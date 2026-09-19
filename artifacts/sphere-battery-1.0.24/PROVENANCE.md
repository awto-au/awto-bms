# Sphere Battery 1.0.24 — artifact provenance

| | |
|---|---|
| App | Sphere Battery ("Sphere Lithium Battery Util") |
| Package | `com.joysuny.batteryutil` |
| Version | 1.0.24 (versionCode 24) |
| Developer | Zhuhai JoySuny New Energy Tech Ltd. (Play listing dev name "tom tang") |
| Play listing | https://play.google.com/store/apps/details?id=com.joysuny.batteryutil |
| Min Android | 12+ · nodpi · arm64-v8a |
| Retrieved | 2026-09-12 from apkcombo.com (Play mirror) |
| Download size | 11,588,677 bytes (XAPK) |

## Layout

- `SphereBattery-1.0.24.xapk` — as downloaded
- `raw/` — XAPK unzipped: base APK + split configs (`arm64_v8a`, `en`, `fr`, `xxhdpi`) + `manifest.json`
- `unpacked-base/` — `com.joysuny.batteryutil.apk` unzipped (plain `unzip`, no apktool)

## First-pass recon

Kotlin/Android app, 2 dex (`classes.dex` 9.4 MB, `classes2.dex` 0.5 MB). Only native lib is
`libBugly_Native.so` (Tencent crash reporting) in the arm64 split — no protocol code in native.

Class-prefix counts in `classes.dex`:

| Prefix | Classes | What |
|---|---:|---|
| `com/google/android/` | 887 | AndroidX / GMS |
| `com/bumptech/glide/` | 706 | image loading |
| `com/joysuny/batteryutil/` | 230 | **app code** |
| `com/lxj/xpopup/` | 207 | popup UI lib |
| `com/tencent/bugly/` | 175 | crash reporting |
| `com/actions/ibluz/` | 85 | **Actions Semiconductor BLE SDK** |
| `com/davemorrissey/labs/` | 45 | subsampling image view |
| `com/actions/utils/`, `com/actions/actionslogutils/`, `com/actions/permissionutil/` | 19 | Actions support |
| `com/joysuny/progress/` | 5 | app UI |

BLE UUIDs found in `classes.dex`:

| UUID | Note |
|---|---|
| `0000FCF0-…-00805F9B34FB` | service (Actions/Bluz style) |
| `0000FCF1-…-00805F9B34FB` | characteristic |
| `0000FCF2-…-00805F9B34FB` | characteristic |
| `00002902-…-00805f9b34fb` | CCCD descriptor |
| `00001101-…-00805F9B34FB` | classic SPP |
| `e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1` | Telink OTA service |
| `e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1` | Telink characteristic |
| `e49a28e1-f69a-11e8-8eb2-f2801f1b9fd1` | Telink characteristic |

So: BLE transport via the Actions Semiconductor SDK on the FCF0 service, with a Telink OTA
service alongside for firmware update. Protocol framing is in `com/joysuny/batteryutil/` dex —
not yet decompiled (no jadx/apktool on this machine).
