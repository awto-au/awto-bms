# Cross-brand BMS comparison — is the JoySuny protocol shared?

**Question:** do other caravan/RV LiFePO4 battery apps use the same BMS as Sphere/RV
(JoySuny)? **Method:** installed competitor apps from Google Play onto a test phone
(Galaxy S23, Android 16), pulled the real APKs, and grepped each for the JoySuny fingerprints
(the `FCF0/FCF1/FCF2` service, the `com.actions.ibluz` SDK, the `FB C8 7C 9D 26 EC` handshake,
the `A2 57…B3 6C` framing) plus each app's own BLE service UUIDs. Date 2026-09-19.

## Result: three brands, three different BMS families

| App | Package | BLE service triple | BMS family | App stack | JoySuny markers? |
|---|---|---|---|---|---|
| **Sphere / RV Battery** | `com.joysuny.batteryutil` / `com.joysuny.mimibattery` | **`FCF0 / FCF1(w) / FCF2(n)`** | **JoySuny** (Actions iBluz transport) | native, `com.actions.ibluz` | — (this is the reference) |
| **Stealth Batteries** | `com.stealth.bmsapp` | **`FF00 / FF01 / FF02`** | **JBD / Xiaoxiang "Smart BMS"** family | Weex + DCloud (uni-app HTML5 hybrid) | **none** — 0 hits for FCF0/e49a/ibluz/joysuny/`FB C8` |
| **LiFePO4 Power** | `com.dy.leadyo` | **`FFF0 / FFF4 / FFF6`** | generic `FFF0` module (Daly-ish) | native, Jackson/xUtils | **none** |

Fingerprint greps (base APKs kept under each `*/raw/base.apk` as evidence):
- **Stealth Batteries** — BLE UUIDs found: `0000ff00/ff01/ff02-…-00805f9b34fb` (+ CCCD 2902).
  That `FF00` service with `FF01` notify / `FF02` write is the well-known **JBD (jiabaida) /
  Xiaoxiang** BMS signature — a family that *does* have open-source decoders (jbdtool,
  patman15/BMS_BLE-HA). Built on Alibaba Weex + DCloud, so its protocol lives in JS assets, not
  dex. Completely unrelated to JoySuny.
- **LiFePO4 Power** — BLE UUIDs `0000fff0/fff4/fff6-…`. Another distinct transparent-module
  family. Native app (Jackson, xUtils, zxing). No JoySuny markers.

## Conclusions

1. **There is no single universal caravan BMS.** Three competitor apps → three different BMS
   BLE platforms (`FCF0` JoySuny, `FF00` JBD, `FFF0` generic). The market is fragmented across
   several BMS vendors; a brand's app tells you which BMS is inside.
2. **JoySuny's `FCF0` protocol is an island.** No other app sampled (here or in the public-code
   search) speaks it. It is confined to JoySuny's own two brands (Sphere, RV Battery). By
   contrast Stealth's JBD/`FF00` family is common and already open-source-decoded.
3. **The `AT+` rename is a generic BLE-module convention, not a JoySuny quirk.** LiFePO4 Power
   also contains `AT+` command strings. This supports the reading (see artifacts/sphere-battery-1.0.24
   /reverse notes) that JoySuny's `AT+=<name>\r\n` / `AT+@` talks to the transparent BLE-UART
   **module** (renaming the advertised name at the module level), while the BMS binary protocol
   passes through it — i.e. the AT rename almost certainly works on real hardware, because it
   configures the radio module, not the battery MCU.

## Caveats
- Two data points beyond JoySuny; not exhaustive. Other brands may still share the JoySuny
  board under their own app/dev account (can't be excluded without sampling them too).
- "Stealth Batteries" (`com.stealth.bmsapp`, US brand stealthbatteries.com) is a *different*
  company from Phoenix Technology's AU "Stealth Energy" house brand — same word, unrelated.
- The actual JoySuny/Phoenix house brands (SolarKing, Stealth Energy AU) ship **no Bluetooth
  app** that could be found — they use hardware shunt/display monitors — so there was no app to
  fingerprint for them; their BMS could still be JoySuny, just not app-exposed.
