# BMS families & multi-BMS support plan

Goal: let `battery_reader` read more than just Sphere/RV (JoySuny). This maps the major
LiFePO4 smart-BMS BLE families, how to tell them apart, and the wire protocol for each so
decoders can be implemented. Empirical column = apps installed from Play on a test phone and
fingerprinted (2026-09-19). Protocol column = compiled from open-source decoders — **verify
every offset against the cited source before shipping** (these are code-ready starting points,
not gospel; the sources are the ground truth).

## Detection: identify the family by BLE GATT service, then dispatch

A multi-BMS reader should scan the peripheral's services and pick a decoder by UUID. From the
apps we fingerprinted plus `aiobmsble`:

| Service (16-bit) | Notify / Write | Family | Detected in app | Notes |
|---|---|---|---|---|
| **`FCF0`** | `FCF1` notify? / write | **JoySuny** (Sphere, RV) | `com.joysuny.*` | our reversed protocol; adv name `JS-…` |
| **`FF00`** | `FF01` / `FF02` | **JBD / Xiaoxiang** | Stealth Batteries `com.stealth.bmsapp`; JBD app | most common; well-documented |
| **`FFE0`** | `FFE1` / `FFE1` | **JK (Jikong)** | JK app `com.jktech.bms` (exposes FFE0/1/2 + FF10/20/80) | header `55 AA EB 90` |
| **`FFE0`** | `FFE1` / **`FFE2`** | **Redodo / LiTime / Power Queen** | (not sampled) | same UUID as JK — disambiguate by frame header |
| **`FFF0`** | `FFF1` / `FFF2` | **Daly** (0xA5 or 0xD2) *or* generic bridge | LiFePO4 Power `com.dy.leadyo` (FFF0/FFF4/FFF6) | FFF0 is a transparent module — probe the payload |
| `FFF0`+`FFD0` | `FFF1` / `FFD1` | **Renogy** (Modbus) | (not sampled) | |

Because `FFE0` and `FFF0` are shared across families, after matching the UUID you must confirm
by the **response header**: `DD…77` = JBD, `55AAEB90` = JK, `A5…` = Daly-classic,
`D2 03…` = Daly-Modbus, `FB C8 7C 9D 26 EC`-handshake→`A2 57…` = JoySuny.

## Empirical fingerprint results (this session)

Installed from Google Play, pulled real APKs, grepped for service UUIDs + JoySuny markers:

| App | Package | Service triple found | Family | JoySuny markers |
|---|---|---|---|---|
| Sphere / RV Battery | `com.joysuny.batteryutil` / `mimibattery` | `FCF0/FCF1/FCF2` | JoySuny | (reference) |
| Stealth Batteries | `com.stealth.bmsapp` | `FF00/FF01/FF02` | **JBD** | none |
| LiFePO4 Power | `com.dy.leadyo` | `FFF0/FFF4/FFF6` | **Daly/generic** | none |
| JBD BMS | `com.jiabaida.xiaoxiangcloud` | 128-bit wrapper UUIDs (FF00 at runtime) | **JBD** | none |
| JK BMS | `com.jktech.bms` | `FFE0/FFE1/FFE2` (+FF10/FF20/FF80) | **JK** | none |

Conclusion: five apps, ≥4 distinct BMS families. **JoySuny's `FCF0` is unique to Sphere+RV.**
Competitor caravan brands sit on JBD / JK / Daly / Redodo — all of which already have
open-source decoders, so `battery_reader` can support them by porting known specs (below),
while JoySuny is the one we reversed ourselves.

## Protocol specs (implement from the cited source)

Primary source for all: **`github.com/patman15/aiobmsble`** (`aiobmsble/bms/<family>_bms.py`,
with real-capture tests) and **`github.com/syssi/esphome-jbd-bms` / `-jk-bms` / `-daly-bms`
(vendor PDFs under each `docs/`).

### JBD / Xiaoxiang — `FF00` svc, `FF01` notify, `FF02` write
- Request: `DD [A5 read|5A write] [reg] [len] [data…] [chkHi chkLo] 77`. Reads: basic `DD A5 03 00 FF FD 77`, cells `DD A5 04 00 FF FC 77`.
- Response: `DD [reg] [status] [len] [data…] [chkHi chkLo] 77`; reassemble across 20-byte notifies until `DD…77` and length matches. Checksum = `(0x10000 − sum(len+data)) & 0xFFFF`, big-endian. All fields **big-endian**.
- Reg 0x03 payload offsets: V@0 ×0.01V, I@2 ×0.01A(signed), remainCap@4 ×0.01Ah, cycles@8, SOC@19 (%), MOS@20 (bit0 chg,bit1 dis), #cells@21, temps@23+ `(raw−2731)×0.1°C`.
- Reg 0x04: N×uint16 mV. Src: `aiobmsble/bms/jbd_bms.py`, `syssi/esphome-jbd-bms`.

### JK (Jikong) — `FFE0` svc, `FFE1` notify+write
- Request 20B: `AA 55 90 EB [cmd] [len] [val:4 LE] … [crc=sum(bytes[0..18])&0xFF]`; cell-info cmd `0x96`.
- Response fixed **300B**, header `55 AA EB 90`, type@4 (`0x02`=cell info); crc=last byte=`sum(0..298)&0xFF`. Fields **little-endian**.
- Two layouts (24S vs 32S, everything after cell block shifted +32). 24S/32S offsets: pack V@118/150 ×0.001V, I@126/158 ×0.001A(signed), SOC@141/173 (%), remainCap@142/174 ×0.001Ah, cells@6 ×0.001V. Resolve layout from FW version (SW<v11 ⇒ −32). Src: `aiobmsble/bms/jikong_bms.py`, `syssi/esphome-jk-bms`.

### Daly — `FFF0`(or `FFE0`) module; classic `0xA5` 13-byte frames
- Frame: `A5 [40 req|01 reply] [cmd] 08 [d0..d7] [chk=sum(bytes[0..11])&0xFF]`, data **big-endian**.
- 0x90: V=d0-1 ×0.1V, I=(d4-5 −30000)×0.1A, SOC=d6-7 ×0.1%. 0x91 max/min cell mV. 0x92 temps `raw−40`. 0x93 MOS+remainCap(mAh). 0x95 cells (3/frame, mV). Newer H/K/M/S units use **0xD2 Modbus** instead (func 0x03, CRC-16/Modbus). Src: `maland16/daly-bms-uart`, `aiobmsble/bms/daly_bms.py`.

### Redodo / LiTime / Power Queen — `FFE0` svc, `FFE1` notify, `FFE2` write
- Request: `00 00 04 01 13 55 AA 17`. Response `[00 00][len][data…][crc=sum(:-1)&0xFF]`, **little-endian**. V@12 ×0.001V, I@48 ×0.001A(signed), SOC@90 (%), remainCap@62 ×0.01Ah, cells@16 ×0.001V. Src: `aiobmsble/bms/redodo_bms.py`.

## Consumer brand → family (for reference)

JBD: Overkill Solar, older Ampere Time, most no-name "Smart BMS". Redodo family: **LiTime /
Redodo / Power Queen** (same OEM). JK: Jikong DIY packs. Daly: Daly-equipped packs. Eco-Worthy,
Renogy, CBT Power/Creabest each have their own `aiobmsble` plugin. **JoySuny: Sphere, RV
Battery** (and possibly Phoenix's SolarKing/Stealth-Energy, unconfirmed — no app to check).

## Wiring into `battery_reader`

Suggested shape (not yet implemented — see `lib/battery_protocol.dart`):
1. A `BmsFamily` interface: `serviceUuid`, `notifyUuid`, `writeUuid`, `handshake()`,
   `decode(List<int> frame) → BatterySample`, plus a `matches(discoveredServices, firstFrame)`.
2. Implementations: `JoySunyBms` (done — our protocol), then `JbdBms`, `JkBms`, `DalyBms`,
   `RedodoBms` ported from the specs above.
3. On connect: enumerate GATT services → pick the family whose `serviceUuid` is present →
   confirm via first-frame header → run that decoder. Fall back to "unknown BMS" with a raw
   hex log (reuse `battery_log.dart`).
4. Keep the JoySuny path as the reference implementation; the others are additive.

Evidence APKs kept under `artifacts/_comparison/<pkg>/base.apk` (heavy — candidate for `.gitignore`).
