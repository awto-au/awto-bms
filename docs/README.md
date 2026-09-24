# awto-bms — reverse-engineering notes

Reverse-engineering of the **Sphere Battery** / **RV Battery** LiFePO4 Bluetooth apps
(Zhuhai JoySuny New Energy Tech), and a clean-room reader being built from the findings.

## Layout

- `docs/` — all write-ups:
  - `PROTOCOL.md` — the shared JoySuny BLE protocol (all three builds): per-version matrix,
    framing, command table, status frame, hidden service mode, SOC/MOS, OTA, no-auth notes
  - `REFERENCES.md` — external sources (Sphere EVO user guide, community footprint)
  - `COMPARISON.md` — cross-brand BMS fingerprinting (Sphere/RV vs Stealth/LiFePO4 Power/JBD/JK)
  - `BMS-FAMILIES.md` — multi-BMS family map + protocol specs for a multi-brand reader
  - `reverse/` — the long-form reverse-engineering notes (01 BLE, 02 transport, 03 app, 04 history)
  - `python-gui-proposal.md` — reader GUI proposal
- `artifacts/<app>-<version>/` — one tree per app build (binary evidence):
  - `*.xapk` — the split bundle as downloaded (Play mirror; see each `PROVENANCE.md`)
  - `raw/` — the XAPK unzipped: base APK + config splits + `manifest.json`
  - `jadx/` — jadx Java decompile (browsable; doc line refs point here)
  - `PROVENANCE.md` — that build's source, version, hashes, and relation to the others
  - `screenshots/` — the UI captured under an emulator
  - `apktool/`, `unpacked-base/` — git-ignored, regenerable from `raw/` (see `.gitignore`)
- `artifacts/_comparison/` — competitor APKs pulled for fingerprinting (git-ignored, heavy)
- `lib/`, `test/`, `android/`, `windows/` — the AWTO BMS app (Dart/Flutter, pubspec name `battery_reader`)
- `python_ble/` — Python BLE reader (`read_batteries.py`)

## Builds captured

| App | Package | Version | Notes |
|---|---|---|---|
| Sphere Battery | `com.joysuny.batteryutil` | 1.0.24 | primary analysis target |
| RV Battery | `com.joysuny.mimibattery` | 1.0.2 | re-badge, superseded |
| RV Battery | `com.joysuny.mimibattery` | 1.0.4 | current; QR setup added, service password rotated |

Same BLE protocol across all three (Actions-Semi iBluz transport, FCF0 service). Details and
differences are in the per-build `PROVENANCE.md` and `docs/PROTOCOL.md`.
