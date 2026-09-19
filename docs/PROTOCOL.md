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

**Same across all three:** the UUIDs (FCF0 service, FCF1 write, FCF2 notify; Telink OTA
`e49a25e0…`), the sentinel framing, the handshake, every RX/TX command in the tables below,
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
| OTA | Telink service `e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1`, chars `…25f8`, `…28e1` |
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
| `CMD_GET_VERSION` | `41 54 2B 56 0D 0A` | ASCII `AT+V\r\n` |
| set BLE name | `41 54 2B 3D` + name + `0D 0A` | ASCII `AT+=<name>\r\n`; BMS replies `OK\r\n` |
| `CMD_GATE_CONTROL` | `C3 1E` + 8 bytes + `D4 3B` | see below |
| `CMD_BATTERY` (capacity) | `C5 60` + 3 bytes + `D6 2A` | Ah × 1000, **little-endian** u24 (BM `setBattery`, L168). **[deep pass]** `longToBytes` emits LSB first: `"100"` → `C5 60 A0 86 01 D6 2A`. Not BE. |
| `CMD_SET_TIME` | `C8 18` + `yLo yHi MM dd HH mm ss` + `D9 74` | year 16-bit **little-endian** (`intToBytes`, LSB first). **[deep pass]** 2026 → `EA 07`. Note: `getCurTime` uses the invalid zone `"GNT+8"` (typo for GMT+8) so the timestamp is effectively UTC. No UI caller. |
| `CMD_OPEN_SLEEP_CONTROL` | `AA CC 00 01 DD EE` | sleep mode on |
| `CMD_CLOSE_SLEEP_CONTROL` | `AA CC 01 01 DD EE` | sleep mode off |
| `CMD_SEND_MTU` | `C3 F2` + mtu + `ED CE` | |
| `CMD_GET_HISTORY` | `C6 7C CF 00 D7 52` | |
| `CMD_CLEAR_HISTORY` | `C7 46 D8 82` | |
| `CMD_SET_HISTORY_STATUS` | `FF CA BE 9A 00` + (id, 00)… + `FA 5F 81 DC` | BM L204; the loop bound looks off-by-one (`i3 < size*2`) |
| `CMD_BEGIN_UPDATE` | `EB 90 00 07 BB 03 40` | OTA start (BM `update`, L173) |
| `CMD_UPDATE_FINISH` | `01 01 EC 00 00 12` | |
| `CMD_UPDATE_END` | `AA BB 01 02 03 04 CC DD` | |

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
