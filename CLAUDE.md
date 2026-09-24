# awto-bms — Development Guide

Adds to the root `CLAUDE.md` for work in `projects/awto-bms/`. Layout: `README.md`.

## Build and run

- Flutter SDK is at `C:\src\flutter\bin` (not on PATH in bash).
- Run ONE Flutter build or test at a time on this laptop (Defender + RAM).
- Debug Android builds: `flutter build apk --debug --target-platform android-arm64`.
- Windows: `flutter build windows --debug`; the exe is
  `build/windows/x64/runner/Debug/battery_reader.exe`. Run it FROM the project dir.

## Windows screenshots

PowerShell: `SetProcessDPIAware`, then `EnumWindows` filtered by the process id of
`battery_reader` (take the largest visible window), `GetWindowRect`, `CopyFromScreen`.
Title matching alone catches other windows.

## UI

- Shared section widgets in `lib/sections/*` drive BOTH the phone layout and the
  two-pane desktop layout (`lib/desktop_shell.dart`, `lib/adaptive_scaffold.dart`,
  breakpoint 900 px), so the two cannot drift. Keep it that way.
- Line charts only. Never rings, gauges or pies.
- Last-known values show in stale red, never dashes.
- Compact layouts.

## Safety

- Never send OTA frames to a real battery without a verified image and the user's
  explicit consent.
- Switch-OFF writes need a fresh BAL_STATUS (≤ 15 s).
- No password or service-mode gates in the app.
- `python_ble/bms_control.py` is the reference for control commands.
  `python_ble/read_batteries.py` is frozen.

## Identity (do not rename)

Keep `package:battery_reader/` imports, the pubspec `name`, the Android
applicationId and the Windows `ProductName "battery_reader"`: ProductName keys the
app-support data folder. The visible name "AWTO BMS" comes from the window title and
FileDescription. Moving to an `au.awto.*` bundle ID is a data migration: file an
issue first.

## Private material

Vendor binaries, decompiled sources and the vendor PDFs stay private. They live in
this private repo. The public snapshot awto-au/awto-bms excludes
`artifacts/*/jadx|apktool|unpacked-base|raw`, `artifacts/_comparison`, and
`*.apk *.so *.java *.pdf *.zip`. A Python publish script under `scripts/` is wanted
(no shell scripts).

## Issues

- File in this repo with `--label project:awto-bms`. `#NN` tags in code comments and
  test names are the OLD awto-bms numbering; match issues by title.
- An issue for every request, honest confidence statements, tests and evidence, and
  no unrequested work.
