# JoySuny BMS — History subsystem + cross-version diff/completeness audit

Scope: the three jadx decompiles.

- Sphere Battery 1.0.24 — `com.joysuny.batteryutil` — `artifacts/sphere-battery-1.0.24/jadx/sources/com/joysuny/batteryutil/`
- RV Battery 1.0.2 — `com.joysuny.mimibattery` — `artifacts/rv-battery-1.0.2/jadx/sources/com/joysuny/mimibattery/`
- RV Battery 1.0.4 — `com.joysuny.mimibattery` — `artifacts/rv-battery-1.0.4/jadx/sources/com/joysuny/mimibattery/`

Byte values below are given as hex; the decompiles store them as signed decimal (jadx). All
cited line numbers verified against the trees named above. "Sphere BM" = Sphere
`blemanager/BatteryManager.java`; "RV1.0.2 BM"/"RV1.0.4 BM" the same file in each RV tree.

---

# A) THE HISTORY SUBSYSTEM

## A.1 Definitive answer

**History is a stubbed, abandoned feature. In all three builds it is (a) never invoked by any
UI/ViewModel/Model, (b) has no response parser anywhere in the read loop, and (c) its one
encoder (`setHistoryStatus`) is mis-coded and produces a malformed frame for every possible
input.** The real battery returns nothing to `CMD_GET_HISTORY` because the shipping firmware's
history path was never driven by the shipping app — the official app never sends the enable
frame, never sends `CMD_GET_HISTORY`, and cannot decode a reply. There is no client-side
history screen, bean, adapter, or decoder in any build.

This is the same across Sphere 1.0.24, RV 1.0.2 and RV 1.0.4 (the relevant code is
byte-for-byte the same; only line numbers shift).

## A.2 Every history reference in every build (exhaustive)

Search across all `com/joysuny/**` sources. The **only** app-code files that mention history
are `BatteryManager.java`, `BatteryCMD.java`, and `R.java` (two leftover resources). There is
**no** `HistoryBean`, `HistoryData`, history list/adapter/fragment/activity/dialog class, and
**no caller** of `getHistory()`, `setHistoryStatus()`, or `cleanAllHistory()` anywhere.

### Command-table constants (identical in all three `BatteryCMD.java`)

| Constant | Bytes (hex) | Sphere line | RV1.0.2 / RV1.0.4 line |
|---|---|---|---|
| `CMD_HISTORY_BEGIN_1` | `FE C9` | 25 | 26 / 26 |
| `CMD_HISTORY_BEGIN_2` | `BD 8A` | 26 | 27 / 27 |
| `CMD_HISTORY_END` | `EA 4F 80 DE` | 27 | 28 / 28 |
| `CMD_SET_HISTORY_STATUS_BEGIN` | `FF CA BE 9A` | 44 | 45 / 45 |
| `CMD_SET_HISTORY_STATUS_END` | `FA 5F 81 DC` | 45 | 46 / 46 |
| `CMD_CLEAR_HISTORY` | `C7 46 D8 82` | 52 | 53 / 53 |
| `CMD_GET_HISTORY` | `C6 7C CF 00 D7 52` | 53 | 54 / 54 |

### Methods (Sphere BM L200-224; RV BM L183-207 — identical logic)

- `getHistory()` — `send(CMD_GET_HISTORY)`. **No caller.**
- `setHistoryStatus(List<Integer>)` — builds the enable frame (see A.4). **No caller.**
- `cleanAllHistory()` — `send(CMD_CLEAR_HISTORY)`. **No caller.**

### Leftover resources (unused)

- `R.color.dialog_history` (Sphere R.java L3648 `0x7f050094`; RV `0x7f050090`). It is a
  **color** (siblings `dial_red`, `dialog_close`, `dialog_tips`, `dialog_title_blue`), not a
  screen. Referenced only in `R.java`.
- `R.string.dialog_history_warning_title` (Sphere R.java L10260). Referenced only in `R.java`.

Neither resource is inflated or looked up anywhere in code — dead assets, not a history UI.

## A.3 CRITICAL QUESTION — does ANY build parse a history response frame? **NO.**

The entire reader is `BatteryManager.ProcessWatchRunnable.run()` (Sphere BM L275-918; RV BM
from L257). It reads a 2-byte begin sentinel and dispatches with a fixed `if/else if` chain of
`ByteUtils.byteCompare(bArr, …)`. The complete list of begin-pairs it matches, in all three
builds, is:

`CMD_VOL_BEGIN`, `CMD_TEMPUTER_BEGIN`, `CMD_ALL_DATA_BEGIN`, `CMD_MOS_STATUS_BEGIN`,
`CMD_BAL_STATUS_BEGIN`, `CMD_OTHER_BEGIN`, `CMD_SOC_BEGIN`, `CMD_EST_TIME_BEGIN`,
`CMD_WARN_TEMP_ALARM_BEGIN`, `CMD_WARN_CUR_ALARM_BEGIN`, `CMD_WARN_VOL_ALARM_BEGIN`,
`CMD_SETTING_RESPOND_BEGIN`, `CMD_NAME_SET_1`, `CMD_GATE_SET_BEGIN`, `CMD_VERSION_BEGIN`,
`CMD_UPDATE_RECALL_1`, `CMD_ACK_HEAD`, `CMD_UPDATE_SUCCESS_1`, `CMD_SLEEP_SET_SUCCESS_BEGIN`.

(Verified by enumerating every `byteCompare(bArr, …)` in each file: Sphere BM L312-874; RV1.0.2
BM L287-661; RV1.0.4 BM L287-661.)

**`CMD_HISTORY_BEGIN_1` (`FE C9`), `CMD_HISTORY_BEGIN_2` (`BD 8A`), `CMD_HISTORY_END`
(`EA 4F 80 DE`) and any `CMD_SET_HISTORY_STATUS` reply are absent from that chain in all three
builds.** So if a battery ever emitted a `FE C9 … EA 4F 80 DE` frame, the read loop would not
recognise the begin pair; it would fall through the whole `if/else` with no handler, loop back,
and — because there is no length field and the two history payloads (`FE C9`/`BD 8A`) are longer
than 2 bytes — the leftover payload bytes would be misread as subsequent begin sentinels,
desyncing the parser. Nothing is ever decoded into data. The history parse is **missing/dead
everywhere.**

`CMD_HISTORY_BEGIN_1[0]` (`FE`) does appear once more, in `judgeCMD` (Sphere BM L272; RV L254),
but `judgeCMD` ANDs 15 unequal comparisons together so it is a constant `false` — dead code, and
in any case it only guards how many bytes are pre-read, not history decoding.

`CMD_HISTORY_BEGIN_2` and `CMD_HISTORY_END` are referenced **nowhere** outside their own
declaration in `BatteryCMD.java` (confirmed by targeted grep). They are pure dead constants.

## A.4 `setHistoryStatus()` byte-by-byte — and why it is broken

Source (Sphere BM L204-220; RV BM L187-203 — identical):

```java
public void setHistoryStatus(List<Integer> list) {
    byte[] bArr = new byte[(list.size() * 2) + 9];
    System.arraycopy(CMD_SET_HISTORY_STATUS_BEGIN, 0, bArr, 0, 4); // bArr[0..3] = FF CA BE 9A
    bArr[4] = 0;                                                    // bArr[4]   = 00
    int i = 0, i2 = 0;
    for (int i3 = 5; i3 < list.size() * 2; i3 += 2) {              // <-- bug: bound is 2*N
        bArr[i3] = intToByte(list.get(i));                         //     id byte
        i2 = i3 + 1;
        bArr[i2] = 0;                                              //     00 separator
        i++;
    }
    for (int i4 = 0; i4 < 4; i4++)
        bArr[i2 + i4 + 1] = CMD_SET_HISTORY_STATUS_END[i4];        // FA 5F 81 DC
    send(bArr);
}
```

**Intended layout** (implied by the `2N+9` array size):
`FF CA BE 9A | 00 | (id,00) × N | FA 5F 81 DC` — 4 + 1 + 2N + 4 bytes.

**Actual behaviour** — the loop condition `i3 < list.size()*2` is wrong (it should be
`i3 < 5 + 2N`). The loop runs for `i3 ∈ {5,7,…}` while `i3 < 2N`, i.e. `K = max(0, N-2)`
iterations. Consequences for `N` record ids:

- `N = 1` or `N = 2`: **K = 0**. `i2` stays `0`, so the END marker is written to `bArr[1..4]`,
  overwriting the BEGIN sentinel. Frame = `FF FA 5F 81 DC 00 …` — total garbage.
- `N = 3`: writes only id0; END at `bArr[7..10]`; the 15-byte buffer ends with trailing zeros.
- `N = 8`: writes ids 0..5 (6 of 8); the last two ids are dropped; END lands mid-buffer at
  `bArr[17..20]`, leaving `bArr[21..24]` = `00 00 00 00` trailing.

So for **every** input the frame is malformed: the last two ids are always dropped and either
the header is clobbered (N≤2) or garbage zero bytes trail the END marker. Combined with the fact
that the method has no caller, this is strong evidence the enable path was never tested and the
firmware side was never exercised by this app.

`CMD_GET_HISTORY` = `C6 7C CF 00 D7 52` looks like begin `C6 7C`, a 2-byte selector `CF 00`,
end `D7 52`; `CMD_CLEAR_HISTORY` = `C7 46 D8 82` is begin `C7 46` / end `D8 82` with no payload.
The `CF 00` selector and the meaning of the per-record ids are **unknown** (no UI ever supplies
them) — flagged uncertain.

## A.5 Does the read require enabling ids first? What to send?

Unknowable from the app with certainty, because the app never runs the sequence and the encoder
is broken. The *designed* intent (two begin markers `FE C9`/`BD 8A`, an enable frame keyed by
per-record ids, plus a clear command) is consistent with a firmware feature where you first
enable which record types stream, then request them. If you want to probe a live pack, try, in
order, and watch the notify characteristic for any `FE C9…`/`BD 8A……EA 4F 80 DE` frame:

1. Handshake as normal: write `CMD_BEGIN` `FB C8 7C 9D 26 EC`, subscribe notify.
2. Send a **correctly-formed** enable frame (the app's buggy one, fixed), e.g. enabling ids
   1..8: 
   `FF CA BE 9A 00 01 00 02 00 03 00 04 00 05 00 06 00 07 00 08 00 FA 5F 81 DC`
   (BEGIN `FF CA BE 9A`, reserved `00`, then `(id,00)` pairs, END `FA 5F 81 DC`). If the pack
   uses a single "all" selector, also try the minimal `FF CA BE 9A 00 FA 5F 81 DC`.
3. Send `CMD_GET_HISTORY` `C6 7C CF 00 D7 52`; also try flipping the `CF 00` selector bytes.
4. If nothing streams, the firmware in these consumer packs almost certainly does not implement
   the history readout (or only in a factory build). Treat history as **unavailable** rather
   than "missing enable step" — there is no evidence in any of the three apps that it ever
   worked. `cleanAllHistory()` → `C7 46 D8 82` is the only other lever and equally unproven.

Caveat: ids and selector semantics are guesses. There is no ground truth in the decompiles.

---

# B) CROSS-VERSION DIFF + COMPLETENESS AUDIT

## B.1 `BatteryCMD.java` is byte-identical across all three builds

I compared all 68 command constants byte-for-byte. **Every command has identical bytes in
Sphere 1.0.24, RV 1.0.2 and RV 1.0.4.** The only textual difference is cosmetic: jadx renders
the byte `61` as the literal `61` in Sphere (BatteryCMD L42) but as the named constant
`Base64.padSymbol` in both RV files (RV L43), because the RV builds also bundle
`kotlin.io.encoding.Base64` (whose `padSymbol` is declared `= 61`, confirmed at
`rv-battery-1.0.4/…/kotlin/io/encoding/Base64.java:26`). `61` = `0x3D` = `'='`.

### CORRECTION to `PROTOCOL.md`

The baseline table (PROTOCOL.md L33) says the RV BLE-rename command is `AT+@` (`41 54 2B 40`).
**That is wrong.** `CMD_SET_BLUETOOTH_NAME_BEGIN` is `{65, 84, 43, 61}` = `41 54 2B 3D` = `"AT+="`
in **all three** builds (Sphere L42; RV `{65,84,43,Base64.padSymbol}` where `padSymbol==61`).
`setBTName()` (Sphere BM L117; RV BM L99) uses this constant directly, and no code anywhere
constructs an `AT+@`/`0x40` variant (grep for `AT+`/`padSymbol`/`0x40` in a rename context finds
none). So the "BLE rename cmd" row of the matrix should read `AT+=` (`41 54 2B 3D`) for every
build, and the "one command that differs" caveat in PROTOCOL.md §Builds should be removed.

## B.2 Per-version difference matrix (corrected/extended)

Sources: `global/Global.java` in each tree; feature packages by directory presence.

| | Sphere 1.0.24 | RV 1.0.2 | RV 1.0.4 |
|---|---|---|---|
| Package | `com.joysuny.batteryutil` | `com.joysuny.mimibattery` | `com.joysuny.mimibattery` |
| Adv-name prefix `DEFAULT_BLUE_HEAD` | `JS` | `RV` | `RV` |
| **BLE-rename cmd** | `AT+=` (`41 54 2B 3D`) | `AT+=` (`41 54 2B 3D`) | `AT+=` (`41 54 2B 3D`) |
| Service-mode pwd (`DEFAULT_BACK_PWD`/`_PSW`) | `339933` | `339933` | `50176` |
| Per-device connect pwd (`DEFAULT_CONNECT_PASSWORD`) | `JS2023` | `RV2025` | `3445418` |
| Settings pwd (`DEFAULT_PASSWORD`) | `JS20230801` | `RV20250506` | `RV20250506` |
| Firmware-update pwd (`DEFAULT_UPDATE_PWD`) | `332211` | `332211` | `332211` |
| Firmware name-lock consts (`JS3_1_FILE`/`JS5_1_FILE`) | `PB51250506.bin` / `8803250506.bin` | none | none |
| `GLOBAL_BT_NAME` rename-store prefix | `Sphere_device_` | none | none |
| `GLOBAL_FILE_PATH` | `…/Sphere` | none | none |
| Firmware family consts (`JS3_1/JS3_2/JS5_1/JS5_2`) | present | none | none |
| QR device setup (zxing + `androidx.camera` + `ScanMainActivity`) | no | no | **yes** |
| Crash reporting `com.tencent.bugly` (+ native lib) | **yes** | no | no |
| Play licence `com.pairip.licensecheck` | no | **yes** | **yes** |
| `IS_INSIDE` flag | `true` (dead) | absent | absent |
| `IS_DEBUG` | `false` | `false` | `false` |
| Constant naming | `DEFAULT_BACK_PWD` | `DEFAULT_BACK_PSW` | `DEFAULT_BACK_PSW` |

Notes / evidence:
- Passwords: Sphere Global L8-12; RV1.0.2 Global L7-11; RV1.0.4 Global L7-11.
- QR: only `rv-battery-1.0.4` contains `com/joysuny/mimibattery/activity/ScanMainActivity.java`,
  `com/google/zxing/**` and `androidx/camera/**`.
- Bugly: only `sphere-battery-1.0.24` contains `com/tencent/bugly/**` (init in
  `application/BatteryApplication.java`).
- pairip: `com/pairip/licensecheck/**` present in both RV trees, absent from Sphere.
- `IS_INSIDE`: declared once (Sphere Global L15), referenced nowhere — dead.
- Sphere `Global` also uniquely carries the OTA name-lock/family constants and the
  `Sphere_device_`/`/Sphere` storage strings; the RV `Global` classes drop all of these.

Transport identifiers (`FCF0/FCF1/FCF2` UUIDs) are identical in all three `Global.java`.
`CMD_BEGIN` `FB C8 7C 9D 26 EC` is byte-identical in all three `BatteryCMD.java`. These parts of
PROTOCOL.md remain correct.

## B.3 Completeness audit — every constant in Sphere `BatteryCMD.java`

Legend: **Understood** = purpose fully established from code; **Dead** = declared but never
referenced outside its declaration; **Partial** = used but with an unexplained subfield.

| Constant | Bytes (hex) | Dir | Status | Notes |
|---|---|---|---|---|
| `CMD_SETTING_VOL` = 1 | `01` | — | **Dead** | Declared only. Never read; parser checks literal `4` only. |
| `CMD_SETTING_CUR` = 2 | `02` | — | **Dead** | Declared only. |
| `CMD_SETTING_TEMP` = 3 | `03` | — | **Dead** | Declared only. |
| `CMD_SETTING_BATTERY` = 4 | `04` | — | Understood | Value `4` matched (as literal) in SETTING_RESPOND parse → `batteryRes(true)` (Sphere BM L753). |
| `CMD_VOL_BEGIN/END` | `A0 C1` / `B1 D2` | RX | Understood | Per-cell mV; `getVolData` (BM L312). |
| `CMD_TEMPUTER_BEGIN/END` | `A1 4F` / `B2 E3` | RX | Understood | 2 signed temps; `getTemperature` (BM L347). |
| `CMD_ALL_DATA_BEGIN/END` | `A2 57` / `B3 6C` | RX | Understood | 24-byte telemetry → `BatteryAllDataBean` (BM L381). |
| `CMD_MOS_STATUS_BEGIN/END` | `A3 9F` / `B4 C7` | RX | Understood | `getMosStatus` (BM L507). |
| `CMD_BAL_STATUS_BEGIN/END` | `A8 AC` / `B9 21` | RX | Understood | 7-byte status frame; `getBalancerStatus`+SP caches (BM L530). |
| `CMD_SOC_BEGIN/END` | `A9 64` / `BA 5E` | RX | Understood | SOC%/remaining/full; `getSOC` (BM L564). |
| `CMD_EST_TIME_BEGIN/END` | `AA AF` / `BB 22` | RX | Understood | time-to-full/empty; `getEstTime` (BM L605). |
| `CMD_HISTORY_BEGIN_1` | `FE C9` | RX | **Dead** | Only in dead `judgeCMD`; never parsed. |
| `CMD_HISTORY_BEGIN_2` | `BD 8A` | RX | **Dead/unexplained** | Referenced nowhere. Second history record marker — semantics unknown. |
| `CMD_HISTORY_END` | `EA 4F 80 DE` | RX | **Dead/unexplained** | Referenced nowhere. |
| `CMD_VERSION_BEGIN/END` | `AC 9A` / `BD 10` | RX | Understood | `getVersion` (BM L800). |
| `CMD_UPDATE_SUCCESS_1/2` | `AA BB` / `01 02 EF` | RX | Understood | OTA success (BM L864). |
| `CMD_SLEEP_SET_SUCCESS_BEGIN/END` | `AC CA` / `DE ED` | RX | **Partial** | BEGIN handled (BM L874, reads 3 bytes, `[0]==0` toggles SP_SLEEP_MODE). END constant `DE ED` never checked. |
| `CMD_NAME_SET_1` | `0D 0A` | RX | Understood | `\r\n`; leads name-set ack (BM L767). |
| `CMD_NAME_SET_2` | `4F 4B 0D 0A` | RX | Understood | `OK\r\n`; `setNameRes` (BM L769). |
| `CMD_GATE_SET_BEGIN/END` | `D2 7E` / `FA 4B` | RX | Understood | 8-field gate ack; `gateRes(...)` (BM L772). |
| `CMD_SETTING_RESPOND_BEGIN/END` | `AB BA` / `CD DC` | RX | Understood | settings ack, type `4` = battery (BM L749). |
| `CMD_BEGIN` | `FB C8 7C 9D 26 EC` | TX | Understood | Handshake wake token (BM L104). |
| `CMD_GET_EST` | `C4 7D F4 D5 86` | TX | Understood | request est-time (BM L197). |
| `CMD_SET_BLUETOOTH_NAME_BEGIN` | `41 54 2B 3D` (`AT+=`) | TX | Understood | rename prefix; `setBTName` (BM L124). |
| `CMD_SET_BLUETOOTH_NAME_END` | `0D 0A` | TX | Understood | `\r\n`. |
| `CMD_SET_HISTORY_STATUS_BEGIN` | `FF CA BE 9A` | TX | **Understood-but-dead** | enable-frame header; encoder buggy (A.4); no caller. |
| `CMD_SET_HISTORY_STATUS_END` | `FA 5F 81 DC` | TX | **Understood-but-dead** | enable-frame trailer. |
| `CMD_GATE_CONTROL_BEGIN/END` | `C3 1E` / `D4 3B` | TX | Understood | 8-byte gate frame (setMos/Heat/etc.). |
| `CMD_BATTERY_BEGIN/END` | `C5 60` / `D6 2A` | TX | Understood | rated capacity Ah×1000 (BM L168). |
| `CMD_SET_TIME_BEGIN/END` | `C8 18` / `D9 74` | TX | Understood | RTC set (BM L191). No caller found in app UI — flagged as likely-unused but function is clear. |
| `CMD_CLEAR_HISTORY` | `C7 46 D8 82` | TX | **Understood-but-dead** | `cleanAllHistory`; no caller. |
| `CMD_GET_HISTORY` | `C6 7C CF 00 D7 52` | TX | **Partial-dead** | `getHistory`; no caller; `CF 00` selector unexplained. |
| `CMD_GET_VERSION` | `41 54 2B 56 0D 0A` (`AT+V\r\n`) | TX | Understood | `getVersion()` (BM L114). |
| `CMD_OPEN_SLEEP_CONTROL` | `AA CC 00 01 DD EE` | TX | Understood | sleep on (BM L133). |
| `CMD_CLOSE_SLEEP_CONTROL` | `AA CC 01 01 DD EE` | TX | Understood | sleep off (BM L135). |
| `CMD_SEND_MTU_BEGIN/END` | `C3 F2` / `ED CE` | TX | Understood | `sendMtu` (BM L144). |
| `CMD_WARN_CUR_ALARM_BEGIN/END` | `A4 8B` / `B5 DD` | RX | Understood | current alarms (BM L677). |
| `CMD_WARN_VOL_ALARM_BEGIN/END` | `A5 99` / `B6 17` | RX | Understood | voltage alarms (BM L710). |
| `CMD_WARN_TEMP_ALARM_BEGIN/END` | `A6 C0` / `B7 72` | RX | Understood | temp alarms (BM L635). |
| `CMD_OTHER_BEGIN` | `A7 4E` | RX | **Unexplained** | Matched (BM L562) then **9 bytes read and discarded** — no end check, no listener. Payload meaning unknown. |
| `CMD_BEGIN_UPDATE` | `EB 90 00 07 BB 03 40` | TX | Understood | OTA start (BM L183). |
| `CMD_UPDATE_RECALL_1/2` | `FF 01` / `B1 02 EF` | RX | Understood | OTA restart-from-0 (BM L825). |
| `CMD_ACK_HEAD` | `01 01` | TX/RX | Understood | OTA data-frame head + chunk-ack begin (BM L835). |
| `CMD_UPDATE_FINISH` | `01 01 EC 00 00 12` | TX | Understood | OTA finish (BM L924). |
| `CMD_UPDATE_END` | `AA BB 01 02 03 04 CC DD` | TX | Understood | OTA end (BM L188). |

### Constants/frames NOT fully explained anywhere (call-outs)

1. **`CMD_HISTORY_BEGIN_2` (`BD 8A`) and `CMD_HISTORY_END` (`EA 4F 80 DE`)** — the shape of the
   history *response* (two distinct begin markers + a 4-byte end). Referenced nowhere; never
   decoded. The two begin markers suggest ≥2 record types, but the record layout is entirely
   unknown from the apps.
2. **`CMD_GET_HISTORY` selector `CF 00`** — the middle two bytes of `C6 7C CF 00 D7 52`. Likely a
   record/range selector; meaning unknown.
3. **`setHistoryStatus` record ids** — the `List<Integer>` values are never supplied by any UI,
   so which BMS record types the ids `1,2,3,…` denote is unknown.
4. **`CMD_OTHER_BEGIN` (`A7 4E`)** — a 9-byte RX frame that the app reads and throws away. Purpose
   unknown; could be a heartbeat, an extra telemetry block, or reserved.
5. **`CMD_SETTING_VOL/CUR/TEMP` (1/2/3)** — declared as settings-ack type discriminators but the
   parser only ever handles type `4` (battery capacity). The vol/cur/temp settings-ack paths are
   unimplemented; whether the firmware emits them is unknown.
6. **`CMD_SLEEP_SET_SUCCESS_END` (`DE ED`)** — declared but the sleep-ack handler never validates
   the end sentinel (reads 3 bytes and checks only `[0]`), so the frame's full length/shape is
   unconfirmed.

Everything else in the Sphere command table is fully accounted for by the read loop and the TX
setters, and matches PROTOCOL.md.

---

# C) Net corrections/additions to `PROTOCOL.md`

1. **BLE-rename cmd is `AT+=` (`41 54 2B 3D`) in ALL three builds**, not `AT+@` for RV. The
   `BatteryCMD.java` command tables are byte-identical across all three builds; remove the
   "except the one command noted" caveat. (RV's `Base64.padSymbol` == `61` == `'='`.)
2. **History is unimplemented/abandoned, not merely "we haven't sent the right frame."** No
   parser in any build; `getHistory`/`setHistoryStatus`/`cleanAllHistory` have no callers; the
   `setHistoryStatus` encoder is buggy for all inputs (drops last two ids; corrupts header for
   N≤2). PROTOCOL.md's TX table note "the loop bound looks off-by-one (`i3 < size*2`)" is correct
   and can be strengthened to "produces a malformed frame for every input; method is dead."
3. `CMD_HISTORY_BEGIN_2`/`CMD_HISTORY_END` are dead constants; the `FE C9 / BD 8A … EA 4F 80 DE`
   response is never decoded (PROTOCOL.md RX table lists `CMD_HISTORY` — flag it as "declared,
   never parsed in any build").
4. `CMD_SET_TIME` (`C8 18 … D9 74`) exists and is understood but appears to have no UI caller —
   note as likely-unused.
5. `CMD_OTHER` (`A7 4E`) is read-and-discarded (9 bytes), no end check — unexplained.
6. `CMD_SETTING_VOL/CUR/TEMP` (1/2/3) are dead; only `CMD_SETTING_BATTERY` (4) is handled.
