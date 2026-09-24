# AWTO BMS

A Flutter app that connects to a JoySuny BMS over Bluetooth Low Energy and
displays **all** telemetry the battery streams: state of charge, pack voltage
and current, power, per-cell voltages, temperatures, capacity, time-to-full /
time-to-empty, MOS and gate status, firmware version, and the current / voltage
/ temperature alarm lists.

Supports both re-badges of the same firmware:

- **Sphere Battery** (`com.joysuny.batteryutil`), advertised name prefix `JS`
- **RV Battery** (`com.joysuny.mimibattery`), advertised name prefix `RV`

## Project layout

Paths are relative to `projects/awto-bms/`.

- `lib/`, `test/`, `android/`, `windows/`, `pubspec.yaml` — the Flutter app
  (pubspec name `battery_reader`)
- `docs/` — protocol, alarm and wake write-ups; `docs/README.md` indexes them and
  lists the vendor builds captured
- `python_ble/` — Python reference reader (`read_batteries.py`) and control tool
  (`bms_control.py`)
- `artifacts/` — vendor APKs/XAPKs and jadx decompiles (private; never publish)

## Where the protocol comes from

Reverse-engineered from the decompiled 1.0.24 Sphere app in
`artifacts/sphere-battery-1.0.24/`. The full wire format is documented in
`docs/PROTOCOL.md`. The parser mirrors `BatteryManager.java`
(`ProcessWatchRunnable`) and `BatteryCMD.java` byte-for-byte, including the
app's little-endian helpers and its truncating integer divisions.

> **Not verified against a live battery.** All field layouts are read from the
> app's own parser, but no physical BMS has confirmed them. Treat readings as
> best-effort until checked against a known-good pack.

## Layout

| File | Role |
|---|---|
| `lib/battery_protocol.dart` | Pure-Dart codec: TX command builders, streaming RX parser, typed `BatteryState`. No Flutter dependency. |
| `lib/battery_connection.dart` | BLE transport (flutter_blue_plus): scan, connect, subscribe, handshake. |
| `lib/main.dart` | Live display UI. |
| `test/battery_protocol_test.dart` | Parser tests using synthetic frames — runs without hardware. |

## Transport summary

| | |
|---|---|
| Service | `0000FCF0-0000-1000-8000-00805F9B34FB` |
| Write (app → BMS) | `0000FCF1-…` |
| Notify (BMS → app) | `0000FCF2-…` |

After a short handshake the BMS streams frames on FCF2 unsolicited. Each frame
is a 2-byte begin sentinel, a fixed or count-prefixed payload, and a 2-byte end
sentinel, with no length field or checksum. The parser buffers notifications
and resyncs a byte at a time on any mismatch, so it recovers from a dropped byte
(the original app does not).

## Alarm bytes: what is known

`CMD_WARN_TEMP_ALARM` (`A6 C0 …`) byte **[2]** is a **latched over-temperature
protection** flag (live-confirmed, #50): it is set by a *past* over-temp event,
stays at 1 — inhibiting charging — until the BMS is restarted, and a restart
clears it (observed 1 → 0). The app decodes it as `BatteryState.overTempLatched`,
logs it as the `overTempLatched` metric, and shows an amber **warning** (with a
"Restart BMS to clear" button) rather than a live temperature fault. Bytes [3]
and [6] of the same frame remain unexplained status bits: captured as
`unknownTempB3` / `unknownTempB6`, never counted as a fault.

## Gate writes are refused without a fresh gate base

Every `CMD_GATE_CONTROL` write re-sends all eight gate bytes, so it must be built
from the pack's *current* gates. `BatteryConnection.sendGateControl` (and the
fleet switch writes) **throws** for any write that can turn something OFF
unless `hasFreshGateState`: connected, all six gates reported, and a
`BAL_STATUS` decoded within the last 15 s. It never falls back to zeros — a
zero-filled base would write chargeMos = dischargeMos = 0 (cutting output /
stopping charge) or tempControlGate = 0 (disabling low-temp protection). The UI
disables those buttons and shows the reason until a fresh status arrives.

The BMS has two independent MOSFET switches (#58): **Charge** (charge MOS, gate
byte[0]) and **Output** (discharge MOS, gate byte[1]). The app shows and
controls them separately, plus a convenience "Both". Turning a switch ON is a
*safe write* (#59): it goes out on any connected link, forcing ONLY its own
byte to 1 and leaving the other switch at its last-known value (Both ON and
Restart force both to 1). Turning a switch OFF keeps the fresh-status gate and
double-confirms.

## Read-only by design

The app's handshake ends with a `CMD_GATE_CONTROL` write (`setLowTemProtect`)
whose payload turns charge MOS, discharge MOS and the temp-control gate on. That
can change the battery's state. This tool **omits that frame by default** and
only sends the read-safe openers (`CMD_BEGIN`, `CMD_GET_EST`, `AT+V`). If a
particular BMS refuses to stream without the full handshake, construct
`BatteryConnection(sendLowTempGate: true)` — understanding it may flip gates.

This tool never sends MOS, balancing, factory-reset, capacity or time-set
commands; it only reads.

## Build & run

Prerequisites: Flutter SDK 3.19+ (`flutter --version`).

```bash
cd projects/awto-bms
flutter create .          # generates android/ ios/ windows/ etc. once
flutter pub get
flutter test              # runs the protocol tests, no device needed
flutter run               # on a phone with Bluetooth
```

`flutter create .` only adds the missing platform folders; it leaves `lib/`,
`test/` and `pubspec.yaml` intact.

### Platform permissions

- **Android**: add to `android/app/src/main/AndroidManifest.xml`:
  `BLUETOOTH_SCAN` (with `usesPermissionFlags="neverForLocation"` if you don't
  need location), `BLUETOOTH_CONNECT`, and for Android ≤ 11 `ACCESS_FINE_LOCATION`.
- **iOS / macOS**: add `NSBluetoothAlwaysUsageDescription` to `Info.plist`.
- **Windows / Linux**: BLE works via flutter_blue_plus with no extra manifest.

## Using the codec on its own

`lib/battery_protocol.dart` has no Flutter import, so you can reuse it in a
`dart:io` CLI or a server. Feed it bytes from any transport:

```dart
final state = BatteryState();
final parser = BatteryParser(state: state, onEvent: (e) => print(e));
parser.addBytes(bytesFromNotification);
print('SOC ${state.socPercent}%  ${state.packVoltage} V  ${state.packCurrent} A');
```
