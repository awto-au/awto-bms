# RV Battery 1.0.4 - artifact provenance

| | |
|---|---|
| App | RV Battery ("Bluetooth app for RV Battery") |
| Package | `com.joysuny.mimibattery` |
| Version | 1.0.4 (versionCode 5) - **current on Play as of 2026-09-16** (Play "Updated on Sep 16, 2026") |
| Developer | Play listing "Honour Energy"; in-app branding "RV TECH"; JoySuny codebase |
| Play listing | https://play.google.com/store/apps/details?id=com.joysuny.mimibattery |
| iOS sibling | https://apps.apple.com/gb/app/rv-battery/id6756601537 (v1.1.1, geo-restricted) |
| Min / target | Android 26 / 36; 3 dex; splits en, fr, xxhdpi |
| Retrieved | 2026-09-16 from apkcombo.com (Play mirror) |
| Download size | 12,049,756 bytes (XAPK) |

Same layout as the sibling trees: `RVBattery-1.0.4.xapk`, `raw/`, `unpacked-base/`,
`jadx/` (73 app files, 0 errors), `apktool/`.

## Changes vs 1.0.2

Protocol: **none**. `BatteryCMD.java` 65/65 constants identical, `BatteryManager.java`
byte-identical (49,006 bytes both). **Correction (deep reverse pass):** rename is `AT+=`
(`41 54 2B 3D`) here too, same as Sphere — an earlier note saying `AT+@` was wrong. See
`../reverse/04-history-versions.md`.

| | 1.0.2 | 1.0.4 |
|---|---|---|
| `DEFAULT_BACK_PSW` (hidden service mode) | `339933` | **`50176`** |
| `DEFAULT_CONNECT_PASSWORD` | `RV2025` | **`3445418`** |
| `DEFAULT_PASSWORD` (settings tab) | `RV20250506` | `RV20250506` |
| `DEFAULT_UPDATE_PWD` (OTA) | `332211` | `332211` |
| `DEFAULT_BLUE_HEAD` | `RV` | `RV` |

New: `activity/ScanMainActivity` + bundled `com.google.zxing` (341 classes) and a `CAMERA`
permission - the QR-code device setup that the iOS 1.1.0 changelog mentioned. Play licence
check (`com.pairip.licensecheck.LicenseActivity`, `classes2.dex`) is still present: a plain
`adb install` shows "Something went wrong - check that Google Play is enabled" (logcat:
`LicenseClient: Local install check failed due to wrong installer`).

The hidden-mode gesture is unchanged (`vm/MainViewModel.java`): logo x4, current x4,
long-press info, then the password above. So the Sphere-era `339933` no longer opens RV
Battery's service screen; `50176` does.

## Running it in the emulator

A plain `adb install` is blocked by the licence check (`screenshots/00-…`). Installing with
the installer package spoofed as Play gets past the local check; the background check then
fails to bind on a google_apis image but only logs "Retry limit reached" and the app keeps
running:

    adb install-multiple -i com.android.vending raw/com.joysuny.mimibattery.apk raw/config.*.apk
