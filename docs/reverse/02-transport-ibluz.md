# Transport layer: Actions "iBluz" SDK + joysuny BatteryManager IO

Reverse-engineered from the jadx decompile of `sphere-battery-1.0.24`. All citations are
`file:line` into `artifacts/sphere-battery-1.0.24/jadx/sources/`.

Key classes:
- `com/actions/ibluz/device/bluzdevice/BluzDeviceBle.java` — the GATT client + `IBluzIO` impl.
- `com/actions/ibluz/device/bluzdevice/BluzDeviceBase.java` — scan/connect base, receiver, lifecycle.
- `com/actions/ibluz/device/DataBuffer.java` — the read queue + write chunker.
- `com/actions/ibluz/factory/IBluzIO.java` — the IO interface BatteryManager reads/writes through.
- `com/actions/ibluz/factory/BluzDeviceFactory.java` — factory + UUID key names.
- `com/joysuny/batteryutil/blemanager/BatteryManager.java` — the app-level framer/parser.
- `com/joysuny/batteryutil/blemanager/BatteryCMD.java` — app frame sentinels/opcodes.
- `com/joysuny/batteryutil/global/Global.java` — the FCF0/FCF1/FCF2 UUIDs.
- `com/joysuny/batteryutil/actmodel/MainModel.java` — wires connect → service → MTU → BatteryManager.

## 0. TL;DR

The iBluz SDK on the BLE path is a **thin, transparent pipe**. On the code path the app
actually uses (`mListener == null`, "speed mode" off), the SDK does **no framing**: every GATT
notification payload on the notify characteristic is pushed verbatim into a byte queue, and
`IBluzIO.read()` is a **blocking, coalescing** reader over that queue. Writes go through a
byte queue that chunks to `MTU-5` and are sent **Write-Without-Response**. The joysuny frame
sentinels (e.g. `A0 C1 … B1 D2`) **are the raw GATT payload bytes** — there is no SDK-imposed
length prefix or packet wrapper on this path. A from-scratch Bleak client only has to speak
the joysuny app-level frames directly on FCF1/FCF2.

## 1. Service / characteristic discovery and UUIDs

The SDK has Actions default UUIDs (`BluzDeviceBle.java:62-65`):
- CCCD: `00002902-0000-1000-8000-00805f9b34fb`
- SERVICE: `e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1`
- WRITE_FIFO: `e49a25e0-…`, READ_FIFO: `e49a28e1-…`

**But the app overrides them all** before connecting. `MainModel.connectService()`
(`MainModel.java:168-186`) builds a map and calls `mBluzConnector.setUUID(map)`:
- `keyServiceUUID`  → `Global.OTA_BLE_UUID_SERVICE`       = `0000FCF0-0000-1000-8000-00805F9B34FB`
- `keyReadCharacteristicUUID` → `Global.OTA_BLE_UUID_SERVICE_READ`  = `0000FCF2-…` (notify)
- `keyWriteCharacteristicUUID`→ `Global.OTA_BLE_UUID_SERVICE_WRITE` = `0000FCF1-…` (write)

(`Global.java:22-24`.) Note the app does **not** set `keyConfigurationUUID`, so the CCCD
stays the standard `0x2902`. `BluzDeviceBle.setUUID()` (`:612-636`) maps these into the static
fields `SERVICE`, `CHARACTERISTIC_READ_FIFO` (=FCF2), `CHARACTERISTIC_WRITE_FIFO` (=FCF1).

Discovery: `onServicesDiscovered` (`:180-188`) → `findServiceAndCharacteristic()`
(`:441-477`). It iterates services, matches `SERVICE` (FCF0), then within it matches:
- FCF2 → `mCharacteristicReadFifo` (the notify characteristic).
- FCF1 → `mCharacteristicWriteFifo`, and immediately `setWriteType(1)` = **WRITE_TYPE_NO_RESPONSE** (`:459-460`).

Then `enableCCC(readFifo, gatt)` (`:479-498`):
- `setCharacteristicNotification(readFifo, true)`
- `readFifo.getDescriptor(0x2902).setValue(ENABLE_NOTIFICATION_VALUE)` then `gatt.writeDescriptor(descriptor)` (`:483-486`).

So notifications are standard CCCD-enabled GATT notifications on **FCF2**; writes go to **FCF1**.

### Telink / "OTA" service
There is **no separate Telink OTA GATT service used at runtime.** The names in `Global`
(`OTA_BLE_UUID_*`) are just how the app labels FCF0/1/2. The Actions default `e49a25e0…` write
UUID (which resembles the Telink OTA e49a… family) is present in the SDK **but overridden** and
never used against this device. Firmware update (OTA) runs over the **same FCF1/FCF2 channel**
using app-level frames (`CMD_BEGIN_UPDATE`, `CMD_ACK_HEAD`, `CMD_UPDATE_FINISH`, etc. in
`BatteryCMD.java:66-71`, handled in `BatteryManager.beginSendUpdateFile()` `:931-971`).

## 2. Receive path: notification → byte stream returned by `read()`

GATT notification arrives at `mGattCallback.onCharacteristicChanged()` (`BluzDeviceBle.java:241-245`)
→ `readIndicator(characteristic)` (the inner-class version `:247-257`):

```
if (characteristic == mCharacteristicReadFifo) {
    byte[] value = characteristic.getValue();
    if (mListener == null) {                 // <-- always true in this app (see §7)
        mReadBuffer.add(value.length);       // ReadDataBuffer.add(int)
        mReadBuffer.write(value);            // ReadDataBuffer.write(byte[])
    } else {
        mListener.onDataRead(value);         // "speed mode" — not used here
    }
}
```

`DataBuffer.ReadDataBuffer` (`DataBuffer.java:122-217`) is the internal buffer/queue:
- `add(int len)` (`:196-199`): allocates a fresh scratch `mBuffer = new byte[len]`, `mBufferCount=0`.
- `write(byte[] v)` (`:201-209`): copies `v` into the scratch; when `mBufferCount >= mBuffer.length`
  (which is immediately, since `len == v.length`) it calls the private `add()` (`:211-216`) which
  **enqueues the whole scratch buffer into `mItemList` and `mConditionEmpty.signal()`s.**

**Net effect: each GATT notification becomes exactly one element in the FIFO queue `mItemList`.**

**`read()` is BLOCKING.** `ReadDataBuffer.read(dst, off, count)` (`:159-194`) runs under a
`ReentrantLock`. It loops copying bytes out of the current item (`mItem`/`mOffset`/`mCount`),
calling `reload()` (`:147-157`) to advance to the next queued notification, and when the queue
is empty it `mConditionEmpty.await()`s until a producer signals. It only returns once `count`
bytes have been assembled, and it **always returns `count`** (the requested `i2`, `:187`).
There is no timeout in the buffer; timeouts live at the app layer (§6).

**Partial / coalesced notifications are handled transparently.** Because `read()` coalesces
across queue elements, the app parser can request an arbitrary number of bytes and the buffer
stitches across notification boundaries. A single logical frame split across two notifications,
or two frames coalesced into one notification, both work — the queue is a pure byte stream and
notification boundaries are not preserved semantically (only as queue-element granularity).

`BluzDeviceBle` exposes the `IBluzIO` reads (`:584-610`):
- `read(byte[],off,len)` → `mReadBuffer.read(...)` (`:585-588`).
- `read()` → reads 1 byte, returns `bArr[0] & 0xFF` (`:604-610`).
- `readInt()`/`readShort()` read 4/2 bytes big-endian via `ByteBuffer` (`:590-602`).

## 3. Transmit path: `write()` → `writeCharacteristic` on FCF1

`BatteryManager.send()` (`:231-243`) → `writeBuffer()` (`:245-262`) posts a task to a
single-thread `ScheduledThreadPoolExecutor` that calls `mIO.flush(); mIO.write(bArr); mIO.flush();`.
`flush()` is a **no-op** on BLE (`BluzDeviceBle.java:76-77`).

`BluzDeviceBle.write(byte[])` (`:557-573`): with `mListener == null` it calls
`mWriteBuffer.add(bArr)` (returns false and drops if `>10` queued — see MAX_CMDS below).

`DataBuffer.WriteDataBuffer` (`:17-120`) is the write queue + MTU chunker:
- `add()` (`:37-50`): appends the full command to `mItemList`; if the list was empty, `reload()`.
- `reload()` (`:57-72`): sets `mItem`/`mCount`/`mOffset`, applies a pending `writeMaxLength`
  change, then fires `WriteCallback.onStart()` → which calls `BluzDeviceBle.writeCharacteristic()`
  (registered at `:355-361`).
- `writeCharacteristic()` (`:414-426`): `buffer = mWriteBuffer.getBuffer()` (`:84-97`, one chunk of
  up to `writeMaxLength` bytes), `mCharacteristicWriteFifo.setValue(buffer)`,
  `mBluetoothGatt.writeCharacteristic(mCharacteristicWriteFifo)`.
- On completion, `onCharacteristicWrite()` (`:209-221`) → `writeCharacteristicSuccess()`
  (`:223-239`): if `mWriteBuffer.isEnd()` (whole command sent) → `next()`; else
  `writeCharacteristic()` again for the next chunk. So a command larger than one MTU is
  **automatically fragmented and drained chunk-by-chunk.**

**Write type = WRITE_TYPE_NO_RESPONSE (1).** Set at discovery (`:459`) and never changed on the
FIFO write char in the buffered path. `onCharacteristicWrite` still fires for no-response writes
(local buffer accepted), which is what drives the chunk chain. Note: `enableCCC` calls
`setWriteType(2)` but on the **read** characteristic (`:481`), which is irrelevant to writes.

Chunk size = `writeMaxLength`, default `DEFAULT_WRITE_MAX_LENGTH = 240` (`DataBuffer.java:18,27`),
updated to `MTU-5` after negotiation (§3/§4). Queue depth cap = `MAX_CMDS = 10` (`:19`) — but note
`add()` actually always returns `true` and never enforces it, so the "too much command" log in
`write()` (`:564`) is effectively dead code.

## 4. MTU negotiation and the `C3 F2 <mtu> ED CE` frame

Two distinct MTU concepts — don't conflate them:

**(a) ATT MTU negotiation (SDK / GATT level).** After the CCCD write completes,
`onDescriptorWrite()` (`:264-295`, gated on `mIsClose==true` which `connectBle()` sets `:391`)
requests a large MTU: `mBluetoothGatt.requestConnectionPriority(1); mBluetoothGatt.requestMtu(512)`
(`:275-276`; `DEFAULT_MTU = 512` `:37`). Per-manufacturer quirks force 20 for Meizu / a Xiaomi
Mi-4c / a QiKU model (`:270-279`). It then sleeps 1000ms and fires `onServiceConnected()`.

`onMtuChanged()` (`:307-329`): on success `i3 = mtu - 5`; sets `mWriteMTU = i3` and
`mWriteBuffer.setWriteMaxLength(i3)` (so **write chunking uses ATT-MTU − 5 bytes**, i.e. minus
the 3-byte ATT notify/write header and 2 more — SDK's own margin). On failure `i3 = 20`. It also
calls `mMtuListener.getMtu(i)` with the **raw** negotiated MTU `i` (not `i-5`).
Caveat: `setWriteMaxLength()` (`:52-55`) does not take effect immediately — it stashes
`tempWriteMaxLength` and is applied on the next `reload()` (next fresh command with an empty queue).

**(b) The app-level MTU frame (`C3 F2 <mtu> ED CE`).** This is a *joysuny protocol* frame telling
the BMS firmware the chunk size to use, **not** a GATT operation.
`BatteryManager.sendMtu(int i)` (`:144-146`) builds:
```
{ CMD_SEND_MTU_BEGIN[0], CMD_SEND_MTU_BEGIN[1], (byte)(i & 0xFF), CMD_SEND_MTU_END[0], CMD_SEND_MTU_END[1] }
```
With `CMD_SEND_MTU_BEGIN = {0xC3,0xF2}` and `CMD_SEND_MTU_END = {0xED,0xCE}` (`BatteryCMD.java:57-58`),
this is exactly `C3 F2 <mtu> ED CE` — a single-byte MTU value.

**Where the value comes from:** `MainModel` registers `setMtuListener` (`MainModel.java:155-164`):
`getMtu(i)` caps the raw negotiated ATT MTU at 200 and saves it to SharedPreferences `SP_MTU`
(`i = min(i,200)`). Then in `initManager()` (`:400-408`), 1000ms after `shakeHand()`, it reads
`SP_MTU` (default 20 if unset) and calls `mManager.sendMtu(SP_MTU)`. So the byte the device
receives is **`min(negotiatedAttMtu, 200) & 0xFF`** — e.g. a 247-MTU link yields `0xC8` (200).
(The OTA file chunking separately computes `(SP_MTU/10)*9 - 6` bytes/packet, `BatteryManager.java:934-936`.)

## 5. Connection lifecycle

- Scan: `BluzDeviceBase` uses either the classic discovery `BroadcastReceiver`
  (`:75-148`, `startDiscovery` `:491-502`) or the BLE scanner; the app filters names by
  `startsWith "JS"` (`Global.DEFAULT_BLUE_HEAD`, `MainModel.java:230`).
- Connect: `MainModel.onFound` → `mBluzConnector.connect(device)` (`:121`) →
  `BluzDeviceBase.connect(dev)` (`:362-393`) → `BluzDeviceBle.connect()` (`:509-518`) →
  `connectBle()` (`:389-400`) → `mDeviceBle.connectGatt(ctx, false, mGattCallback, TRANSPORT_LE=2, PHY=1)`.
- `onConnectionStateChange` (`:111-177`): `newState==2` (connected) → `mConnectListener.onConnectSuccess(gatt)`
  → `MainModel` calls `connectService()` → `gatt.discoverServices()` (`MainModel.java:136-137,185`).
- Service/MTU as in §1/§4; success → `onServiceConnected()` → `onDeviceConnectSuccess` →
  `beginGetBtData()` → `initManager()` → `new BatteryManager(ctx, connector.getIO())` +
  `shakeHand()`.
- Disconnect: `newState==0` → (non-stress) `mConnectListener.onConnectFail()` and
  `mBleConnectListener.onConnect(false)`. `disconnect()` (`:520-540`): `refreshDeviceCache()`
  (reflection `gatt.refresh()`, `:542-555`), `closeNotify()` (disable CCCD + notifications
  `:370-387`), `gatt.disconnect()`, `gatt.close()`.
- Reconnection: only in **stress mode** (`mIsStress`, not enabled by this app). There
  `newState==0` schedules a 1000ms retry that re-`connectGatt`s, up to 10 times, then gives up
  (`:138-164`). The normal app path does **not** auto-reconnect at the SDK level; the UI drives reconnect.
- Timeouts: SDK constants `CONNECT_TIMEOUT`/`SCAN_TIMEOUT = 10000`, `DISCOVERY_TIMEOUT = 20000`
  (`BluzDeviceBle.java:36,42`, `BluzDeviceBase.java:34`). App-level: handshake timeout 20000ms,
  resend 2000ms (`BatteryManager.java:29-30`).

## 6. App-level framing/parsing (the joysuny layer, above IBluzIO)

`BatteryManager.startPull()` (`:264-269`) spins a **single reader thread**
`ProcessWatchRunnable` (`:275-918`). Its loop:
1. `int i = mIO.read()` — one byte (blocks).
2. `judgeCMD(b4)` (`:271-273`) — **always false** (it `&&`s many mutually-exclusive equalities),
   so the else branch always runs: read a second byte, forming a **2-byte command header** `bArr`.
3. `ByteUtils.byteCompare(bArr, CMD_*_BEGIN)` selects a handler; each handler then does a
   **fixed-length** `mIO.read(buf, 0, N)` for that command's body and verifies the trailing
   `CMD_*_END` sentinel. Examples (all `BatteryCMD.java`):
   - `A2 57` all-data: read 24 bytes, tail `B3 6C` (`:381-505`).
   - `A9 64` SOC: read 9, tail `BA 5E` (`:564-604`).
   - `A0 C1` cell voltages: read a count byte, then `count*2 + 2`, tail `B1 D2` (`:312-345`).
   - `A1 4F` temperature: read 6, tail `B2 E3`. `A3 9F` MOS: read 8, tail `B4 C7`. etc.

**Critical framing conclusion:** on the BLE path the SDK hands **raw bytes straight through**.
The joysuny `BEGIN`/`END` sentinels and payloads *are* the exact bytes of the GATT notification
payloads — there is **no iBluz packet header, no length prefix, no escaping** wrapping them.
(`DataBuffer.PacketInfo` `:219-248` *does* define a `[len16][type][pad]` packet header, but it is
**not referenced anywhere on the BLE read/write path** — it belongs to the SPP/EDR transports, not this one.)

The framing is therefore **self-delimiting by content**: a 2-byte start sentinel, a
command-specific fixed body length (or a length byte for voltages), and a 2-byte end sentinel
that the parser asserts. There is **no on-wire length field for most frames** and **no checksum**
on the telemetry frames (only the OTA data frames carry a 1-byte two's-complement checksum,
`getSum()` `:973-979`, `getRecallSum()` `:981-984`).

## 7. Speed mode is off (why the buffered path is the real path)

`mListener` (`OnBleListener`) is only set by `setSpeedListener()` and `mIsSpeed` by
`setSpeedMode()`. Neither is ever called by the joysuny app (grep: the only calls to those on
`BluzDeviceBle` are the SDK's own definitions; the app only calls `setMtuListener`). Therefore
throughout this app `mListener == null` and `mIsSpeed == false`, i.e. the buffered
`ReadDataBuffer`/`WriteDataBuffer` path documented above is authoritative.

## 8. Implications for a from-scratch Python/Bleak client

- **Talk the joysuny frames directly on FCF1 (write) / FCF2 (notify).** No iBluz wrapper to
  reproduce — write the raw command bytes (e.g. `FB C8 7C 9D 26 EC` = `CMD_BEGIN`) and parse raw
  notification bytes with the 2-byte-start / fixed-body / 2-byte-end scheme.
- **Enable notifications** by writing `0x0001` to the CCCD (`0x2902`) of FCF2 (Bleak's
  `start_notify` does this).
- **Write Without Response** on FCF1. With Bleak: `write_gatt_char(FCF1, data, response=False)`.
- **You must reassemble the stream, not per-notification frames.** Bleak delivers one callback
  per notification; a logical frame can span multiple notifications and multiple frames can share
  one notification. Buffer incoming bytes and parse by sentinel+length exactly like
  `ProcessWatchRunnable`, rather than assuming one notification == one frame.
- **Chunk your writes to ≤ (ATT_MTU − 5) bytes** if you send commands larger than the MTU (rare —
  most commands are ≤ ~14 bytes; OTA is the big one). Request a large MTU (247/512) first.
- **Handshake order matters:** the app does `CMD_BEGIN` (`FB C8 7C 9D 26 EC`, an opaque wake
  token), then `CMD_GET_EST`, then ~1s later `sendMtu(min(mtu,200))` = `C3 F2 <mtu> ED CE`, and a
  low-temp-protect gate write ~2.5s in. Replicate at least `CMD_BEGIN` + the MTU frame to get the
  device streaming telemetry.
- **No auth / no checksum** on telemetry frames; OTA frames use a 1-byte two's-complement sum.
- The device advertises with a name starting `JS` (and the app relabels FCF0/1/2 as "OTA");
  don't look for a Telink `e49a…` service — it isn't used.
