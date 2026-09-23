# JoySuny Sphere / RV Battery BLE protocol

One shared protocol across all three builds we have decompiled. The wire format below is
common to every version; only identifiers and passwords differ (see the matrix). Line refs
are to the **Sphere 1.0.24** tree — `artifacts/sphere-battery-1.0.24/jadx/sources/com/joysuny/batteryutil/`,
`blemanager/BatteryManager.java` (BM) and `blemanager/BatteryCMD.java` (CMD) — unless stated.

**Status.** The RX telemetry frames (VOL / TEMP / ALL_DATA / SOC / EST / MOS / BAL /
warnings / VERSION / SLEEP) have been **verified against live Sphere hardware** (two real
`JS-2C14AA` / `JS-2C14B8` packs, firmware `JS5.1`) via `python_ble/read_batteries.py`, and
re-derived line-by-line in a deep reverse pass. The exhaustive per-line write-ups live in
`docs/reverse/` (`01-ble-protocol.md` frames/commands, `02-transport-ibluz.md` the BLE
transport, `03-app-logic.md` the UI/gesture/passwords, `04-history-versions.md` history +
cross-version diff). Corrections from that pass are folded in below and flagged **[deep pass]**.
TX write commands (gate / capacity / time / OTA) and the `A7 4E` frame are decompile-only,
not exercised against hardware.

## Builds covered

| App | Package | Version | jadx tree |
|---|---|---|---|
| Sphere Battery | `com.joysuny.batteryutil` | 1.0.24 | `artifacts/sphere-battery-1.0.24/` |
| RV Battery | `com.joysuny.mimibattery` | 1.0.2 | `artifacts/rv-battery-1.0.2/` |
| RV Battery ("RV TECH") | `com.joysuny.mimibattery` | 1.0.4 | `artifacts/rv-battery-1.0.4/` |

**Same across all three:** the UUIDs (FCF0 service, FCF1 write, FCF2 notify; Actions/iBluz OTA-transparent UUID family
`e49a25e0…` (NOT Telink)), the sentinel framing, the handshake, every RX/TX command in the tables below,
the status frame, and the hidden service-mode gesture (logo ×4 → current ×4 → long-press
info → password). **[deep pass]** All three `BatteryCMD.java` are **byte-identical** — every
`CMD_*` constant, including the BLE-rename command (`AT+=` in all three), matches. The only
differences across builds live in `Global.java` (passwords, adv prefix, firmware name-locks)
and bundled libraries; see the per-version matrix below and `docs/reverse/04-history-versions.md`.

Package layout differs by app: Sphere puts view-models under `actvm/` `actmodel/` (plus
`fragmentvm/` `fragmentmodel/`); RV renames those to `vm/` `model/`. So a Sphere ref like
`actvm/MainViewModel.java` is `vm/MainViewModel.java` in the RV trees. `BatteryManager.java`
is a larger build in Sphere (68 KB) than RV (49 KB) but exposes the same command set.

## Per-version differences

| | Sphere 1.0.24 | RV 1.0.2 | RV 1.0.4 |
|---|---|---|---|
| Adv-name prefix (`DEFAULT_BLUE_HEAD`) | `JS` | `RV` | `RV` |
| BLE rename cmd (`CMD_SET_BLUETOOTH_NAME_BEGIN`) | `AT+=` (`41 54 2B 3D`) | `AT+=` (`41 54 2B 3D`) | `AT+=` (`41 54 2B 3D`) |
| Hidden service-mode pwd | `339933` | `339933` | **`50176`** |
| Per-device connect pwd | `JS2023` | `RV2025` | **`3445418`** |
| Settings-tab pwd (`DEFAULT_PASSWORD`) | `JS20230801` | `RV20250506` | `RV20250506` |
| Firmware-update pwd (`DEFAULT_UPDATE_PWD`) | `332211` | `332211` | `332211` |
| Firmware name-lock | `PB51250506.bin` / `8803250506.bin` | none | none |
| QR device setup | no | no | **yes** (`ScanMainActivity` + zxing + CAMERA) |
| Crash reporting | Tencent Bugly (+ native lib) | none | none |
| Play licence check | no | `pairip` licensecheck | `pairip` licensecheck |
| `IS_INSIDE` flag | present (dead) | absent | absent |

Notes: the settings passwords are brand + build date (`JS`+2023-08-01, `RV`+2025-05-06) — and
`250506` is the same stamp in the Sphere firmware filenames. RV 1.0.4 rotated the service-mode
and connect passwords to non-date values, published to Play 2026-09-15. Full per-build
provenance and hashes are in each tree's `PROVENANCE.md`.

## Transport

| | |
|---|---|
| Stack | Actions Semiconductor "iBluz" SDK (`com/actions/ibluz/`), `BluzDeviceBle` |
| Service | `0000FCF0-0000-1000-8000-00805F9B34FB` |
| Write char | `0000FCF1-…` (app → BMS) |
| Notify char | `0000FCF2-…` (BMS → app), CCCD `2902` |
| OTA / 2nd pipe | The app's SDK defaults name the Actions Technology (iBluz) OTA/transparent UUIDs `e49a25f8` (service) / `e49a25e0` (write) / `e49a28e1` (notify) — **not Telink** (Telink's are `00010203-…1910/2b12`). The app never uses them. A live GATT dump of a JS5.1 pack (2026-09-21) shows no `e49a` service at all; instead an undocumented service `11110001-1111-1111-1111-111111111111` with chars `11110002` (write-without-response) and `11110003` (notify, write). Writing the wake/AT frames to it produced no reply on a dormant pack. The bridge identifies itself over the standard Device Information service as Manufacturer `Nations`, Model `NS-BLE-1.0`, Serial `1.0.0.0-LE`, HW/FW/SW rev `1.0.0`, System ID `12 34 56 ff fe 9a bc de`, PnP ID `02 5e 04 40 00 00 03` — i.e. a Nations N32WB03x BLE SoC running Nations' stock BLE profile (the `1111…` service is the SDK's UART-transparent RDTSS service) with JoySuny's FCF0 service added. |
| Adv name | prefix `JS` (`Global.DEFAULT_BLUE_HEAD`); app stores renames as `Sphere_device_<name>` |
| MTU | app sends `C3 F2 <mtu> ED CE` after negotiation (BM `sendMtu`) |

## Handshake (BM `shakeHand`, L91)

1. start read loop (`startPull`)
2. TX `FB C8 7C 9D 26 EC` (`CMD_BEGIN`); 20 s handshake timeout
3. TX `C4 7D F4 D5 86` (`CMD_GET_EST`)
4. 2.5 s later TX a low-temp-protect gate frame `C3 1E 01 01 01 00 00 00 00 00 D4 3B` (`setLowTemProtect`)

After this the BMS streams frames on FCF2 continuously. There is no per-frame request for
VOL / TEMP / ALL_DATA / MOS / STATUS / SOC — they are unsolicited.

`CMD_BEGIN` (`FB C8 7C 9D 26 EC`) is an opaque magic token — no structure (byte sum mod 256 =
238, not self-checksumming; not ASCII), not per-device, not a nonce. It is **byte-identical
across all three builds** (Sphere 1.0.24, RV 1.0.2, RV 1.0.4), i.e. the same "wake word" the
shared BMS firmware pattern-matches — the one value a client must send to start the stream,
and the only thing here that was never rebranded between Sphere and RV.

## Framing

No length or checksum. Every message is a fixed 2-byte **begin** sentinel, a fixed-length
payload, and a fixed 2-byte **end** sentinel; the parser reads the begin bytes, then
`read(n)` for a known n, and checks the last two bytes match the expected end. A handful of
commands are single opaque blobs. The BLE-name commands are ASCII `AT+` strings.

The parser (BM `ProcessWatchRunnable`, L281 on) dispatches on the begin pair. Note `judgeCMD`
(L271) ANDs all the comparisons together, so it is always false — dead code.

## TX commands (app → BMS)

| Name | Bytes | Payload / notes |
|---|---|---|
| `CMD_BEGIN` | `FB C8 7C 9D 26 EC` | handshake |
| `CMD_GET_EST` | `C4 7D F4 D5 86` | request estimated time |
| `CMD_GET_VERSION` | `41 54 2B 56 0D 0A` | ASCII `AT+V\r\n`. The reply is the framed `CMD_VERSION` **plus one stray ASCII `'0'` byte (`0x30`)** — see "AT+V stray byte" below. |
| set BLE name | `41 54 2B 3D` + name + `0D 0A` | ASCII `AT+=<name>\r\n`; BMS replies `OK\r\n` |
| `CMD_GATE_CONTROL` | `C3 1E` + 8 bytes + `D4 3B` | see below |
| `CMD_BATTERY` (capacity) | `C5 60` + 3 bytes + `D6 2A` | Ah × 1000, **little-endian** u24 (BM `setBattery`, L168). **[deep pass]** `longToBytes` emits LSB first: `"100"` → `C5 60 A0 86 01 D6 2A`. Not BE. |
| `CMD_SET_TIME` | `C8 18` + `yLo yHi MM dd HH mm ss` + `D9 74` | year 16-bit **little-endian** (`intToBytes`, LSB first). **[deep pass]** 2026 → `EA 07`. Note: `getCurTime` uses the invalid zone `"GNT+8"` (typo for GMT+8) so the timestamp is effectively UTC. No UI caller. |
| `CMD_OPEN_SLEEP_CONTROL` | `AA CC 00 01 DD EE` | **Bluetooth standby** mode ON (a persistent BMS setting — see "Sleep mode is Bluetooth Standby" below) |
| `CMD_CLOSE_SLEEP_CONTROL` | `AA CC 01 01 DD EE` | sleep mode off |
| `CMD_SEND_MTU` | `C3 F2` + mtu + `ED CE` | |
| `CMD_GET_HISTORY` | `C6 7C CF 00 D7 52` | |
| `CMD_CLEAR_HISTORY` | `C7 46 D8 82` | |
| `CMD_SET_HISTORY_STATUS` | `FF CA BE 9A 00` + (id, 00)… + `FA 5F 81 DC` | BM L204; the loop bound looks off-by-one (`i3 < size*2`) |
| `CMD_BEGIN_UPDATE` | `EB 90 00 07 BB 03 40` | OTA start (BM `update`, L173) |
| `CMD_UPDATE_FINISH` | `01 01 EC 00 00 12` | |
| `CMD_UPDATE_END` | `AA BB 01 02 03 04 CC DD` | |

#### "Sleep mode" is Bluetooth Standby (vendor help text, RV build)

The RV build's guide screen (`strings.xml` `guide_standby_mode`) is the only place
the vendor explains `CMD_OPEN/CLOSE_SLEEP_CONTROL`: *"When the BT standby is set to
ON this means if the BMS doesn't detect any charging or discharging taking place
the BT will go into standby mode to save energy. As soon as a load or charging is
detected the BT will automatically turn back on until no activity is detected. To
turn BT standby back to OFF you will need to apply charging or a load and then open
the app and Select OFF. Once the BT standby is turned to OFF the BT will always be
transmitting even when there is no charging or loads applied."* Default OFF.

Live-confirmed 2026-09-20: with standby ON a pack that is connected and idle keeps
streaming (it is a policy, not a "go to sleep now" command; the `AC CA` ack only
mirrors the stored flag). A pack whose OUTPUT was switched off (both MOS = 0)
cannot see a load, idled into standby and became a *bridge-alive, BMS-dormant*
pack: the BLE module still connects and answers `AT+V` with its `'0'` status byte,
but no framed command (CMD_BEGIN, gate frames, sleep-off) reaches the BMS. Only
charge/load current wakes it. Output-off + standby-on is therefore the combination
to warn about; the vendor app never handles a silent pack at all (it just forces
both MOS on 2.5 s after every handshake).

#### AT+V stray byte (`0x30`) — live-confirmed 2026-09-20

The only bytes the BMS ever sends that are not part of a framed message are
single stray `0x30` (ASCII `'0'`) bytes, seen ~64 times across ~49k captured
frames, always within the first few seconds after a (re)connect. A live A/B
test settled their origin: 20 reconnects **with** `AT+V` produced exactly one
`0x30` on **14/14** good connects; 20 reconnects **without** `AT+V` produced one
on **1/13** (an outlier best explained as a buffered reply left over from another
central's `AT+V`, since the firmware has one TX buffer). Every connect in both
arms sent `CMD_BEGIN`, so the byte is **not** a wake/begin artefact: it is the
status/return-code character the firmware's AT-command bridge emits in reply to
`AT+V`, alongside the framed version. It is harmless — the byte-level resync
parser drops it and it is counted (`unrecognisedBytes`). Only `AT+V` triggers it.

### `CMD_GATE_CONTROL` payload (BM `setMos` / `setHeat` / `setPassiva` / `setRestart` / `setFactory`, L131–L166)

```
C3 1E  b0 b1 b2 b3 b4 b5 b6 b7  D4 3B
       |  |  |  |  |  |  |  +-- b7  factory reset    (1 = do it)
       |  |  |  |  |  |  +----- b6  passive balance  (1 = on)
       |  |  |  |  |  +-------- b5  restart          (1 = do it)
       |  |  |  |  +----------- b4  heater gate
       |  |  |  +-------------- b3  smoke gate
       |  |  +----------------- b2  temp-control gate
       |  +-------------------- b1  discharge MOS    (1 = on)
       +----------------------- b0  charge MOS       (1 = on)
```

Every setter re-sends the *whole* frame, filling the untouched fields from the last values
the app cached in SharedPreferences (`setting_mos`, `temcontorl_gate`, `smoke_gate`,
`heat_gate`, `setting_passiva`). **[deep pass]** Only four of those are populated from the
STATUS frame below (BM L538–541): `setting_mos`, `temcontorl_gate`, `smoke_gate`, `heat_gate`.
`setting_passiva` is written **only by UI view-models**, never from the BMS status — so the
passive-balance bit in every gate frame reflects the last UI toggle and can be stale relative
to the balancer state the BMS actually reports (BAL_STATUS `s3`). A stale cache can silently
flip a gate. The BMS acknowledges with `CMD_GATE_SET` `D2 7E … FA 4B` (BM L772) and/or
`CMD_SETTING_RESPOND` `AB BA … CD DC` (the latter fires **only** when its payload byte0 == 4,
i.e. the capacity-set ack).

## RX frames (BMS → app)

These are frames the **BMS sends to the app**. The Java source misleadingly prefixes them
`CMD_` (the same prefix it uses for real app→BMS commands); the first column below is our plain
name for the report, and the `Java constant` column keeps the original `CMD_*` identifier so you
can still grep the decompile.

| Report (BMS → app) | Begin | End | Java constant | What it carries |
|---|---|---|---|---|
| Cell voltages | `A0 C1` | `B1 D2` | `CMD_VOL` | count + per-cell mV → `getVolData` (BM ~L290) |
| Temperatures | `A1 4F` | `B2 E3` | `CMD_TEMPUTER` | two signed temps → `getTemperature` |
| Telemetry | `A2 57` | `B3 6C` | `CMD_ALL_DATA` | V/A/W, cells, cycles, flags → `BatteryAllDataBean`; **completes handshake** |
| MOS status | `A3 9F` | `B4 C7` | `CMD_MOS_STATUS` | charge+discharge FET on iff `[0]==[1]==1` (L507) |
| Current alarm | `A4 8B` | `B5 DD` | `CMD_WARN_CUR_ALARM` | over-current / short-circuit flags → `getCurWarnList` |
| Voltage alarm | `A5 99` | `B6 17` | `CMD_WARN_VOL_ALARM` | cell/pack over/under-voltage flags → `getVolWarnList` |
| Temperature alarm | `A6 C0` | `B7 72` | `CMD_WARN_TEMP_ALARM` | chip/MOS over/under-temp flags → `getTempWarnList` |
| Unknown status | `A7 4E` | — | `CMD_OTHER` | 9 bytes **read and discarded** by the app; no end check, no callback; meaning undetermined **[deep pass]** (L562) |
| Status (charge state + gates) | `A8 AC` | `B9 21` | `CMD_BAL_STATUS` | s0 charge-state, MOS, passive-bal, gate states (L530) — see diagram below |
| State of charge | `A9 64` | `BA 5E` | `CMD_SOC` | SOC% + two u24 LE capacities → `getSOC` |
| Time remaining | `AA AF` | `BB 22` | `CMD_EST_TIME` | two u24 LE seconds → `getEstTime` |
| Settings ack | `AB BA` | `CD DC` | `CMD_SETTING_RESPOND` | fires `batteryRes(true)` only when `[0]==4` (capacity ack) |
| Firmware version | `AC 9A` | `BD 10` | `CMD_VERSION` | 5 ASCII chars → `getVersion` |
| Sleep state | `AC CA` | `DE ED` (not checked) | `CMD_SLEEP_SET_SUCCESS` | `[0]==0`=sleep on else off; saves pref only, **no callback** (L874) |
| History | `FE C9` / `BD 8A` | `EA 4F 80 DE` | `CMD_HISTORY_BEGIN_1/2` | **never parsed** — see history note below |
| Gate-control ack | `D2 7E` | `FA 4B` | `CMD_GATE_SET` | echoes the 8 gate bits → `gateRes` (L772) |
| Name-set ack | `0D 0A` | `…OK\r\n` | `CMD_NAME_SET_1/2` | `\r\nOK\r\n`, ack for the `AT+=` rename |
| OTA acks | `FF 01 B1 02 EF`, `01 01 …`, `AA BB 01 02 EF` | | `CMD_UPDATE_RECALL/ACK_HEAD/UPDATE_SUCCESS` | firmware-update handshake (L932 on) |

### History is unavailable **[deep pass]**

History is a stubbed, abandoned feature in **all three** builds, confirmed by reading every
build byte-for-byte. There is **no code path anywhere that parses a history response**: the
history sentinels appear only inside the dead `judgeCMD` (BM L272), and no `byteCompare` in the
read loop ever matches `FE C9` / `BD 8A` / `EA 4F 80 DE`. `getHistory()`, `setHistoryStatus()`
and `cleanAllHistory()` exist in `BatteryManager` but have **zero callers** — no UI, no
view-model, no history screen or bean. `setHistoryStatus()` is itself mis-coded (loop bound
`i3 < size*2` instead of `5 + size*2`): it drops the last two ids, misplaces the END sentinel,
and corrupts the BEGIN sentinel for lists shorter than 3 — clear evidence it was never used.

Consequence, confirmed on live hardware: sending `CMD_GET_HISTORY` (`C6 7C CF 00 D7 52`) to a
real `JS5.1` pack returns **nothing**. Treat history as unavailable, not "a missing enable
step." A blind enable attempt (unproven; id/selector semantics unknown) would be a *corrected*
`FF CA BE 9A 00 …ids… FA 5F 81 DC` before `CMD_GET_HISTORY`, but there is no evidence the
firmware implements a response. If a `FE C9…` frame ever did arrive, the length-less parser
would desync and (on the next parse exception) tear down the connection.

Field layouts for VOL / TEMP / ALL_DATA / SOC / EST_TIME are given below, decoded from
BM L281–L620 and `BatteryAllDataBean.java`. All multi-byte integers are **little-endian**
(`ByteUtils.byteToInt` = u16 LE, `byteToLong` = u24/u32 LE). Several fields divide by an
integer *before* the float divide, so the truncation is real and caps resolution — the tables
reproduce the app's exact math. Payload offsets are 0-based from the first byte after the
2-byte begin sentinel. None of this is verified against a live pack; a reference Dart codec
that implements every frame below lives in `battery_reader/lib/battery_protocol.dart`.

### `CMD_VOL` — per-cell voltages (BM L312–L346)

```
A0 C1  n  [c0]…[c(n-1)]  B1 D2
```

`n` (1 byte) is the cell count, read on its own; then `n` cells of 2 bytes each, then the end
sentinel. Each cell is `u16 LE` in **millivolts** (raw, no scaling — cf. the ALL_DATA cell
fields, which are the same numbers ÷1000 → V). Delivered as `getVolData(n, List<int>)`.

### `CMD_TEMPUTER` — two temperatures (BM L347–L378)

```
A1 4F  p0 t1 p2 t2  B2 E3       payload = 6 bytes, end at p4,p5
```

| Off | Field | Type | Unit |
|---|---|---|---|
| p1 | temperature 1 | **signed** 8-bit (`v>127 ? v-256`) | °C |
| p3 | temperature 2 | **signed** 8-bit | °C |

p0 and p2 are ignored by the parser. Delivered as `getTemperature(t1, t2)`.

### `CMD_ALL_DATA` — main telemetry (BM L381–L470, `BatteryAllDataBean`)

```
A2 57  <24-byte payload>  B3 6C     end at p22,p23
```

| Off | Field | Type | Scaling → unit |
|---|---|---|---|
| p0..1 | pack voltage | u16 LE | ÷10 → V |
| p2..4 | pack current | u24 LE | `(v ÷ 100) ÷ 10.0` → A (magnitude; sign not carried here — use load/charger flags or BAL `s0`) |
| p5 | load connected | u8 | `!=0` |
| p6 | charger connected | u8 | `!=0` |
| p7 | chip temperature | u8 | °C |
| p8..9 | sum of cells | u16 LE | ÷10 → V |
| p10..11 | max cell voltage | u16 LE | `(v ÷ 10) ÷ 100.0` → V |
| p12..13 | min cell voltage | u16 LE | `(v ÷ 10) ÷ 100.0` → V |
| p14..15 | cell voltage delta | u16 LE | `(v ÷ 10) ÷ 100.0` → V |
| p16..17 | power | u16 LE | ÷10 → W |
| p18..19 | cycle count | u16 LE | count |
| p20..21 | average cell voltage | u16 LE | `(v ÷ 10) ÷ 100.0` → V |

The `÷100 then ÷10` (current) and `÷10 then ÷100` (cell voltages) are integer divisions in the
app, done before the float divide. Delivered as `getAllData(BatteryAllDataBean)`.

### `CMD_SOC` — state of charge and capacity (BM L564–L590)

```
A9 64  <9-byte payload>  BA 5E      end at p7,p8
```

| Off | Field | Type | Scaling → unit |
|---|---|---|---|
| p0 | state of charge | u8 | clamped to 0..100 → % |
| p1..3 | full / rated capacity | u24 LE | ÷1000 → Ah |
| p4..6 | remaining capacity | u24 LE | ÷1000 → Ah |

The call is `getSOC(pct, remaining, full)` — it passes **p4..6 first** (remaining, shown on the
main screen as `x.xx AH`) then **p1..3** (full, cast to int).

### `CMD_EST_TIME` — time remaining (BM L591–L620)

```
AA AF  <8-byte payload>  BB 22      end at p6,p7
```

| Off | Field | Type | Unit |
|---|---|---|---|
| p0..2 | time to full (while charging) | u24 LE | seconds |
| p3..5 | time to empty (while discharging) | u24 LE | seconds |

Both go through `Utils.secondToTime` → `"HH:MM:SS"` (hours zero-padded to ≥2 digits). The main
screen shows the charge value when BAL `s0 == 1`, the discharge value when `s0 == 2`, and blank
otherwise. Delivered as `getEstTime(chargeStr, dischargeStr)`.

The three alarm frames (`CMD_WARN_CUR_ALARM` A4 8B / `CMD_WARN_VOL_ALARM` A5 99 /
`CMD_WARN_TEMP_ALARM` A6 C0) are one flag byte per condition (`== 1` sets it); the exact
bit-to-string mapping is in the Dart codec's `_warnCur` / `_warnVol` / `_warnTemp` tables.

#### `CMD_WARN_TEMP_ALARM` — byte meanings (live-confirmed additions)

```
A6 C0  b0 b1 b2 b3 b4 b5 b6  B7 72      end at p7,p8
```

| Off | Meaning | Live fault? |
|---|---|---|
| p0 | chip over-temperature protection | yes |
| p1 | chip under-temperature protection | yes |
| p2 | **LATCHED over-temperature protection** — set by a *past* over-temp event and held at 1 after the pack has cooled; while set the BMS **inhibits charging** (observed: charger present, 0 A, cells stuck at 3.33 V for a full day). Cleared only by a BMS restart (`CMD_GATE_CONTROL` restart byte). Live-confirmed 2026-09-19/20: p2 went 1 → 0 after the restart and the SOC was re-derived 100 % → 93 %. | no — a warning (charging inhibited), not a live over-temp |
| p3 | MOS flag, meaning unknown (the app ORs p2 \| p3 into one "MOS over-temp" string) | no |
| p4 | under-temperature discharge protection | yes |
| p5 | under-temperature charge protection | yes |
| p6 | MOS flag, meaning unknown (the app shows it as "MOS protect") | no |

Only p0, p1, p4, p5 are genuine live temperature faults. p2 is decoded as its own latched
status (`overTempLatched` in the Dart codec, `overTempLatched` metric in the store); p3 and p6
remain unknown-meaning MOS flags and are captured as unknown-byte metrics so any change is caught.

### `CMD_BAL_STATUS` — the status frame (BM L530–L548)

```
A8 AC  s0 s1 s2 s3 s4 s5 s6  B9 21
       |  |  |  |  |  |  +-- s6  heater gate        -> pref heat_gate
       |  |  |  |  |  +----- s5  smoke gate         -> pref smoke_gate
       |  |  |  |  +-------- s4  temp-control gate  -> pref temcontorl_gate
       |  |  |  +----------- s3  passive balancing  -> getBalancerStatus(bool, s0)
       |  |  +-------------- s2  discharge MOS  \  app: "MOS on" iff s1 == s2 == 1
       |  +----------------- s1  charge MOS     /    -> pref setting_mos
       +-------------------- s0  charge state: 0 idle, 1 charging, 2 discharging
```

The normal main screen consumes only `s0` (dial label). `s3` is dropped there and only
surfaces in the hidden service screen (`fragment_dial.xml` → `sbtn_bla`), display-only.

## Frame table with value summaries and the sentinel pattern

Added 2026-09-23 from a read-only pass over every `CMD_*` constant in `BatteryCMD.java`, the
two reference parsers (`python_ble/read_batteries.py` `Parser.FIXED`, `battery_reader/lib/battery_protocol.dart`
`_fixed`) and three captures: `python_ble/logs/JS-2C14B8.log` + `JS-2C14AA.log` (2026-09-19
14:00–16:13, both packs) and the phone raw log (2026-09-19 20:38 → 2026-09-23 05:25, ~13.3 k
frames of each periodic type, mostly `JS-2C14B8`). Both packs are 4S LiFePO4, 100 Ah, firmware
`JS5.1`. Timestamps below are from those logs; `hh:mm:ss` alone means the 2026-09-19 Python log.

### Sentinel pattern

Every begin/end pair in the app, with the arithmetic that was tested. `Δ0 = end[0] − begin[0]`,
`Δ1 = end[1] − begin[1]` (mod 256). `Rule` says which rule the pair obeys.

| Frame | Dir | Begin | End | Δ0 | Δ1 | end[1] ⊕ begin[1] | Rule |
|---|---|---|---|---|---|---|---|
| VOL | RX | `A0 C1` | `B1 D2` | +11 | +11 | 13 | 1 |
| TEMPUTER | RX | `A1 4F` | `B2 E3` | +11 | +94 | AC | 1 |
| ALL_DATA | RX | `A2 57` | `B3 6C` | +11 | +15 | 3B | 1 |
| MOS_STATUS | RX | `A3 9F` | `B4 C7` | +11 | +28 | 58 | 1 |
| WARN_CUR_ALARM | RX | `A4 8B` | `B5 DD` | +11 | +52 | 56 | 1 |
| WARN_VOL_ALARM | RX | `A5 99` | `B6 17` | +11 | +7E | 8E | 1 |
| WARN_TEMP_ALARM | RX | `A6 C0` | `B7 72` | +11 | +B2 | B2 | 1 |
| OTHER (trailer observed on the wire, not in Java) | RX | `A7 4E` | `B8 29` | +11 | +DB | 67 | 1 |
| BAL_STATUS | RX | `A8 AC` | `B9 21` | +11 | +75 | 8D | 1 |
| SOC | RX | `A9 64` | `BA 5E` | +11 | +FA | 3A | 1 |
| EST_TIME | RX | `AA AF` | `BB 22` | +11 | +73 | 8D | 1 |
| VERSION | RX | `AC 9A` | `BD 10` | +11 | +76 | 8A | 1 |
| GATE_CONTROL | TX | `C3 1E` | `D4 3B` | +11 | +1D | 25 | 1 |
| GET_EST (5-byte, payload `F4`) | TX | `C4 7D` | `D5 86` | +11 | +09 | FB | 1 |
| BATTERY (capacity) | TX | `C5 60` | `D6 2A` | +11 | +CA | 4A | 1 |
| GET_HISTORY (payload `CF 00`) | TX | `C6 7C` | `D7 52` | +11 | +D6 | 2E | 1 |
| CLEAR_HISTORY (no payload) | TX | `C7 46` | `D8 82` | +11 | +3C | C4 | 1 |
| SET_TIME | TX | `C8 18` | `D9 74` | +11 | +5C | 6C | 1 |
| SETTING_RESPOND | RX | `AB BA` | `CD DC` | +22 | +22 | 66 | 2 |
| UPDATE_END (OTA, 8-byte) | TX | `AA BB` | `CC DD` | +22 | +22 | 66 | 2 |
| OPEN/CLOSE_SLEEP_CONTROL | TX | `AA CC` | `DD EE` | +33 | +22 | 22 | 2 |
| SLEEP_SET_SUCCESS | RX | `AC CA` | `DE ED` | +32 | +23 | 27 | 2 |
| SEND_MTU | TX | `C3 F2` | `ED CE` | +2A | +DC | 3C | — |
| GATE_SET (gate ack) | RX | `D2 7E` | `FA 4B` | +28 | +CD | 35 | — |
| HISTORY (4-byte sentinels) | RX | `FE C9 BD 8A` | `EA 4F 80 DE` | — | — | — | — (see below) |
| SET_HISTORY_STATUS (4-byte sentinels) | TX | `FF CA BE 9A` | `FA 5F 81 DC` | — | — | — | — (see below) |
| CMD_BEGIN (6-byte token) | TX | `FB C8 7C 9D 26 EC` | | | | | opaque |
| NAME_SET / rename | both | ASCII `AT+=` … `\r\n` / `\r\nOK\r\n` | | | | | ASCII |
| OTA family | both | `EB 90 00 07 BB 03 40`, `01 01 …`, `FF 01 B1 02 EF`, `AA BB 01 02 EF`, `01 01 EC 00 00 12` | | | | | bootloader dialect |

**Rule 1 — `end[0] = begin[0] + 0x11`.** Holds for all 18 pairs of the two *numbered* families:
the RX reports `A0`–`AC` (every one except `AB` and `AC CA`, which belong to rule 2) and the TX
commands `C3`–`C8` (every one except `C3 F2`). `begin[0]` is a sequential opcode — `A0`…`AC`
enumerates the 13 report types in order, `C3`…`C8` the six framed commands — and the end byte is
the opcode plus 0x11. The observed `A7 4E … B8 29` trailer of the OTHER frame fits this rule
exactly (`A7 + 11 = B8`), which is the evidence that `B8 29` is its end sentinel (see oddities).

**`end[1]` is not derivable from the begin pair.** Across the 18 rule-1 frames, `Δ1` takes 18
distinct values and `end[1] ⊕ begin[1]` 17, so neither an additive nor an XOR constant exists.
Also tested and rejected: one's/two's complement, nibble swap, bit reversal, rotate-by-k with
any constant, every affine map `a·begin[1] + c` and `a·begin[1] ⊕ c` (65 536 candidates each —
none fits more than 2 of 18, i.e. chance level), functions of `begin[0] + begin[1]` and
`begin[0] ⊕ begin[1]`, "sum of the four sentinel bytes is constant", and CRC-8 with polynomials
0x07 / 0x31 / 0x9B / 0x1D over the begin pair. VOL (`A0 C1 → B1 D2`, both bytes +0x11) is the
single coincidence. Conclusion: `end[1]` is an independently chosen per-frame magic byte; a
parser must carry the end pairs as a table, exactly as the app does. `util/ByteUtils.java`
contains no derivation either — its whole API is `byteJudge`, `byteToInt1`, `intToByte`,
`intToBytes`, `longToBytes`, `byteToInt`, `byteToIntHigh`, `byteToLong`, `byteCompare`, and the
read loop only ever `byteCompare`s literal constants (BM L312 onwards).

**Rule 2 — the "hex-word" family.** Four pairs are visibly hand-typed mnemonics where the end is
the begin with each hex letter moved along the alphabet: `AB BA → CD DC` and `AA BB → CC DD`
(A→C, B→D, i.e. +0x22 on both bytes); `AA CC → DD EE` and `AC CA → DE ED` (A→D, C→E). Palindromes
stay palindromes (`ABBA→CDDC`, `ACCA→DEED`). The sleep-control request `AA CC`/`DD EE` and its
ack `AC CA`/`DE ED` are byte-permutations of each other, as are `AA BB`/`CC DD` (OTA end) and
`AB BA`/`CD DC` (setting ack). These are the only pairs where `begin[0]` collides with a rule-1
opcode (`AA` = EST_TIME, `AC` = VERSION), which is why the app compares both begin bytes.

**Outliers.** `C3 F2 → ED CE` (MTU) shares the `C3` opcode with GATE_CONTROL but its end obeys
neither rule. `D2 7E → FA 4B` (gate ack) obeys neither. The history frames use **4-byte**
sentinels on both ends and are the only such frames: the RX begin `FE C9 BD 8A` is stored as two
2-byte constants (`CMD_HISTORY_BEGIN_1/2`) only because the reader compares two bytes at a time
(`judgeCMD` references `CMD_HISTORY_BEGIN_1[0]` alone), whereas the matching TX
`CMD_SET_HISTORY_STATUS_BEGIN` is one 4-byte array. The RX and TX history sentinels are
near-neighbours — TX begin = RX begin + `01 01 01 10` byte-wise, TX end = RX end + `10 10 01 FE` —
i.e. one set was derived from the other by nudging bytes, not by any rule. The OTA family is a
separate bootloader dialect: `EB 90` is the classic sync word, `AA BB … CC DD` its frame, `01 01`
the ACK head, and `CMD_UPDATE_FINISH` `01 01 EC 00 00 12` is itself a well-formed checksummed data
frame (chunk 0xEC00, length 0, checksum 0x12 → byte sum ≡ 0 mod 256).

### Per-frame value summary (what these packs actually send)

Payload offsets are 0-based after the begin pair and exclude the end pair; "Java read" is the
`mIO.read(n)` count (payload + 2 end bytes), which matches `Parser.FIXED` / `_fixed` for every
frame. The stream is unsolicited, in strictly ascending opcode order `A0 A1 A2 A3 A4 A5 A6 A7 A8
A9 AA` once per cycle, ~0.85 s per cycle (e.g. VOL at 2026-09-21 15:06:48.270, 49.096, 49.944,
50.786); `AC 9A` (version) and `AC CA` (sleep) are slotted in when triggered.

| Frame | Java read | Layout (offset → meaning, unit, endianness) | Values seen |
|---|---|---|---|
| `A0 C1` VOL | `n` then `2n`, end `B1 D2` | p0 = cell count n; then n × u16 LE mV | n = 4 in 13 569/13 569 frames. Cells 3246–3503 mV (`JS-2C14B8`: 3246 under ~90 A at 2026-09-21 15:07:21.932 `a0 c1 04 c8 0c c5 0c bb 0c ae 0c b1 d2`; 3503 at rest after charge 2026-09-21 10:32:10.567; `JS-2C14AA`: 3333–3339 over its 2 h). |
| `A1 4F` TEMPUTER | 6 | p0..p3 = four signed-8 °C; app reads p1 and p3 | **p0 == p3 in 18 487/18 487 frames; p1 == p2 in 14 293 and differs by 1 °C in 4 194** — the frame is two sensors each sent twice (A = p0/p3, B = p1/p2). 25–43 °C; sensor B is the one that heats under load (43 °C at 2026-09-21 15:09:10.177 `a1 4f 24 2b 2a 24 b2 e3` after the 90 A run; A peaks at 38). Never negative here. |
| `A2 57` ALL_DATA | 24 | p0..1 packV u16 ÷10 V; p2..4 current u24 ÷100 then ÷10 A (magnitude); p5 load flag; p6 charger flag; p7 chip °C; p8..9 cell sum ÷10 V; p10..11 max, p12..13 min, p14..15 delta, p20..21 avg cell mV (÷10 then ÷100 → V); p16..17 power ÷10 W; p18..19 cycles | packV 13.0–13.9 V, always == cell sum. Current 0–90.4 A (raw 90 496 at 2026-09-21 15:06:10.910, 1188.4 W); charging 13.8 A (raw 13 816) at 2026-09-21 10:27:11.143 with **load = charger = 0**. Sign never carried (no raw > 0x7FFFFF). p5 load = 1 in 5 887 frames, 5 111 of them at 0 A; p6 charger = 1 in 1 985 frames, all at 0 A on 2026-09-19 (charger present, charging inhibited by the latched over-temp) and **never while actually charging**; p5 and p6 never both 1. p7 chip = 0 in 18 468/18 468 (unused). Cell max/min/avg 3246–3503 mV, delta 0–39 mV (0x27 at 2026-09-21 06:48:18.843). Cycles 0 or 1 only (see oddities). |
| `A3 9F` MOS_STATUS | 8 | p0 charge MOS, p1 discharge MOS (app: on iff both 1); p2..p5 unknown | p0 == p1 in every frame; `01 01` in 13 501/13 512, `00 00` for 11 frames 2026-09-21 15:06:50.889–15:07:00.136 (deliberate MOS-off). p3 = 1 exactly once, 15:07:00.136 `a3 9f 00 00 00 01 00 00 b4 c7`, coincident with the short-circuit flag (below). p2, p4, p5 always 0. |
| `A4 8B` WARN_CUR_ALARM | 7 | p0 over-current discharge, p1 over-current charge, p2 short-circuit, p3..p4 unused | All zero except p2 = 1 in two frames, 2026-09-21 15:06:59.329 and 15:07:00.194 `a4 8b 00 00 01 00 00 b5 dd`, as the MOS was re-closed onto the ~90 A load (TX `c3 1e 01 01 01 …` 15:06:58.849); cleared by itself, MOS back on at 15:07:00.976, current 1.5 → 2.2 → 89 A by 15:07:10. |
| `A5 99` WARN_VOL_ALARM | 11 | p0 cell over-charge, p1 cell over-discharge, p3 delta alarm, p6 pack over-charge, p7 pack over-discharge, rest unused | All nine bytes zero in 13 247/13 247 frames. |
| `A6 C0` WARN_TEMP_ALARM | 9 | p0 chip OT, p1 chip UT, p2 latched OT (charge inhibit), p3 unknown MOS, p4 UT discharge, p5 UT charge, p6 unknown MOS | All zero except p2 = 1 in 5 192 frames — every frame from both packs on 2026-09-19 until the restart (last `JS-2C14AA` 16:13:38.101), 0 since. p0, p1, p3–p6 never set. |
| `A7 4E` OTHER | 9 (discarded) | 7 bytes + `B8 29` | `a7 4e 00 00 00 00 00 00 00 b8 29` in 13 496/13 496 frames — payload all zero, trailer constant. |
| `A8 AC` BAL_STATUS | 9 | s0 charge state 0/1/2, s1 charge MOS, s2 discharge MOS, s3 passive balance, s4 temp-control gate, s5 smoke gate, s6 heater gate | s0: 0 idle (13 139), 2 discharging (331, whenever load current flowed), 1 charging (3 frames 2026-09-21 10:27:11.392–12.427 at 13.8 A). s1 == s2 always, mirrors MOS frame (00 during the MOS-off test). s3 = 0, s4 = 1, s5 = 0, s6 = 0 in every frame. |
| `A9 64` SOC | 9 | p0 SOC %, p1..3 full u24 LE mAh, p4..6 remaining u24 LE mAh | p0 ∈ {100, 99, 98, 93, 83, 0}. full = 100 000 (`a0 86 01`) always. **remaining = p0 × 1000 exactly** in every frame (99 000 = `b8 82 01`, 93 000 = `48 6b 01`, 83 000 = `38 44 01`) — no finer resolution than the percentage. SOC 0 / remaining 0 only in the first two SOC frames after a BMS restart (2026-09-20 21:03:59.294 and .626 `a9 64 00 a0 86 01 00 00 00 ba 5e`), then 100 % again from 21:04:00.464. 100 → 93 after the 2026-09-19 restart; 100 → 83 one second after the factory-reset frame (2026-09-21 08:13:05.342). |
| `AA AF` EST_TIME | 8 | p0..2 time-to-full s, p3..5 time-to-empty s (u24 LE) | time-to-full = 0 in 13 456/13 456 frames. time-to-empty: 3 960 s minimum (66 min at ~90 A, 2026-09-21 15:05:29.918 `aa af 00 00 00 78 0f 00 bb 22`) up to a cap of 360 000 s = 100 h (`40 7e 05`, 10 910 frames, whenever idle); all 115 distinct values are multiples of 60 s; 0 only in the two post-restart frames. |
| `AC 9A` VERSION | 7 | p0..4 ASCII | `JS5.1` in 105/105 frames, 0.1–4 s after `AT+V`, accompanied by the stray `0x30`. |
| `AC CA` SLEEP_SET_SUCCESS | 3 (end not checked) | p0: 0 = standby on, 1 = off | End `DE ED` present in 167/167 frames. p0 = 1 in 163; p0 = 0 in 4 (2026-09-20 21:02:41.452, 0.3 s after `aa cc 00 01 dd ee`; 21:03:28.597; 21:08:09.799; 21:08:57.913). Sent unsolicited ~0.5 s after every `CMD_BEGIN` handshake and as the ack to `AA CC`. |
| `AB BA` SETTING_RESPOND | 3 | p0 type (1 vol, 2 cur, 3 temp, 4 capacity) | Never observed (no capacity/threshold write was ever sent). |
| `D2 7E` GATE_SET | 10 | p0..7 echo of the gate-control bytes | 20 frames, each 0.1–0.3 s after a `C3 1E` TX, from `JS-2C14B8` only. Echoes b0–b6 exactly, including restart b5 = 1 (`d2 7e 01 01 01 00 00 01 00 00 fa 4b`, 2026-09-20 21:02:56.061). **b7 is not echoed**: the factory frame `c3 1e 01 01 01 00 00 00 00 01 d4 3b` at 2026-09-21 08:13:04.305 was acked `d2 7e 01 01 01 00 00 00 00 00 fa 4b`. |
| `FE C9 BD 8A` HISTORY | — | never parsed | Never observed; 5 × `CMD_GET_HISTORY` sent (Python log 14:00:08 …) with no reply. |
| `0D 0A` NAME_SET | 4 | `OK\r\n` | Not exercised. |
| OTA acks | 3 / 4 / 3 | see "Firmware update" | Not exercised. |
| stray `0x30` | — | AT bridge return code | 153 single-byte notifications plus two `30 30`, always within seconds of `AT+V`. |

TX commands as actually used in these captures:

| TX | Bytes | When / count | Effect seen |
|---|---|---|---|
| `CMD_BEGIN` | `fb c8 7c 9d 26 ec` | every connect (233 handshakes + 7 wake ladders in the phone log) | stream starts within ~50 ms (20:38:46.604 TX → 20:38:46.654 first VOL) |
| `CMD_GET_EST` | `c4 7d f4 d5 86` | after every handshake (232) | nothing visible — EST is streamed regardless |
| `AT+V\r\n` | `41 54 2b 56 0d 0a` | after every handshake (228) + probes (273) | `AC 9A` VERSION + one `0x30` |
| `CMD_GATE_CONTROL` | `c3 1e b0…b7 d4 3b` | 39: restart 13, both MOS on 12, output on 6, charge on 4, output off 1, charge off 1, both off 1, factory 1 | `D2 7E` ack 0.1–0.3 s later; restart re-handshakes ~6 s later (21:03:52.720 → 21:03:58.877) |
| `CMD_OPEN/CLOSE_SLEEP_CONTROL` | `aa cc 00/01 01 dd ee` | 5 on, 1 off | `AC CA` ack within 0.3 s mirroring the flag |
| `CMD_GET_HISTORY` | `c6 7c cf 00 d7 52` | 5 (Python log) | no reply |
| capacity `C5 60`, time `C8 18`, MTU `C3 F2`, clear/set history, OTA, rename | | never sent | |

### Oddities found in this pass

- **`A7 4E` has an end sentinel after all.** The trailer `B8 29` is constant in 13 496/13 496
  frames and `B8 = A7 + 0x11` matches rule 1, so OTHER is a 7-byte all-zero payload plus a
  2-byte end — the same 7+2 shape as WARN_TEMP and BAL_STATUS, consistent with the app's
  `read(9)`. The app merely never checks it. Validating `B8 29` costs nothing and improves resync.
- **Temperature frame carries two sensors twice** (p0 = p3 always, p1 ≈ p2). The app's choice of
  p1 and p3 happens to pick one of each. The hotter sensor (B) is the one that tracks load.
- **The load/charger flags are not a current sign.** Load = 1 at 0 A 87 % of the time; charger = 1
  only during inhibited charging and never during real charging; current is unsigned. Direction
  has to come from BAL `s0` (1/2), as the doc already says — the flags mean "something attached".
- **Cycle count flickers 0 ↔ 1** within seconds on both packs on 2026-09-19 (`JS-2C14B8` cyc = 1 at
  14:00:20, 0 at 14:00:26, 1 at 14:00:29 …; 218 and 348 frames at 1) and is 0 ever since. It is
  not a monotonic counter on this firmware; do not trend it.
- **SOC remaining is SOC × 1000, full is always 100 000.** The two capacity fields add no
  information beyond the percentage byte on these packs.
- **First SOC / EST frames after a restart read 0** (2026-09-20 21:03:59.294–.653), then the real
  values. A reader should ignore SOC/EST for ~1 s after a post-restart handshake.
- **Gate ack does not echo the factory bit** (b7) although the frame was acted on: SOC dropped
  100 → 83 % one second later (2026-09-21 08:13:05.342).
- **MOS frame byte 3 = 1** exactly once, in the same cycle as the short-circuit flag when the MOS
  was re-closed onto a ~90 A load — a candidate "protection tripped" status bit (single
  observation). Both cleared within two cycles.
- **EST is minute-granular and capped at 100 h**; time-to-full has never been non-zero, so that
  field is unverified.
- **Java read lengths all match the parsers**: TEMP 6, ALL 24, MOS 8, BAL 9, SOC 9, EST 8,
  WARN_TEMP 9, WARN_CUR 7, WARN_VOL 11, SETTING 3, GATE_SET 10, VERSION 7, SLEEP 3, OTHER 9,
  NAME 4, OTA 3/4/3. No length inconsistency exists between the app and the two reference codecs.
- **About 600 BLE notifications carried two consecutive frames** (VOL+TEMP 21 B, TEMP+ALL 34 B,
  ALL+MOS 36 B, e.g. 2026-09-19 20:40:26.833 `a1 4f … b2 e3 a2 57 … b3 6c`). This is packing, not
  a frame type; a parser must treat the link as a byte stream.
- **Why VOL is count-prefixed**: it is the only field whose size differs by product (4S here; the
  app's `Global` names four firmware families), so the firmware sends `n` rather than fixing the
  frame length. Every other frame is fixed-size.
- **Why history has "two begins"**: it does not — `FE C9 BD 8A` is one 4-byte begin (its TX
  counterpart `FF CA BE 9A` is declared as a single 4-byte array), split only to suit the
  2-byte `byteCompare` reader. History and set-history-status are the only 4-byte-sentinel frames.

## Hidden service mode

Not linked from any menu. Unlock on the main screen (`actvm/MainViewModel.java` L130–L163):

1. tap the **logo** 4× within 2 s (`MultiClickListener`)
2. tap the **current readout** 4× within 2 s
3. long-press the **info icon**
4. password **`339933`** (`Global.DEFAULT_BACK_PWD`)

Any other click in between resets the sequence. This launches `BatteryActivity`:

- **Dial tab** — MOS and passive-balance status indicators (display-only), a "more" button
  forced `INVISIBLE` with an empty `more()` handler (stub).
- **Settings tab** — second password, default **`JS20230801`** (`Global.DEFAULT_PASSWORD`,
  user-changeable via `ResetDialog`, stored in pref `fragment_password`). Exposes: charge /
  discharge MOS on-off, **passive balancing on-off**, heater, sleep mode, restart, **factory
  reset**, rated capacity, temperature-unit conversion, firmware update, BMS version.
  **[deep pass]** There is **no** low-temp-protect control and **no** history read/clear control
  in the UI (the earlier note was wrong): `setLowTemProtect` is auto-sent during the handshake,
  not a UI toggle, and `getHistory`/`setHistoryStatus`/`cleanAllHistory` have no UI callers.
  Also note a second, **unauthenticated** path exists outside service mode: the main-screen
  info button opens a screen offering a BMS **restart** and a **capacity write** with no
  password and no confirmation (see `docs/reverse/03-app-logic.md`).

Other gates, all plain constants in `global/Global.java`:

| Constant | Value | Gates |
|---|---|---|
| `DEFAULT_CONNECT_PASSWORD` | `JS2023` | per-device connect prompt (`MainViewModel` L532) |
| `DEFAULT_UPDATE_PWD` | `332211` | firmware update (`UpdateActivity`) |
| `IS_INSIDE` | `true` | referenced nowhere — dead |
| `IS_DEBUG` | `false` | |

Firmware families / OTA images named in `Global`: `JS1.0` → `PB51250506.bin`,
`JS5.1` → `8803250506.bin`; also `JS3.2`, `JS5.2`.

## Caveats

- No checksum or length field anywhere; a dropped byte desyncs the parser until the next
  recognised begin pair.
- Gate frames carry every gate on every write; drive them from a fresh STATUS frame, not a
  cache.
- MOS-off and factory-reset have no confirmation beyond the password.

## Verified in emulator (2026-09-15)

Pixel 6 AVD, Android 14 x86_64, app sideloaded from the XAPK splits, **no BLE device**.
The unlock works with nothing connected: all three gesture views are in the base layout with
no visibility toggle, and `BatteryViewModel.initManager()` simply skips creating the
`BatteryManager` when `mBluzConnector` is null, so the service screen opens and shows zeros.
Screenshots in `screenshots/`.

Driven via adb: `input tap` x4 on `iv_logo` (235 ms), x4 on `iv_cur` (184 ms), `input swipe`
1500 ms in place on `iv_info`, then `339933` -> `BatteryActivity`. Tab "Parameter" -> second
prompt (8-16 chars) -> `JS20230801`. Parameter tab rows as rendered, top to bottom:

MOS Switch (toggle) - Low Power Sleep Mode (toggle) - Heat Up (toggle) - Passive Equalization
Switch (toggle) - Restart BMS System - Restore To Factory Default - Battery Capacity (100 AH
default) - Reset User Password - Temp Unit Conversion - BMS Firmware Update - BMS Version
(placeholder "23.11.01" when unconnected).

Same-machine setup: SDK in `~/.local/opt/android-sdk`, AVD `sphere`, boot with
`emulator -avd sphere -no-window -no-audio -gpu swiftshader_indirect`.

## Behaviour notes (field questions)

### SOC is display-only — a stuck 100% is a BMS fault, not an app bug

The app does **not** compute state-of-charge. The `CMD_SOC` frame (`A9 64` … `BA 5E`, BM
L564–L583) carries SOC directly:

```
A9 64  p  f f f  r r r  BA 5E
       │  └─────┐└─────┐
       │        │       └ capacity B (u24 LE, /1000 = Ah)  -> getSOC arg f (bytes 4..6)
       │        └───────── capacity A (u24 LE, /1000 = Ah)  -> getSOC arg f2 (bytes 1..3)
       └────────────────── SOC %  (byte, clamped to 0..100) -> getSOC arg pct, drives the dial
```

**[deep pass]** Both capacities are **little-endian** (`byteToLong`, LSB first), not BE. The
byte→argument mapping is certain (`getSOC(pct, bytes4..6/1000, bytes1..3/1000)`, BM L583) but
the semantic labels **remaining vs full/rated are not stated in the code** — the app only logs
the two raw values. Our reader labels bytes 4..6 = remaining and 1..3 = full, which is
consistent with the main screen showing the first as `"x.xx AH"`, but this is inference, not
code-confirmed. On live hardware both read 100.0 Ah at 100% SOC, which fits either reading.

`p` is shown on the dial as-is (only clamped 0..100). So a battery that "always shows 100%"
is the **BMS reporting 100** in that byte — the app is a dumb display. Classic LiFePO4
coulomb-counter drift: the flat discharge curve means the gauge only re-anchors at a real
full charge / full cut-off. The manufacturer confirms this — the Sphere EVO user guide calls
it *"learning SoC monitoring via the Bluetooth app"* (see REFERENCES.md): the gauge is a
learned coulomb-counter in the BMS, so a fresh or mis-learned pack reads wrong until a full
cycle re-anchors it. Fixes, in order: verify against Sum Volt + Current (100% may be
correct); do a full charge→discharge→charge recalibration cycle; else `Restart BMS` then
`Restore To Factory Default` from the hidden Parameter tab; check `Battery Capacity` matches
the pack's real Ah. If it never moves off 100 through a full cycle, the BMS gauge is faulty
(warranty).

### MOS Switch = the battery's master output (charge + discharge FETs together)

The single "MOS Switch" toggle drives **both** the charge and discharge MOSFETs to the same
state. `setMos(z)` (BM L164) sends a `CMD_GATE_CONTROL` frame with byte0 (charge MOS) = byte1
(discharge MOS) = z:

```
C3 1E  z z  temp smoke heat  00  passiva 00  D4 3B     (z = 1 on / 0 off)
```

So turning it **off electrically disconnects the battery** — no charge in, no load out; the
pack goes dark at the terminals (the BMS stays alive on its own rail and still talks BLE).
Turning it on re-enables output. It is the software equivalent of the pack's main
enable/isolator, distinct from the automatic protection trips (over-/under-voltage, OCP, OTP)
the BMS does on its own. The status readback (`CMD_MOS_STATUS` `A3 9F` … `B4 C7`, BM L507)
reports "on" only when byte0 AND byte1 are both 1, so if the BMS has tripped one FET on its
own the app shows MOS off.

Caveat matching the app: there is **no confirmation dialog** on this toggle. Switching MOS
off on a battery that is currently powering a load cuts that load instantly.

## Firmware update (OTA over the FCF0 link)

The app carries **no firmware** and downloads none — no `.bin` in assets, no update URL in
the code. `UpdateViewModel.selectFile()` ([UpdateViewModel L60]) opens the Android document
picker (`OPEN_DOCUMENT`, octet-stream); the user supplies a `.bin` already on the phone and
the app streams it to the BMS. So the images are distributed out-of-band by JoySuny / the
dealer, not published anywhere.

### File name-lock and family mapping (Sphere)

`UpdateActivity.onActivityResult` (L119–123) only accepts a picked file whose name is exactly:

| `Global` const | File name | For BMS family |
|---|---|---|
| `JS3_1_FILE` | `PB51250506.bin` | JS1.0 / JS3.x (when `mIsNewest == false`) |
| `JS5_1_FILE` | `8803250506.bin` | JS5.x (when `mIsNewest == true`) |

`MainModel` L392–394 maps the version string the BMS reports (`CMD_VERSION`) to the family:
`JS5.1`/`JS5.2` → family 5, `JS3.1`/`JS3.2` → family 3. The `250506` in both names is a date
(2025-05-06), the same stamp as the `RV20250506` settings password; `PB51` / `8803` look like
board/chip prefixes. **RV Battery 1.0.4 dropped the name-lock** — its picker takes any file.

### Wire sequence (BM `update` → `beginUpdate` → `beginSendUpdateFile` → `endUpdate`)

1. `EB 90 00 07 BB 03 40` (`CMD_BEGIN_UPDATE`); 20 s handshake timeout.
2. BMS drives the transfer by ACKing chunk numbers. For chunk `i` the app sends a data frame
   and waits (2 s resend timer); on the matching ACK it does `mCurNum++` and sends the next.
3. **Data frame** (`beginSendUpdateFile`):

   ```
   01 01  seqHi seqLo  len  <payload…len>  cksum
   └─CMD_ACK_HEAD       │                   └ 1-byte two's-complement of the sum of all
          └ chunk index (u16 BE)              preceding bytes  (sum of whole frame == 0 mod 256)
                        └ payload length (u8)
   ```

   Payload size = `(MTU/10)*9 - 6` bytes (default pref MTU 20 → 12 B/chunk; larger after MTU
   negotiation). Payload is read straight from the file at offset `payloadLen * i` via
   `RandomAccessFile.seek` — the `.bin` is shipped raw, no header parsing app-side.
4. `FF 01` + `B1 02 EF` (`CMD_UPDATE_RECALL_1/2`) from the BMS = restart from chunk 0
   (`mCurNum = 0`).
5. When offset ≥ file length: 300 ms later send `01 01 EC 00 00 12` (`CMD_UPDATE_FINISH`).
6. `AA BB 01 02 03 04 CC DD` (`CMD_UPDATE_END`).
7. Success from BMS: `AA BB` (`CMD_UPDATE_SUCCESS_1`) + `01 02 EF` (`CMD_UPDATE_SUCCESS_2`).

Checksum (`getSum`): `(byte)(~sum + 1)` over the frame minus the checksum byte — i.e. the byte
that makes the 8-bit sum of the whole frame zero.

Gate: the update screen itself is behind the `332211` password (`DEFAULT_UPDATE_PWD`), reached
from the main screen's version check, not from the hidden service mode.

### Getting the actual images

Not in the app and not public (no hit for `PB51250506` / `8803250506` on the web or GitHub).
Only routes: obtain from JoySuny / the dealer (Coast to Coast RV), or capture a `.bin` from a
phone that has run an official update (app cache, the `/Sphere` storage folder, or by sniffing
this OTA stream off the FCF1 characteristic).

## Authentication: there is none on the wire

**Every password in these apps is an app-side UI gate. Nothing authenticates to the battery.**

- `PasswordDialog` validates locally: `mPassword.equalsIgnoreCase(mPwd)` (PasswordDialog
  L114) compares what the user types against a constant the app passed in (`JS2023`,
  `JS20230801`, `339933`, …). On match it calls `onConfirm()` and the UI advances. Nothing is
  transmitted.
- No TX command carries a password. Grepping every `send(...)` / `byte[]` for the connect,
  settings, service-mode and update passwords returns zero hits — none appear in any frame.
  The TX table has no auth field.
- The connect password (`DEFAULT_CONNECT_PASSWORD`) is used in exactly one place
  (`MainViewModel.clickOk`, L531) to gate a UI dialog before the app adds the device to its
  list. The BMS is never consulted.

The Sphere EVO user guide prints the connect password in the open — "The default Password
for Sphere Batteries is JS2023" (see REFERENCES.md) — underscoring that it is a convenience
gate, not a secret.

There is no BLE bonding/pairing, no challenge–response, no session key. The handshake is a
fixed constant (`FB C8 7C 9D 26 EC`). So **any** BLE central can read the full live stream:

1. connect to service `FCF0`
2. enable notifications on the notify characteristic
3. write `FB C8 7C 9D 26 EC` to the write characteristic

…and the BMS streams VOL / TEMP / ALL_DATA / SOC / STATUS unsolicited — from any phone,
regardless of who "owns" the battery. (Established from the code; not yet run against real
hardware.)

**Security implication:** the *write* commands are equally unauthenticated — `CMD_GATE_CONTROL`
(MOS-off, passive-balance, **factory reset**) and the OTA sequence take effect with no
on-wire credential. The app's password prompts are a speed bump in one particular app, not a
control on the battery; anyone in BLE range who knows the frame format (documented here) can
issue them. Good for us building an independent reader — it means read-only monitoring needs
no secrets — but worth stating plainly as a device-security property.

## For a read-only reader

Minimum to monitor without touching the app: connect FCF0, subscribe notify, write
`CMD_BEGIN`, then parse the RX frames. Do **not** send `setLowTemProtect` /
`CMD_GATE_CONTROL` / any TX write if the goal is passive monitoring — those change BMS state.
The stream is push-only, so a reader never needs to poll.
