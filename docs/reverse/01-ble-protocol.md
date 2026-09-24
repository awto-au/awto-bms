# Sphere / JoySuny BMS — BLE command/frame protocol (exhaustive)

Reverse-engineered from the jadx decompile of **Sphere Battery 1.0.24**
(`com.joysuny.batteryutil`). Every claim is cited `file:line`. Byte values are given in
hex (the Java source stores them as signed decimals; the conversions here are exact).
All integer math is reproduced exactly, including truncating integer division.

Source files (all under
`artifacts/sphere-battery-1.0.24/jadx/sources/com/joysuny/batteryutil/`):

- `blemanager/BatteryManager.java`  — **BM** below
- `blemanager/BatteryCMD.java`      — **CMD** below
- `blemanager/BatteryAllDataBean.java`
- `blemanager/IReadIOListener.java`
- `blemanager/OnUpdateListener.java`
- `util/ByteUtils.java`
- `util/Utils.java`
- `sp/SpManager.java` (pref key strings), `actmodel/MainModel.java` (MTU + call sites)

Nothing here is verified against live hardware.

---

## 0. Byte-helper semantics (util/ByteUtils.java, util/Utils.java)

These define endianness/scaling for everything below. Read them first.

| Method | Definition | Meaning |
|---|---|---|
| `intToByte(i)` | `(byte)(i & 255)` — ByteUtils:18 | low 8 bits |
| `intToBytes(i)` | `{(byte)(i&255), (byte)((i>>8)&255)}` — ByteUtils:33 | **u16 little-endian** (LSB first) |
| `longToBytes(j)` | `{(byte)(j&255), (byte)((j>>8)&255), (byte)((j>>16)&255)}` — ByteUtils:37 | **u24 little-endian** (LSB first) |
| `byteToInt(b[])` | `(b[0]&255) + ((b[1]&255)<<8)` — ByteUtils:41 | **u16 little-endian** |
| `byteToIntHigh(b[])` | `(b[1]&255) + ((b[0]&255)<<8)` — ByteUtils:45 | **u16 big-endian** (used only in OTA seq) |
| `byteToLong(b[])` | `(b[0]&255) + ((b[1]&255)<<8) + ((b[2]&255)<<16) + (len<4?0:(b[3]&255)<<24)` — ByteUtils:49 | **u24/u32 little-endian** |
| `byteJudge(b)` | `b != 0` — ByteUtils:10 | bool |
| `byteToInt1(b)` | `b & 255` — ByteUtils:14 | unsigned byte |
| `byteCompare(a,b)` | element-wise equality, false on length mismatch — ByteUtils:53 | sentinel match |

`Utils.secondToTime(long j)` (Utils:34): `HH:MM:SS`, `HH = j/3600` zero-padded to ≥2 digits
(no cap; can exceed 24). `Utils.getCurTime()` (Utils:54) builds a `TimeBean` from
`new Time("GNT+8")` — **"GNT+8" is a typo for "GMT+8" and is not a valid Olson/POSIX zone**,
so Android's `Time` silently falls back (effectively UTC); `month = time.month + 1`,
`year = time.year` (full 4-digit).

**Key correction vs the existing PROTOCOL.md:** all multi-byte numbers are **little-endian**
(`byteToInt`/`byteToLong`/`longToBytes`/`intToBytes` all place the LSB first). The only
big-endian value in the whole protocol is the OTA chunk sequence number.

---

## 1. TX commands (app → BMS)

Fixed opaque command constants (CMD:*, hex):

| Constant | Bytes (hex) | ASCII / note |
|---|---|---|
| `CMD_BEGIN` | `FB C8 7C 9D 26 EC` | handshake wake token (CMD:40) |
| `CMD_GET_EST` | `C4 7D F4 D5 86` | request est-time (CMD:41) |
| `CMD_GET_VERSION` | `41 54 2B 56 0D 0A` | `AT+V\r\n` (CMD:54) |
| `CMD_SET_BLUETOOTH_NAME_BEGIN` | `41 54 2B 3D` | `AT+=` (CMD:42) |
| `CMD_SET_BLUETOOTH_NAME_END` | `0D 0A` | `\r\n` (CMD:43) |
| `CMD_GATE_CONTROL_BEGIN` / `_END` | `C3 1E` / `D4 3B` | (CMD:46-47) |
| `CMD_BATTERY_BEGIN` / `_END` | `C5 60` / `D6 2A` | (CMD:48-49) |
| `CMD_SET_TIME_BEGIN` / `_END` | `C8 18` / `D9 74` | (CMD:50-51) |
| `CMD_OPEN_SLEEP_CONTROL` | `AA CC 00 01 DD EE` | sleep ON (CMD:55) |
| `CMD_CLOSE_SLEEP_CONTROL` | `AA CC 01 01 DD EE` | sleep OFF (CMD:56) |
| `CMD_SEND_MTU_BEGIN` / `_END` | `C3 F2` / `ED CE` | (CMD:57-58) |
| `CMD_GET_HISTORY` | `C6 7C CF 00 D7 52` | (CMD:53) |
| `CMD_SET_HISTORY_STATUS_BEGIN` | `FF CA BE 9A` | (CMD:44) |
| `CMD_SET_HISTORY_STATUS_END` | `FA 5F 81 DC` | (CMD:45) |
| `CMD_CLEAR_HISTORY` | `C7 46 D8 82` | (CMD:52) |
| `CMD_BEGIN_UPDATE` | `EB 90 00 07 BB 03 40` | OTA start (CMD:66) |
| `CMD_ACK_HEAD` | `01 01` | OTA data-frame header (CMD:69) |
| `CMD_UPDATE_FINISH` | `01 01 EC 00 00 12` | (CMD:70) |
| `CMD_UPDATE_END` | `AA BB 01 02 03 04 CC DD` | (CMD:71) |

### 1.1 `sendBeginCMD` / `CMD_BEGIN` (BM:102-111)

`send(CMD_BEGIN)` → `FB C8 7C 9D 26 EC`. Opaque, no structure. Before sending it schedules
the 20 s handshake timeout (`mRemoteHandshakeTimeout`, BM:103). 2500 ms later it fires a
`setLowTemProtect` gate frame via a one-shot `Timer` (BM:105-110).

### 1.2 `getEst` / `CMD_GET_EST` (BM:196-198)

`send(CMD_GET_EST)` → `C4 7D F4 D5 86`. Requests the EST_TIME frame. Sent during `shakeHand`.

### 1.3 `getVersion` / `CMD_GET_VERSION` (BM:113-115)

`send(CMD_GET_VERSION)` → `41 54 2B 56 0D 0A` (`AT+V\r\n`).

### 1.4 Set BLE name (BM:117-129, `setBTName(String)`)

- Rejects (`return false`) if `name.getBytes().length >= 20` (BM:119).
- Frame = `CMD_SET_BLUETOOTH_NAME_BEGIN` (4 B, `41 54 2B 3D` = `AT+=`) + name bytes +
  `CMD_SET_BLUETOOTH_NAME_END` (2 B, `0D 0A`). Assembled by three `System.arraycopy`
  (BM:123-126). So on the wire: `AT+=<name>\r\n`. BMS replies `\r\nOK\r\n` (see §2.16).

### 1.5 `CMD_GATE_CONTROL` — the 8 payload bytes (BM:131-166, 227-229)

12-byte frame: `C3 1E  p0 p1 p2 p3 p4 p5 p6 p7  D4 3B`. Field map (verified from every setter):

```
C3 1E  p0 p1 p2 p3 p4 p5 p6 p7  D4 3B
       |  |  |  |  |  |  |  +-- p7  factory reset   (1 = perform)
       |  |  |  |  |  |  +----- p6  passive balance (1 = on)
       |  |  |  |  |  +-------- p5  restart BMS     (1 = perform)
       |  |  |  |  +----------- p4  heater gate
       |  |  |  +-------------- p3  smoke gate
       |  |  +----------------- p2  temp-control gate
       |  +-------------------- p1  discharge MOS   (1 = on)
       +----------------------- p0  charge MOS      (1 = on)
```

Every setter re-sends the **whole** frame, filling the fields it does not touch from cached
SharedPreferences (path `battery_path`, keys from SpManager). Exact per-setter payloads:

| Setter (BM) | p0 | p1 | p2 | p3 | p4 | p5 | p6 | p7 |
|---|---|---|---|---|---|---|---|---|
| `setMos(z)` :164 | `z` | `z` | pref `temcontorl_gate` | pref `smoke_gate` | pref `heat_gate` | `0` | pref `setting_passiva` | `0` |
| `setHeat(z)` :158 † | pref `setting_mos` | pref `setting_mos` | pref `temcontorl_gate` | pref `smoke_gate` | **`z`** | `0` | pref `setting_passiva` | `0` |
| `setPassiva(z)` :153 | pref `setting_mos` | pref `setting_mos` | pref `temcontorl_gate` | pref `smoke_gate` | pref `heat_gate` | `0` | **`z`** | `0` |
| `setRestart()` :139 | pref `setting_mos` | pref `setting_mos` | pref `temcontorl_gate` | pref `smoke_gate` | pref `heat_gate` | **`1`** | pref `setting_passiva` | `0` |
| `setFactory()` :148 | pref `setting_mos` | pref `setting_mos` | pref `temcontorl_gate` | pref `smoke_gate` | pref `heat_gate` | `0` | pref `setting_passiva` | **`1`** |
| `setLowTemProtect()` :227 | `1` | `1` | `1` | `0` | `0` | `0` | `0` | `0` |

† `setHeat(z)` **first** does `saveInt(..., SP_HEAT_GATE, z?1:0)` (BM:160) before building the
frame, so the cached heat gate is updated to match.

Pref keys (SpManager:15-23), all under path `battery_path` (`SP_PATH`):
`setting_mos` (bool), `temcontorl_gate` (int), `smoke_gate` (int), `heat_gate` (int),
`setting_passiva` (bool). Booleans encode as `1`/`0`; ints via `intToByte` (low 8 bits).

**CORRECTION vs PROTOCOL.md:** the existing doc claims all of `setting_mos`,
`temcontorl_gate`, `smoke_gate`, `heat_gate`, `setting_passiva` are "populated from the STATUS
frame." The BAL_STATUS handler (BM:538-541) writes only `setting_mos`, `temcontorl_gate`,
`smoke_gate`, `heat_gate`. It does **not** write `setting_passiva`. `setting_passiva` is
written only by UI view-models (`fragmentvm/SetViewModel.java:168`,
`fragmentmodel/DialModel.java:167`) — never by BatteryManager. So the passive-balance bit in
every gate frame comes from the last UI toggle, which can be stale relative to the balancer
state the BMS actually reports in BAL_STATUS byte `s3`.

`setLowTemProtect` is a fixed frame `C3 1E 01 01 01 00 00 00 00 00 D4 3B`, auto-sent 2.5 s into
the handshake (BM:108). It forces charge+discharge MOS on and the temp-control gate on.

### 1.6 `CMD_BATTERY` — rated capacity (BM:168-171, `setBattery(String)`)

`b = longToBytes((long)(Float.parseFloat(str) * 1000.0f))` (BM:169). Frame (7 B):
`C5 60  b0 b1 b2  D6 2A` where `b0..b2` = **u24 little-endian** of `round-toward-zero(Ah×1000)`.

- Example: `"100"` → 100000 = `0x0186A0` → `b0=A0 b1=86 b2=01` → `C5 60 A0 86 01 D6 2A`.

**CORRECTION:** PROTOCOL.md says "big-endian 24-bit." `longToBytes` emits LSB first, so it is
**little-endian**.

### 1.7 `CMD_SET_TIME` (BM:191-194, `setTime()`)

`curTime = Utils.getCurTime()`. Frame (11 B):

```
C8 18  yLo yHi  MM  DD  HH  mm  ss  D9 74
```

- `yLo yHi` = `intToBytes(year)` = **u16 little-endian** of the 4-digit year
  (BM:193 uses `intToBytes(year)[0]` then `[1]`; `[0]` is the low byte).
- `MM DD HH mm ss` each = `intToByte(...)` (low 8 bits) of month(1-12), day, hour, minute, second.
- Example year 2026 = `0x07EA` → `yLo=EA yHi=07`.

**CORRECTION:** PROTOCOL.md says "year 16-bit BE." It is little-endian (low byte first).

### 1.8 Sleep open/close (BM:131-137, `setSleepMode(boolean)`)

`z==true` → `send(CMD_OPEN_SLEEP_CONTROL)` = `AA CC 00 01 DD EE`;
`z==false` → `send(CMD_CLOSE_SLEEP_CONTROL)` = `AA CC 01 01 DD EE`. Both fixed constants.

### 1.9 `CMD_SEND_MTU` (BM:144-146, `sendMtu(int i)`)

Frame (5 B): `C3 F2  (byte)(i&255)  ED CE`. Only the low byte of the MTU is transmitted.
`i` is the MTU the iBluz stack negotiated: `MainModel.3.getMtu` clamps to ≤200 and stores it
in pref `sphere_mtu` (MainModel:159-162); `MainModel` then calls `sendMtu(pref sphere_mtu,
default 20)` 1000 ms after `shakeHand` (MainModel:401-407). Example MTU 20 → `C3 F2 14 ED CE`.

### 1.10 `CMD_GET_HISTORY` (BM:200-202)

`send(CMD_GET_HISTORY)` → `C6 7C CF 00 D7 52`. **The app never parses any history response**
(see §2.15 / §4).

### 1.11 `CMD_SET_HISTORY_STATUS` (BM:204-220, `setHistoryStatus(List<Integer>)`) — buggy

```java
byte[] bArr = new byte[(list.size() * 2) + 9];          // :205
arraycopy(CMD_SET_HISTORY_STATUS_BEGIN, 0, bArr, 0, 4);  // FF CA BE 9A  :206
bArr[4] = 0;                                             // :207
int i = 0, i2 = 0;
for (int i3 = 5; i3 < list.size() * 2; i3 += 2) {        // :210  <-- BUG
    bArr[i3]     = intToByte(list.get(i));               // id byte
    i2 = i3 + 1; bArr[i2] = 0;                           // padding 0
    i++;
}
for (int i4 = 0; i4 < 4; i4++)                           // :216
    bArr[i2 + i4 + 1] = CMD_SET_HISTORY_STATUS_END[i4];  // FA 5F 81 DC
send(bArr);
```

Intended frame: `FF CA BE 9A 00  (id,00)…  FA 5F 81 DC`. Two real defects:

1. **Off-by-(more-than)-one loop bound.** The loop writes ids at index 5,7,9,… but the guard
   is `i3 < size*2` instead of `i3 < 5 + size*2`. For `N = list.size()` it runs `N-2`
   iterations (for N≥3), so it writes only ids `list[0..N-3]` and **silently drops the last 2
   entries**. For N<3 it writes **zero** ids and the END-copy at `i2+i4+1` (with `i2==0`)
   overwrites bytes 1..4 — i.e. it clobbers part of the BEGIN sentinel.
2. **Trailing garbage.** The array is sized `2N+9`, but END is placed right after the last id.
   Worked example N=6 (array = 21 bytes, indices 0-20):
   `[0..3]=FF CA BE 9A`, `[4]=00`, ids at `[5]=id0 [7]=id1 [9]=id2 [11]=id3`, zero pads at
   `[6][8][10][12]`, END at `[13..16]=FA 5F 81 DC`, and **`[17..20]=00 00 00 00`** trailing
   junk. ids 4 and 5 never sent.

This confirms the off-by-one the task asked to verify — it is real and worse than off-by-one.

### 1.12 `CMD_CLEAR_HISTORY` (BM:222-224)

`send(CMD_CLEAR_HISTORY)` → `C7 46 D8 82`.

### 1.13 OTA / firmware update flow (BM:173-189, 825-873, 920-984)

**Entry:** `update(ctx, file, listener)` (BM:173-179): sets static `sUpdateListener`, calls
`startPull()`, saves the file's absolute path to pref `update_file_path`, then `beginUpdate()`.

**`beginUpdate()` (BM:181-184):** schedules 20 s handshake timeout, `send(CMD_BEGIN_UPDATE)` =
`EB 90 00 07 BB 03 40`.

**BMS "go" trigger — `CMD_UPDATE_RECALL` (RX, BM:825-834):** begin `FF 01`
(`CMD_UPDATE_RECALL_1`), then read 3 bytes and compare to `CMD_UPDATE_RECALL_2` = `B1 02 EF`.
Full frame `FF 01 B1 02 EF`. On match: create `mResendPool`, `mCurNum=0`, `mResendTime=0`,
`beginSendUpdateFile(0)`. This same frame also **restarts** the transfer from chunk 0 if
re-received mid-flight.

**Data frame — `beginSendUpdateFile(i)` (BM:932-971):**

```
payloadCap = (pref sphere_mtu[def 20] / 10) * 9 - 6         (:934-936; def 20 -> 12 bytes)
offset     = payloadCap * i                                  (:937)
len        = payloadCap, clamped to (fileLen - offset) on the last chunk   (:946-948)
if fileLen <= offset  -> updateFinish(); return             (:942-945)
read len bytes from file at offset via RandomAccessFile.seek (:950-953)

frame (len+6 bytes):
  [0]=01 [1]=01            (CMD_ACK_HEAD)                    (:956-957)
  [2]=intToBytes(i)[1] = (i>>8)&255   = seqHi               (:958)
  [3]=intToBytes(i)[0] =  i&255       = seqLo               (:959)   => seq is BIG-ENDIAN on wire
  [4]=intToByte(len)                                        (:960)
  [5..5+len-1]=file payload                                 (:961)
  [len+5]=getSum(frame, len+5)                              (:962-963)
schedule 2 s resend timer, send(frame)                      (:964-965)
```

`getSum(b,n)` (BM:973-979) = `(byte)(~((byte)Σb[0..n-1]) + 1)` — the checksum byte that makes
the 8-bit sum of the **whole** frame ≡ 0 (mod 256).

**ACK from BMS (RX, BM:835-863):** begin `01 01` (`CMD_ACK_HEAD`), read 4 bytes
`[seqHi seqLo x cksum]`. Advance iff (a) 4 bytes read, (b)
`byteToIntHigh({seqHi,seqLo}) == mCurNum` (big-endian compare, BM:841), **and** (c)
`bArr31[3] == getRecallSum({seqHi,seqLo})` (BM:843). `getRecallSum(b)` (BM:982-984) =
`(byte)(~(b[0] + 2 + b[1] + 6) + 1)` = two's-complement of `(seqHi + seqLo + 8)`. On success:
cancel resend timer, `mResendTime=0`, `mCurNum++`, send next chunk (BM:844-848).

**Resend logic (BM:52-64):** the 2 s timer runnable resends the current chunk up to 10 times;
on the 11th (`mResendTime >= 10`) it calls `sUpdateListener.onUpdateFailure()` and nulls the
listener.

**Finish (BM:920-929, `updateFinish`):** 300 ms after the last chunk, `send(CMD_UPDATE_FINISH)`
= `01 01 EC 00 00 12` (a zero-length data frame; its `12` checksum makes the sum ≡ 0), then arm
the 2 s resend timer.

**Success from BMS (RX, BM:864-873):** begin `AA BB` (`CMD_UPDATE_SUCCESS_1`), read 3 bytes,
compare `CMD_UPDATE_SUCCESS_2` = `01 02 EF`. Full frame `AA BB 01 02 EF`. → `onUpdateSuccess()`,
null the listener, cancel resend timer.

**`CMD_UPDATE_END` / `endUpdate()` (BM:186-189):** `send(CMD_UPDATE_END)` =
`AA BB 01 02 03 04 CC DD`. This is a **public** method invoked by the UI, not by the internal
flow; it is not sent automatically anywhere in BatteryManager.

`CMD_UPDATE_FINISH` and `CMD_UPDATE_SUCCESS_1` both format-collide with other frames only at the
begin-pair level; `AA BB` (success) vs `AA BB 01 02 03 04 CC DD` (`CMD_UPDATE_END`, TX) share
the same 2-byte begin but END is TX-only so no RX ambiguity.

---

## 2. RX frames (BMS → app), parsed in `ProcessWatchRunnable.run` (BM:275-918)

**Frame read primitive (BM:294-311).** Read 1 byte `b4`. `if (judgeCMD(b4))` read 2 **more**
bytes as the begin pair (discarding `b4`); `else` the begin pair = `{b4, next}`. Because
`judgeCMD` is **always false** (§4), the else path always runs, so the begin sentinel is simply
the first two bytes read. Dispatch is a single if/else-if chain comparing that pair
(`byteCompare`) against each begin constant. All begin pairs are distinct, so no shadowing.

Payload offsets below are 0-based from the **first byte after the 2-byte begin**. The parser
reads a fixed count `n` for each frame (that count **includes** the trailing 2- or 4-byte end
sentinel), then validates the end sentinel; on mismatch the frame is dropped silently.

Any exception anywhere in the loop sets `mRunning=false` and fires `mListener.IOError("err:")`
(BM:910-914 and the per-branch catches), so **a single malformed/desynced frame tears down the
whole read loop and connection.**

### 2.1 `CMD_VOL` — cell voltages (BM:312-346)

Begin `A0 C1`, end `B1 D2`. Read 1 byte `n` = cell count (BM:313), then read `n*2 + 2` bytes
(BM:314-317). End sentinel at `[n*2], [n*2+1]`. Each cell = `byteToInt` (**u16 LE**, raw
**millivolts**) for offsets `0,2,4,…` (BM:326-333). → `mListener.getVolData(n, List<Integer>)`
(BM:339). No scaling applied to cells here.

### 2.2 `CMD_TEMPUTER` — two temperatures (BM:347-378)

Begin `A1 4F`, end `B2 E3`. Read 6 bytes; end sentinel at `[4],[5]`.

| Off | Field | Type |
|---|---|---|
| 0 | (ignored) | — |
| 1 | temp 1 | **signed** 8-bit: `v = b[1]&0xFF; if (v>127) v += 0xFFFFFF00` (−256) → °C |
| 2 | (ignored) | — |
| 3 | temp 2 | **signed** 8-bit (same) → °C |

→ `mListener.getTemperature(t1, t2)` (BM:357-366). (`InputDeviceCompat.SOURCE_ANY` = `0xFFFFFF00`
= −256, i.e. sign-extension.)

Live (`JS5.1`, see PROTOCOL.md): the ignored bytes are copies. p0 == p3 in every frame and p1 ≈ p2
(±1 °C), so the frame is two sensors each sent twice.

### 2.3 `CMD_ALL_DATA` — main telemetry (BM:381-470, BatteryAllDataBean.java)

Begin `A2 57`, end `B3 6C`. Read **24 bytes**; end sentinel at `[22],[23]`. On entry the
handshake timeout is cancelled (`mScheduledThreadPoolExecutor.remove(mSFRemoteTimeout)`,
BM:385) — **ALL_DATA is what completes the handshake.**

| Off | Field (bean setter) | Type | Exact expression → unit |
|---|---|---|---|
| 0..1 | allVol | u16 LE | `byteToInt / 10.0f` → V (BM:439) |
| 2..4 | allCur | u24 LE (`{[2],[3],[4],0}`) | `(byteToLong / 100) / 10.0f` → A magnitude (BM:440) |
| 5 | loadStatus | u8 | `byteJudge` (`!=0`) (BM:441) |
| 6 | chargerStatus | u8 | `byteJudge` (BM:442) |
| 7 | chipTemputer | u8 | `b & 0xFF` → °C (BM:443). Live: always 0 on `JS5.1` |
| 8..9 | vsum (sum of cells) | u16 LE | `byteToInt / 10.0f` → V (BM:444) |
| 10..11 | maxVol | u16 LE | `(byteToInt / 10) / 100.0f` → V (BM:445) |
| 12..13 | minVol | u16 LE | `(byteToInt / 10) / 100.0f` → V (BM:446) |
| 14..15 | volDiff | u16 LE | `(byteToInt / 10) / 100.0f` → V (BM:447) |
| 16..17 | curPower | u16 LE | `byteToInt / 10.0f` → W (BM:448) |
| 18..19 | cycTimes | u16 LE | `byteToInt` → count (BM:449) |
| 20..21 | avgVol | u16 LE | `(byteToInt / 10) / 100.0f` → V (BM:450) |

The `/100` (current) and `/10` (cell voltages) are **integer** divisions applied before the
float divide — truncation is real. Current carries no sign here. → `mListener.getAllData(bean)`
(BM:453).

### 2.4 `CMD_MOS_STATUS` (BM:507-529)

Begin `A3 9F`, end `B4 C7`. Read 8 bytes; end at `[6],[7]`. `getMosStatus(true)` iff
`[0]==1 && [1]==1`, else `getMosStatus(false)` (BM:512-516). `[0]`=charge FET, `[1]`=discharge
FET; `[2..5]` unused.

### 2.5 `CMD_WARN_CUR_ALARM` (BM:677-709)

Begin `A4 8B`, end `B5 DD`. Read 7 bytes; end at `[5],[6]`. Flag → R.string (a flag "set" when
byte `== 1`):

| Off | Condition (`==1`) | R.string |
|---|---|---|
| 0 | over-current discharge | `warn_over_cur_discharge_protect` (BM:684) |
| 1 | over-current charge | `warn_over_cur_charge_protect` (BM:690) |
| 2 | short circuit | `warn_short_protect` (BM:693) |

`[3],[4]` unused. → `mListener.getCurWarnList(list)` (BM:696).

### 2.6 `CMD_WARN_VOL_ALARM` (BM:710-748)

Begin `A5 99`, end `B6 17`. Read 11 bytes; end at `[9],[10]`.

| Off | Condition (`==1`) | R.string |
|---|---|---|
| 0 | single-cell over-voltage (charge) | `warn_single_charge` (BM:717) |
| 1 | single-cell under-voltage (discharge) | `warn_single_discharge` (BM:723) |
| 3 | cell voltage difference | `warn_vol_diff_alarm` (BM:726) |
| 6 | pack over-voltage (charge) | `warn_overall_charge_protect` (BM:729) |
| 7 | pack under-voltage (discharge) | `warn_overall_discharge_protect` (BM:732) |

`[2],[4],[5],[8]` unused. → `mListener.getVolWarnList(list)` (BM:735).

### 2.7 `CMD_WARN_TEMP_ALARM` (BM:635-676)

Begin `A6 C0`, end `B7 72`. Read 9 bytes; end at `[7],[8]`.

| Off | Condition | R.string |
|---|---|---|
| 0 | `==1` chip over-temp | `warn_chip_over_protect` (BM:642) |
| 1 | `==1` chip under-temp | `warn_chip_under_protect` (BM:648) |
| 2 or 3 | `[2]==1 \|\| [3]==1` MOS over-temp | `warn_mos_over_temputer` (BM:650) |
| 4 | `==1` under-temp discharge | `warn_under_discharge_protect` (BM:653) |
| 5 | `==1` under-temp charge | `warn_under_charge_protect` (BM:656) |
| 6 | `==1` MOS protect | `warn_mos_protect` (BM:659) |

→ `mListener.getTempWarnList(list)` (BM:663).

The strings are the vendor's. Live (see PROTOCOL.md): byte 2 is a **latched over-temperature
protection** (held after the pack cools, inhibits charging, cleared only by a BMS restart), not a
MOS reading; bytes 3 and 6 never changed and their meaning is unknown.

### 2.8 `CMD_OTHER` (BM:562-563) — A7 4E

Begin `A7 4E`. The parser does `mIO.read(new byte[9], 0, 9)` and **discards all 9 bytes**
(BM:563). No end-sentinel check, no callback. Purpose **undetermined** — the 9-byte length and
the `A7 4E` begin match the shape of the other status frames (7 data + 2 end), so it is most
plausibly a telemetry/status frame the app deliberately ignores, but the payload meaning cannot
be recovered from the app code. `CMD_OTHER_BEGIN` = `A7 4E` (CMD:65); there is no
`CMD_OTHER_END` constant.

### 2.9 `CMD_BAL_STATUS` — the real status frame (BM:530-560)

Begin `A8 AC`, end `B9 21`. Read 9 bytes; end sentinel at `[7],[8]`. Data `[0..6]`:

```
A8 AC  s0 s1 s2 s3 s4 s5 s6  B9 21
       |  |  |  |  |  |  +-- s6  heater gate        -> pref heat_gate       (BM:541)
       |  |  |  |  |  +----- s5  smoke gate         -> pref smoke_gate      (BM:540)
       |  |  |  |  +-------- s4  temp-control gate  -> pref temcontorl_gate (BM:539)
       |  |  |  +----------- s3  passive balancing  -> getBalancerStatus(s3==1, s0)
       |  |  +-------------- s2  discharge MOS  \  mos-on := (s1==s2 && s1==1)  -> pref setting_mos (BM:538)
       |  +----------------- s1  charge MOS     /
       +-------------------- s0  charge state (u8): 0 idle / 1 charging / 2 discharging
```

`i9 = s0 & 0xFF` is passed as the 2nd arg of `getBalancerStatus`. This handler is the **only**
writer of prefs `setting_mos`, `temcontorl_gate`, `smoke_gate`, `heat_gate` in BatteryManager —
i.e. the cache the gate-control setters read back from. It does **not** write `setting_passiva`.
→ `mListener.getBalancerStatus(s3==1, s0)` (BM:543-546).

### 2.10 `CMD_SOC` — state of charge + capacities (BM:564-604)

Begin `A9 64`, end `BA 5E`. Read 9 bytes; end at `[7],[8]`.

| Off | Field | Type | Scaling |
|---|---|---|---|
| 0 | SOC % | u8 | clamped to 0..100 (BM:570-576) |
| 1..3 | capacity A (`fByteToLong`) | **u24 LE** | `/ 1000.0f` → Ah |
| 4..6 | capacity B (`fByteToLong2`) | **u24 LE** | `/ 1000.0f` → Ah |

Call: `getSOC(pct, fByteToLong2/1000, fByteToLong/1000)` (BM:583) — i.e. **1st float arg =
bytes 4..6**, **2nd float arg = bytes 1..3**. The interface is `getSOC(int, float f, float f2)`
(IReadIOListener:25). The semantic labels "remaining" vs "full/rated" are **not present in the
code** (the log at BM:582 just prints the two raw values); the existing PROTOCOL.md's
"remaining = 4..6, full = 1..3" is a reasonable interpretation but is **unverified** — only the
byte→arg mapping above is certain. Both are **little-endian** (PROTOCOL.md's ASCII diagram
labels these "24-bit BE," which is wrong).

### 2.11 `CMD_EST_TIME` — time remaining (BM:605-634)

Begin `AA AF`, end `BB 22`. Read 8 bytes; end at `[6],[7]`.

| Off | Field | Type |
|---|---|---|
| 0..2 | `jByteToLong2` | u24 LE seconds |
| 3..5 | `jByteToLong` | u24 LE seconds |

Call: `getEstTime(secondToTime(jByteToLong2), secondToTime(jByteToLong))` (BM:615) — 1st arg =
bytes 0..2, 2nd arg = bytes 3..5, each → `"HH:MM:SS"`. (Existing doc's "charge = 0..2, empty =
3..5" is a plausible interpretation, not code-stated.)

### 2.12 `CMD_SETTING_RESPOND` (BM:749-766)

Begin `AB BA`, end `CD DC`. Read 3 bytes; end at `[1],[2]`. Fires `mListener.batteryRes(true)`
**only if `[0]==4`** (BM:753) — i.e. it is specifically the ack for a capacity write
(`CMD_SETTING_BATTERY = 4`, CMD:7). Values 1/2/3 (`CMD_SETTING_VOL/CUR/TEMP`) are defined but
never produced or handled. Full frame `AB BA 04 CD DC`.

### 2.13 `CMD_NAME_SET` (BM:767-771)

Begin `CMD_NAME_SET_1` = `0D 0A`. Read 4 bytes, compare `CMD_NAME_SET_2` = `4F 4B 0D 0A`
(`OK\r\n`). Full frame `0D 0A 4F 4B 0D 0A` (`\r\nOK\r\n`). → `mListener.setNameRes()` (BM:770).
Ack for the `AT+=` rename (§1.4).

### 2.14 `CMD_GATE_SET` — gate-control ack (BM:772-799)

Begin `D2 7E`, end `FA 4B`. Read 10 bytes; end at `[8],[9]`. `[0..7]` echo the 8 gate-control
payload fields as booleans (`==1`). → `mListener.gateRes(g0,g1,g2,g3,g4,g5,g6,g7)` (BM:786),
same field order as §1.5.

### 2.15 `CMD_VERSION` (BM:800-824)

Begin `AC 9A`, end `BD 10`. Read 7 bytes; end at `[5],[6]`. Version string =
`new String({[0],[1],[2],[3],[4]})` — 5 ASCII chars (BM:806). → `mListener.getVersion(str)`
(BM:808). MainModel maps `JS5.1`/`JS5.2` → family-5, `JS3.1`/`JS3.2` → family-3
(MainModel:392-395).

### 2.16 `CMD_SLEEP_SET_SUCCESS` (BM:874-893)

Begin `AC CA`. Read 3 bytes. If `[0]==0` → save pref `setting_sleep_mode = true`; else `false`
(BM:877-892). **Note:** the end sentinel `CMD_SLEEP_SET_SUCCESS_END` = `DE ED` is **not
checked**, and **no listener callback fires** (the `IReadIOListener.getSleepStatus` method is
never invoked in this loop). The flag polarity is inverted-looking (`0` ⇒ sleep on) but is
exactly as written.

### 2.17 OTA RX acks

`CMD_UPDATE_RECALL` (`FF 01` + `B1 02 EF`), `CMD_ACK_HEAD` (`01 01` + 4 bytes), and
`CMD_UPDATE_SUCCESS` (`AA BB` + `01 02 EF`) — fully described in §1.13.

### 2.18 HISTORY response — **not parsed anywhere** (see §4)

`CMD_HISTORY_BEGIN_1` (`FE C9`), `CMD_HISTORY_BEGIN_2` (`BD 8A`), `CMD_HISTORY_END`
(`EA 4F 80 DE`) are defined (CMD:25-27) and `CMD_HISTORY_BEGIN_1[0]` appears only inside the
dead `judgeCMD` (BM:272). A grep of the whole decompiled tree finds **no `byteCompare` against
any history sentinel** in `ProcessWatchRunnable` or elsewhere. The app can *request* history
(§1.10-1.12) but has **no code path that decodes a history response.**

---

## 3. Handshake, read-loop startup, MTU

`shakeHand()` (BM:91-96), in order:

1. `retryTimes = 0`.
2. `startPull()` (BM:264-269): spawn `Thread(new ProcessWatchRunnable())`, set `mRunning=true`,
   `thread.start()`. The loop (BM:290) runs while `mRunning`; it returns immediately if both
   `mListener==null` and `sUpdateListener==null` (BM:291-293).
3. `sendBeginCMD()` (BM:102-111): schedule 20 s handshake timeout, `send(CMD_BEGIN)`
   (`FB C8 7C 9D 26 EC`), and arm a 2500 ms `Timer` → `setLowTemProtect()`.
4. `getEst()` (BM:196): `send(CMD_GET_EST)` (`C4 7D F4 D5 86`).

Then (driven by `MainModel`, not BatteryManager): 1000 ms later `sendMtu(pref sphere_mtu)`
(MainModel:401-407) → `C3 F2 <mtu&0xFF> ED CE`.

Timeline: t≈0 `CMD_BEGIN` + `CMD_GET_EST`; t≈1.0 s MTU; t≈2.5 s low-temp-protect gate frame.
The handshake completes (timeout cancelled) when the **first ALL_DATA** frame arrives (BM:385).

**Handshake-timeout quirk (BM:42-51):** `mRemoteHandshakeTimeout` is a one-shot. On fire it does
`if (retryTimes != 0) IOError("time out"); else retryTimes++`. Since `shakeHand` resets
`retryTimes=0` and the timeout is scheduled only once per attempt, the **first** timeout merely
bumps `retryTimes` to 1 and raises **no** error; there is no second scheduled fire, so a stalled
first handshake never surfaces "time out" from here. (`send` is also a no-op whenever
`mRunning==false`, BM:234.)

`send(byte[])` (BM:232-243) guards on `mRunning`, then `writeBuffer` posts a Runnable to
`mScheduledThreadPoolExecutor` that does `mIO.flush(); mIO.write(bArr); mIO.flush()`
(BM:245-262). All TX goes out FCF1; all RX comes in on FCF2 (transport per PROTOCOL.md).

---

## 4. Bugs / footguns

1. **`judgeCMD` is dead code (BM:271-273).** It `&&`-ANDs ~15 equality tests of a single byte
   against different constants, so it can never be true. Its only effect would be harmful: the
   `if (judgeCMD(b4))` branch (BM:300-302) would read **2 more** bytes and discard the first,
   desyncing the stream. Because it's always false, the else path (BM:307-309) always runs and
   the framing is correct — but the intended "first byte is a known command" fast-path never
   executes. It is also the **only** in-code reference to `CMD_HISTORY_BEGIN_1`.

2. **No history-response parser (§2.18).** `getHistory()`/`setHistoryStatus()`/`cleanAllHistory()`
   can be sent, but any `FE C9…`/`BD 8A…` response falls through the entire if/else-if chain
   unmatched. Nothing is read past its begin pair, so the next `read()` starts mid-payload →
   **the stream desyncs** and, once a parse throws, the loop tears down the connection.

3. **`setHistoryStatus` off-by-one + trailing garbage (§1.11).** Drops the last 2 list entries,
   mis-places the END sentinel, and appends 4 zero bytes; for lists shorter than 3 it corrupts
   the BEGIN sentinel.

4. **No checksum/length on telemetry frames.** A single dropped/extra byte desyncs the parser
   until it happens to realign on a known 2-byte begin. Any parse exception sets `mRunning=false`
   and fires `IOError` (BM:910-914), killing the read loop — the connection does not
   self-recover.

5. **Stale `setting_passiva` in gate frames (§1.5).** The BAL_STATUS handler never refreshes
   `setting_passiva`, yet every gate-control setter reuses it, so the passive-balance bit written
   back to the BMS reflects the last UI toggle, not the BMS's reported state.

6. **`SLEEP_SET_SUCCESS` ignores its end sentinel and fires no callback (§2.16).**

7. **`getCurTime` uses the invalid zone string `"GNT+8"` (Utils:55)** — the set-time command's
   timestamp is effectively UTC, not GMT+8.

8. **Handshake timeout never errors on the first attempt (§3).**

---

## 5. Corrections/additions vs the existing PROTOCOL.md

- **Endianness:** `CMD_BATTERY` capacity and `CMD_SET_TIME` year are **little-endian**, not
  big-endian as the doc's TX table states. The doc's SOC ASCII diagram also mislabels the
  capacities "24-bit BE" — they are u24 LE (the doc's own RX table had it right; the diagram is
  wrong).
- **Gate-frame cache:** the doc claims the STATUS frame populates `setting_passiva`. It does not
  — only `setting_mos`, `temcontorl_gate`, `smoke_gate`, `heat_gate` (BM:538-541).
  `setting_passiva` is UI-only.
- **`setHistoryStatus`:** the doc says the bug "looks like an off-by-one." Confirmed and
  characterized exactly: N-2 entries written, END misplaced, 4 trailing zero bytes, BEGIN
  corruption for N<3.
- **HISTORY never parsed:** confirmed there is no RX history decoder at all; the only reference
  is the dead `judgeCMD`.
- **`CMD_OTHER` (A7 4E):** 9 bytes read and discarded; no end sentinel, no callback; meaning
  undetermined.
- **`CMD_SETTING_RESPOND`:** fires `batteryRes(true)` **only** when payload byte0 == 4 (capacity
  ack); added.
- **`SLEEP_SET_SUCCESS`:** added — saves pref only, `[0]==0 ⇒ sleep on`, no end check, no
  callback.
- **OTA seq is big-endian** (the one BE value); full ACK/checksum/recall/resend math added,
  including `getRecallSum = -(seqHi+seqLo+8)`.
- **MTU** is sent by `MainModel` 1 s post-handshake (not part of `shakeHand`), value clamped
  ≤200 and cached in pref `sphere_mtu`; added.
- **Handshake-timeout quirk** and **ALL_DATA cancels the timeout / completes the handshake**
  added.
- Exact per-frame read lengths, offsets, and the exact Java scaling expressions added for every
  RX frame.

## 6. Could NOT determine

- Semantic labels for the two `CMD_SOC` capacities (remaining vs full/rated) and the two
  `CMD_EST_TIME` durations (to-full vs to-empty) — only the byte→argument mapping is certain;
  the code carries no names.
- Meaning/layout of the `CMD_OTHER` (A7 4E) 9-byte payload (discarded by the app).
- Meaning of unused payload bytes: `CMD_MOS_STATUS[2..5]`, `CMD_WARN_CUR_ALARM[3..4]`,
  `CMD_WARN_VOL_ALARM[2],[4],[5],[8]`, `CMD_TEMPUTER[0],[2]`.
- The `+2`/`+6` constants inside `getRecallSum` (`seqHi + 2 + seqLo + 6`) — reproduced exactly
  but their derivation (presumably the `01 01` header contributes 2; the `6` is unexplained) is
  not recoverable from the app.
- The history request/response wire format and the `CMD_HISTORY_BEGIN_2` / `CMD_HISTORY_END`
  usage (no code exercises them).
- Sign handling of pack current in `CMD_ALL_DATA` (magnitude only; direction must be inferred
  from load/charger flags or BAL_STATUS `s0`).
- Whether the BMS actually emits the frames the app never decodes — cannot be known from the
  app alone.
