# RV Battery 1.0.2 - artifact provenance

| | |
|---|---|
| App | RV Battery ("Bluetooth app for RV Battery") |
| Package | `com.joysuny.mimibattery` |
| Version | 1.0.2 (versionCode 3) - superseded by 1.0.4 on 2026-09-16, see `../rv-battery-1.0.4/` |
| Developer | Play listing name "Honour Energy"; same JoySuny codebase as Sphere Battery |
| Play listing | https://play.google.com/store/apps/details?id=com.joysuny.mimibattery |
| iOS sibling | https://apps.apple.com/gb/app/rv-battery/id6756601537 (bundle `com.joysuny.mimibatterys.MimiBatterys`, v1.1.1, not listed in AU/US stores; privacy policy hosted under a Coast RV domain) |
| Min / target | Android 26 / 36, splits: en, fr, xxhdpi (no native-lib split) |
| Retrieved | 2026-09-15 from apkcombo.com (Play mirror), Play publish date 2026-02-03 |
| Download size | 10,164,592 bytes (XAPK) |

## Layout

Same as `../sphere-battery-1.0.24/`: `RVBattery-1.0.2.xapk`, `raw/`, `unpacked-base/`,
`jadx/` (71 app files, 0 decompile errors), `apktool/`.

## Relationship to Sphere Battery

Same app, re-badged. **Correction (deep reverse pass):** the two `blemanager/BatteryCMD.java`
files are **byte-identical** — there is no command difference at all. An earlier note claimed
RV renames with `AT+@` (`41 54 2B 40`); that is wrong. Both send `AT+=` (`41 54 2B 3D`). UUIDs,
framing, handshake, hidden service mode and gesture are identical; the real differences are
only in `Global.java` (passwords, adv prefix) and bundled libraries. See `../../PROTOCOL.md`
and `../reverse/04-history-versions.md`.

| `Global` constant | Sphere 1.0.24 | RV 1.0.2 |
|---|---|---|
| `DEFAULT_BLUE_HEAD` (adv prefix) | `JS` | `RV` |
| `DEFAULT_CONNECT_PASSWORD` | `JS2023` | `RV2025` |
| `DEFAULT_PASSWORD` (settings tab) | `JS20230801` | `RV20250506` |
| `DEFAULT_BACK_PWD` (hidden mode) | `339933` | `339933` |
| `DEFAULT_UPDATE_PWD` (OTA) | `332211` | `332211` |

Differences worth noting: RV drops Bugly crash reporting (and so has no native code at all),
drops the `IS_INSIDE` flag and the JS3/JS5 firmware-file constants, and adds a Play
licence check (`com.android.vending.CHECK_LICENSE`, `com/pairip/licensecheck`) - a
sideloaded copy may refuse to run outside Google Play. The iOS 1.1.0 changelog mentions QR-code
device setup; the Android 1.0.2 build has no QR/scanner code.
