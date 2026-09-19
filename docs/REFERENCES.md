# External references & community discussion

What exists publicly about the Sphere / RV Battery apps and batteries, gathered 2026-09-17.

## Official documentation

**Sphere EVO Lithium — Lithium Battery User Guide** (Coast to Coast RV, "Sphere - 2024"),
e.g. `mygenerator.com.au/assets/files/CRM4840_Sphere_Battery_User_Guide.pdf`. This is the
authoritative field reference and it **confirms several things we reverse-engineered**:

- **Connect password is public.** Page 3, verbatim: *"The default Password for Sphere
  Batteries is JS2023."* Printed in the customer manual — confirming (see PROTOCOL.md
  "Authentication") that `JS2023` is an app-side convenience gate, not a secret.
- **Device naming.** *"All Sphere EVO batteries start with the initials 'JS'."* Matches
  `Global.DEFAULT_BLUE_HEAD = "JS"` and the advertised name `JS-<id>` seen in the app
  screenshot (`BT CONNECTION:JS-401705016E19`).
- **SOC is a *learning* gauge.** Page 4 (commissioning): *"Sphere EVO batteries have learning
  SoC monitoring via the Bluetooth app, no need to set."* This is the manufacturer confirming
  the SOC is a learned coulomb-counter value in the BMS — exactly why a fresh or mis-learned
  pack can sit at a wrong/stuck %, and why a full charge/discharge cycle is the fix (see
  PROTOCOL.md "SOC is display-only"). The app only displays the byte; the *learning* is in the
  BMS.
- **Capacity is user-set via the info icon.** *"press the information icon and select the
  correct battery capacity from the drop down list (Eg: 100AH)."* Matches `setBattery`
  (`CMD_BATTERY`) — and note it's the same ⓘ icon used in the hidden-mode gesture.
- **"Do not modify the BMS by any means"** (page 8 warnings) and *"Non compliance will void
  the warranty."* Directly relevant to the hidden service mode: the MOS / passive-balance /
  factory-reset controls behind the `339933` gesture are manufacturer-discouraged and using
  them arguably voids warranty.
- **Sphere is a sub-brand of Coast to Coast RV services** (page 8 disclaimer) — the link that
  explains the RV Battery app's Coast-RV privacy-policy domain.

Useful spec numbers from the same guide (inform the decoder / sanity ranges): 12.8 V nominal;
Bulk 14.2–14.6 V, Float 13.6 V, Charge cut-off max 15.0 V, Low-voltage cut-off 10.0 V;
discharge 100 A (250 A 3 s); capacities 100 / 120 / 200 / 240 Ah; BMS re-connect automatic.
Note a discrepancy: the spec sheet lists **"Cell Balancing: Active 5A"**, but the app only
exposes a **passive** equalisation toggle (`setPassiva`) — the app UI and the marketing spec
disagree on balancing type.

## Community / message-board discussion

Searched Australian caravan forums (Caravaners Forum, Grey Nomads, ExplorOz, myswag,
CaravansPlus, ozRoamer), Reddit, XDA, Facebook groups, and the app-store review sections.

**There is almost none.** Findings:

- Caravaners Forum has a *"Sphere lithium batteries"* thread
  (`caravanersforum.com/viewtopic.php?t=86133`) but it is a single unanswered 2020 post asking
  for general experience — nothing about the app, SOC, BMS, or firmware.
- Other forum hits for "Sphere" are the unrelated **Endless Sphere** DIY-EV forum (false match
  on the word), not this product.
- App-store footprint is tiny: App Store AU shows **3.0★ from 2 ratings, no written reviews**;
  Play lists 1K+ installs, 2.6★ from ~7 reviews. No substantive user threads.
- No public discussion anywhere of the firmware images (`PB51250506.bin` / `8803250506.bin`),
  the OTA mechanism, or the hidden service mode. As of this date, this repo appears to be the
  only place the protocol is written down.

## Firmware

Covered in PROTOCOL.md ("Firmware update"): the `.bin` images are not in the app, not
downloaded by it, and not published anywhere found. Distributed out-of-band by JoySuny / the
dealer. The user guide does not mention firmware updates at all — consistent with it being a
dealer/service operation, not a customer one.
