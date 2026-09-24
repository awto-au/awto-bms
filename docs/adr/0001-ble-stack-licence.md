# ADR 0001: BLE stack licence

- Status: **Proposed**. The user decides. Issue #88.
- Date: 2026-09-24
- Scope: `projects/awto-bms` (AWTO BMS). Android and Windows now, iOS later.
  Distribution through Google Play (#101) and the Microsoft Store (#105).

This is an engineering reading of the licence texts, not legal advice.

## Context

On 2026-09-17 the app moved to `flutter_blue_plus` 2.x (lock: 2.3.12). Since 2.0.0
the package is no longer BSD-licensed. It uses its own "FlutterBluePlus License",
which requires a paid licence for any for-profit use. AWTO is a company, and AWTO
BMS is headed for commercial app stores.

How the app uses BLE today (commit 652c05a):

| Where | What |
|---|---|
| `lib/ble_transport.dart` (417 lines) | The only file that imports a BLE plugin. It has the `BleTransport`/`BleLink` interface, `FbpTransport` + `_FbpLink` (flutter_blue_plus, about 110 lines, used on Android/iOS) and `UniversalBleTransport` + `_UniversalBleLink` (universal_ble, about 230 lines, used on Windows). `_createBleTransport()` picks one per platform. |
| `lib/battery_connection.dart`, `lib/battery_manager.dart` | Use only the interface (`transport.connect/startScan/stopScan/scanResults`). They never import either plugin. |
| `test/fakes.dart`, `test/reconnection_test.dart` | Fake `BleTransport`. They don't touch either plugin. |
| `pubspec.yaml` | `flutter_blue_plus: ^2.3.12`, `universal_ble: ^0.18.0` (lock 0.18.0) |
| `android/app/build.gradle.kts:58-61` | Disables the `flutterBluePlusLicensePing*` tasks |
| `ble_transport.dart:150-156` | `device.connect(license: fbp.License.nonprofit, ...)` |

Also worth noting:

- **The Windows build ships flutter_blue_plus 2.x too.** `flutter_blue_plus` 2.3.x
  depends on `flutter_blue_plus_winrt` and names it as its Windows plugin, so
  `windows/flutter/generated_plugin_registrant.cc` registers it. The FBP Dart code
  is also compiled in, because `ble_transport.dart` imports it unconditionally. At
  runtime Windows talks through universal_ble, but the Microsoft Store package
  still contains FlutterBluePlus-licensed code. The licence question therefore
  covers both stores, not only Play.
- The code comments "flutter_blue_plus has no Windows support" (`pubspec.yaml`,
  `ble_transport.dart`) were true for 1.x and are out of date for 2.x. They don't
  change anything here.

## Facts: the flutter_blue_plus 2.x licence

Sources:

- Package LICENSE / LICENSE.md, identical, "FlutterBluePlus License Version 1.5".
  Read from the pub cache copy of 2.3.12 and compared with upstream `master`
  (https://github.com/chipweinberger/flutter_blue_plus/blob/master/LICENSE.md)
  on 2026-09-24: no differences. Latest release is 2.3.13 (2026-09-22). Its last
  licence change was 2026-06-19 ("add Corporate tier").
- NOTICE.md in the package:
  https://github.com/chipweinberger/flutter_blue_plus/blob/master/NOTICE.md
- pub.dev shows the licence as `license:unknown`, meaning it isn't an OSI licence:
  https://pub.dev/packages/flutter_blue_plus
- Payment portal (stated in the licence):
  https://jamcorder.myshopify.com/products/flutterblueplus-commercial-license
  Prices below come from the store's product JSON (`…/flutterblueplus-commercial-license.json`)
  and `/meta.json` (currency USD), fetched 2026-09-24.

Relevant clauses, quoted:

> **3. Commercial Use Requirement.** Use of the Software by any for-profit
> organization requires a commercial license under Section 3, regardless of how
> the Software was obtained. (Section 1)

> Any use of FlutterBluePlus by or for a for-profit company or corporation —
> including commercial use by individuals — requires the purchase of a commercial
> license (Section 3)

> **3. Development Clarification.** Use of the Software during development,
> testing, or evaluation by a for-profit organization is considered commercial use
> and requires a commercial license. (Section 3)

> **2. Perpetual Use.** The license grants perpetual rights to use the Software and
> to receive all current and future software updates made available by the
> licensor after purchase. (Section 3)

> Only a single commercial license is required per organization, regardless of how
> many FlutterBluePlus packages are used. (Section 3)

> **5. Nonprofit & Educational Exemption.** Registered nonprofit organizations and
> accredited educational institutions are exempt … (Section 1)

> **2. Relicensing Prohibition.** The Software may not be relicensed under
> different terms by any party. (Section 1)

What this means for AWTO:

- **Commercial use:** the test is whether the user is a for-profit organisation,
  not whether the app is sold. A free app from a for-profit company still needs a
  licence. So does internal use, and so does development and testing (Section 3.3).
  Only personal use, registered nonprofits and accredited educational institutions
  are exempt. AWTO is a company, so on the licence's own terms AWTO has needed a
  licence since the move to 2.x on 2026-09-17, not only from release day onwards.
  *Assumption to confirm: AWTO is a for-profit entity (e.g. a Pty Ltd).*
- **`License.nonprofit` in our code is wrong for AWTO.** The `license:` argument to
  `connect()` is required, but the package doesn't enforce it: it is never read in
  2.3.12's `bluetooth_device.dart`. It works as a self-declaration. Leaving
  `nonprofit` in a for-profit app is an inaccurate statement in our source, so it
  must change whichever option we choose.
- **Prices** (USD, one-time, per organisation, tier by headcount at purchase):

  | Tier | Headcount | Price |
  |---|---|---|
  | Inventor | solo developer working alone | $999 |
  | Starter | 1–9 employees | $2,999 |
  | Team | 10–29 | $5,999 |
  | Business | 30–99 | $9,999 |
  | Enterprise | 100–249 | $16,999 |
  | Corporate | 250+ | $24,999 |

  The shop page adds a term that is **not in the LICENSE**: "If your company later
  grows into a higher tier, you must purchase the new tier" (with an email discount
  for upgraders). The LICENSE says the tier is set "at the time of purchase" and
  grants perpetual use. The two texts conflict. Before buying, ask the licensor
  which one binds. *Not verified.* The shop page also lists the covered packages;
  `flutter_blue_plus_winrt` is not among them, but it is MIT-licensed by a
  different author (Himchan Park), so it doesn't need to be.
- **Validity of offer** (Section 3.5): the priced offer holds only while v1.5 is the
  current licence on `master`. Terms can change later. A licence already bought
  covers "all current and future" updates.
- **BSD residue:** NOTICE.md says releases up to and including 1.36.8 (published
  before October 2025) stay under BSD-3 "which are irrevocable", and advises 2.x
  users to keep the BSD-3 attribution. The app's about/licence screen (Flutter's
  `LicenseRegistry`) should carry it whichever option is chosen.

### The `flutterBluePlusLicensePing` Gradle task

Source: `flutter_blue_plus_android-9.0.3/android/license_ping.gradle`, applied
from its `build.gradle`. It is Android-only; the Windows build has no ping. For
every Android application variant, the plugin registers
`flutterBluePlusLicensePing<Variant>` and makes `pre<Variant>Build` depend on it.
At build time it sends an HTTPS POST (3 s connect and 3 s read timeout, failures
swallowed) to a Google Apps Script URL
(`https://script.google.com/macros/s/AKfycbw5p3…/exec`). The JSON it sends
contains:

- UTC day
- `applicationId`
- app label, resolved from the manifest or `strings.xml`
- `versionName`
- the flutter_blue_plus version from `pubspec.lock`
- a SHA-256 of those fields

It sends no source code or user data. The task is never up to date, so it runs on
every build.

The licence covers the ping in Section 1.4:

> **4. Build-Time License Ping.** The Software may attempt to send limited license
> telemetry at build time … This telemetry does not include source code or end-user
> data, and failure to send it does not prevent use or building of the Software.

**Is disabling it a licence breach?** Probably not. Section 1.4 is a notice that
the software "may attempt" to send telemetry. It isn't a condition placed on the
licensee. No clause forbids disabling the ping, and the licence itself says
failure to send is expected and harmless. Modifying the software is allowed in
Section 1. Confidence: moderate; this is a reading of the text, not legal advice.
The real problem is the missing commercial licence. Disabling the ping neither
creates that problem nor cures it. With FBP removed or pinned to 1.x the ping
doesn't exist at all: `flutter_blue_plus_android` 7.0.4 has no
`license_ping.gradle`.

## Options

Platform coverage is for this app: Android now, Windows now, iOS later. Licence
and maintenance data comes from pub.dev and the package sources, checked
2026-09-24.

| Option | Licence | Android | Windows | iOS | Maintenance | Cost |
|---|---|---|---|---|---|---|
| A. Keep FBP 2.x, buy a licence | FlutterBluePlus License v1.5 (proprietary, paid for for-profit use) | yes | FBP winrt exists, but we use universal_ble | yes | Active: 2.3.13 on 2026-09-22, about 243k downloads in 30 days | US$2,999 (Starter), once |
| B. Pin FBP 1.36.8 | BSD-3 (irrevocable per NOTICE.md). All federated packages are pinned exactly to BSD 7.0.x | yes | no Windows plugin, so universal_ble stays | yes | **Frozen**: last 1.x release 2025-09-17. No fixes for new Android/iOS changes | $0 |
| C. universal_ble on every platform | BSD-3 (Navideck Labs OÜ) | yes | yes (already our Windows backend) | yes | Active: 2.3.0 on 2026-09-07, repo pushed 2026-09-10, about 52k downloads in 30 days | $0 |
| D. flutter_reactive_ble (mobile) + universal_ble (Windows) | BSD-3 (Signify / Philips Hue) | yes | **no**, still needs universal_ble | yes | Maintained: 5.6.0 on 2026-09-23, but 161 open issues | $0 |
| E. bluetooth_low_energy | MIT | yes | yes | yes | Last release 6.2.1 on 2026-01-17, about 11.5k downloads in 30 days | $0 |

Not considered further:

- `win_ble`: MIT, Windows only, last release January 2024.
- `flutter_blue_plus_windows`: MIT, a 1.x shim, last release February 2025.
- `quick_blue`: last release 2022.

## Code change per option (concrete)

**A. Buy the licence.** Around 5 lines.

- `ble_transport.dart:152`: `License.nonprofit` becomes `License.commercial`.
- `build.gradle.kts:58-61`: either keep the ping disabled (allowed, see above) or
  delete the block to re-enable it as a courtesy to the licensor. The cost is 2–6 s
  on each Android build.
- Record the licence purchase (order number, tier, date) in `README.md`.
- No behaviour change, so no device retest is needed.

**B. Pin 1.36.8.** Around 10 lines, plus retests.

- `pubspec.yaml`: `flutter_blue_plus: 1.36.8`, an exact pin. A caret would allow
  2.x.
- `ble_transport.dart`: remove the `license:` argument; 1.x `connect()` has no
  such parameter. The other APIs used (`onScanResults`, `advName`, `str128`,
  `mtuNow`, `onValueReceived`) all exist in 1.36.8.
- Delete the gradle block, because the ping task no longer exists.
- Regenerate the Windows plugin registrant; `flutter_blue_plus_winrt` drops out.
- Retest Android scan, connect and OTA. Main risk: no upstream fixes for future
  Android targetSdk or Play policy changes, or for iOS when we add it.

**C. universal_ble everywhere.** A medium change: about 115 lines deleted and
20–40 changed, in about 5 files. Needs an on-device Android verification pass.

- `ble_transport.dart`:
  - delete `FbpTransport` and `_FbpLink` (about 110 lines)
  - make `_createBleTransport()` always return `UniversalBleTransport`
  - drop the `fbp` import
  - update the header comments
- `pubspec.yaml`:
  - remove `flutter_blue_plus`
  - bump `universal_ble` from `^0.18.0` to `^2.3.0`. Version 0.18.0 has **no**
    Android runtime-permission handling; 2.x adds `UniversalBle.requestPermissions()`
    (Android 12+ SCAN/CONNECT, with `withAndroidFineLocation: false` to match our
    `neverForLocation` manifest). FBP requested these permissions for us, so an
    explicit `requestPermissions()` call before the first scan must be added.
- API changes from 0.18 to 2.x that touch our code (per the universal_ble
  CHANGELOG):
  - `connect(connectionTimeout:)` became `timeout:` (0.21.0)
  - `setNotifiable` is deprecated in favour of `subscribeNotifications`
  - `writeValue` is deprecated in favour of `write`

  All three sit inside `UniversalBleTransport`/`_UniversalBleLink`, so Windows
  gets a small edit and needs a Windows retest too.
- `android/app/build.gradle.kts`: delete the ping-disable block.
- `AndroidManifest.xml`: fix the comment only; the permissions are already right.
- Regenerate the Windows plugin registrant; `flutter_blue_plus_winrt` drops out.
- Verify on a real Android phone against a real battery:
  - scan hits, and the FCF0 service in the advert
  - connect, discover, notify
  - write-without-response on FCF1
  - reported MTU; the OTA chunker (#41) sizes from it. Read-only check; no OTA
    frames to a real battery without consent.
  - reconnect after a dropped link
- Unit tests use `test/fakes.dart` and don't change.
- Risk: medium-low. The universal_ble path already runs this exact protocol in
  production on Windows, including the #49 discovery-retry hardening. Android is
  the new backend underneath it.

**D. flutter_reactive_ble on mobile.** About 150 new lines replace the ~110 FBP
lines, and there are still two BLE stacks to maintain. It has no Windows support.
Worse than C on every axis except the size of its mobile install base.

**E. bluetooth_low_energy.** Rewrite both implementations (about 340 lines). Its
release cadence is slower than universal_ble's. No advantage over C.

## Recommendation

**Option C: universal_ble on every platform, and remove flutter_blue_plus.**
Confidence: **moderate-high** (about 75%).

Why:

1. The licence problem goes away permanently and costs nothing, for both stores.
   The code is BSD-3 and OSI-approved, with no telemetry, no headcount tiers and
   no terms that can change later.
2. The app gets **one** BLE stack instead of two. This matches the "one Dart
   implementation; platform branches only at the thin edge" rule, and the
   Windows-only branch in `_createBleTransport()` disappears.
3. The Windows backend is already universal_ble, so the protocol path is proven.
   Only the Android native layer changes.
4. universal_ble is actively maintained. The 2.x line has recent Android GATT
   lifetime fixes and iOS state restoration, which will help when iOS arrives.

What lowers confidence:

- universal_ble on Android is unproven *in this app*. FBP's Android layer is the
  more battle-tested of the two (about 5× the downloads).
- The jump from 0.18 to 2.3 is a real upgrade across several breaking releases.
- A regression in reconnect behaviour would only show up on hardware.

Fallback: if the Android verification pass fails and can't be fixed quickly, buy
the licence (A). It costs about US$3k and one line of code, and it is an
acceptable, low-risk answer. It isn't wrong; it just leaves a paid, changeable
licence and a second BLE stack in place.

Not recommended: B (1.36.8 pin). It is free, but it is a dead end with no fixes
from 2025-09 onwards, which is a poor base for a store app that must keep up with
Android targetSdk rules and later iOS.

**Interim:** until C lands or a licence is bought, AWTO's current use of 2.x
(development and testing included) is outside the licence's free terms.
Don't publish any Play or Microsoft Store build with flutter_blue_plus 2.x in it
before this is resolved.

## What the user must decide or buy

1. **Choose C or A.** C costs engineering time: a medium change plus an
   Android-on-hardware verification session. A costs US$2,999 (Starter tier,
   assuming 1–9 employees). B is not recommended.
2. **Confirm the facts the recommendation rests on:** AWTO is a for-profit entity,
   and its employee headcount (this sets the tier under A).
3. **If A:**
   - The purchase is the user's to make at the portal above.
   - First ask the licensor to settle the "grow into a higher tier" conflict
     between the shop page and LICENSE §3.1.
   - Keep the receipt on file.
   - Decide whether to re-enable the build ping.
4. **Either way:** on the licence's own terms, the use of 2.x since 2026-09-17 was
   unlicensed commercial use. Whether to buy a licence to cover that period, even
   if C is chosen, is a business call for the user.
5. When decided, record the outcome in `projects/awto-bms/README.md` as #88 asks,
   and set this ADR to Accepted.

## Not verified

- Whether the shop's "must purchase the new tier" growth term binds, given the
  LICENSE text says otherwise.
- AWTO's legal form and headcount.
- universal_ble 2.3.0 behaviour on Android against the JoySuny BMS: scan
  batching, write-without-response, MTU. Needs a device session.
- Whether Android `startScan()` in universal_ble 2.x requests permissions
  automatically. The README states it only for iOS/macOS; plan an explicit
  `requestPermissions()` call.
