# Waking a dormant JoySuny BMS — investigation (2026-09-21)

**Case.** JS-2C14AA (Sphere EVO, firmware JS5.1) went dormant between 07:03 and
21:02 on 20 Sep 2026 with no observer. Its last telemetry showed MOS **on**,
idle at 0 A, 93 %, 3.33 V/cell, no alarm bits, and its Bluetooth-standby flag
**off** (see ALARM-CORRELATION.md — an earlier draft of this note assumed the
output had been switched off with standby on; the logs show neither). The BLE
bridge still advertises and connects, but the BMS microcontroller behind it
does not run. The pack is permanently paralleled with JS-2C14B8 (healthy).
The cause is undetermined; the vendor's documented standby behaviour does not
apply, and the spec row "BMS Re-Connect: Auto" did not hold.

**Verdict.** There is no Bluetooth path to wake it — proven by three clients
(our app, the vendor app, a Python tool), a byte-level re-reverse of all three
vendor apps and their SDK, a live GATT dump, and the module's own datasheet
constraints. Recovery is physical. The vendor documents no procedure, the case
has no button, and opening it voids the warranty. Ranked steps and contacts are
in §5.

## 1. What the pack does (live, verified)

| Probe | Result |
|---|---|
| BLE connect, GATT discovery | fine every time |
| Device Information service | Manufacturer `Nations`, Model `NS-BLE-1.0`, FW/HW/SW `1.0.0` — a Nations N32WB03x BLE SoC running Nations' stock BLE profile with JoySuny's `FCF0` service added |
| `AT+V\r\n` | sometimes a lone `0x30` (`'0'`) status byte from the bridge, sometimes nothing; never the framed `AC 9A …` version reply that a running BMS adds |
| `AT+=JS-2C14AA\r\n` | `\r\nOK\r\n` (bridge-local rename ack) |
| `AT`, `AT+?`, `AT+VER`, `AT+VERSION`, `AT+NAME?`, `AT+ROLE`, `AT+BAUD`, `AT+PIO`, `AT+MODE`, `AT+SLEEP?`, `AT+STATE`, `AT+H`, `AT+HELP`, `AT+MAC`, `AT+LADDR` | nothing (or the generic `'0'`) — the bridge implements only the vendor's two verbs |
| `CMD_BEGIN` (wake), `CMD_GET_EST`, `CMD_SEND_MTU`, sleep-OFF `AA CC 01 01 DD EE`, the vendor's auto turn-on gate `C3 1E 01 01 01 00 00 00 00 00 D4 3B`, the restart gate frame, `CMD_UPDATE_END` | no reply, no telemetry — on `FCF1` (both write modes), and on the undocumented `11110002` / `11110003` characteristics (the Nations SDK's raw-UART pass-through service), with UART wake preambles and rapid repeats |
| Vendor app (Sphere 1.0.24) | connects, shows SOC 0.0 %, 0.0 V, 0.0 A after its own automatic turn-on frame |
| Charger on the parallel bank | charged B8 only (B8 rose 3.33 → 3.46 V/cell); AA unchanged |

## 2. Why nothing over Bluetooth can work

- **The bridge and the BMS are two chips.** The `'0'` and `OK` come from the
  Nations BLE SoC; every framed reply comes from the BMS MCU over a UART. A pack
  that only ever answers with `'0'`/`OK` has a live bridge and a halted MCU.
- **The BMS MCU's sleep is a deep one.** Every framed command already sent
  creates UART RX edges; had the MCU been in a STOP-class sleep with UART wake,
  it would have woken. It didn't, so it is in a STANDBY/power-down class state,
  which on Nations N32 parts leaves only NRST, the WKUP pin, RTC or a power
  cycle as exits — none reachable from the radio (N32G435 / N32WB03x
  datasheets, low-power sections).
- **The vendor apps contain no wake.** Exhaustive search of Java, smali,
  resources, assets and the single native library in all three builds: the only
  TX frames are the ones we already send; the SDK (Actions iBluz) is transport
  only; the app does nothing when a pack answers nothing (one 20 s timer that
  is never re-armed). Packs "come back" under the vendor app only because it
  fires the both-MOS-on gate frame 2.5 s after every handshake — which a dormant
  MCU ignores just like everything else.
- **No third-party software exists** for this BMS (GitHub, Home Assistant,
  ESPHome, dbus-serialbattery: zero hits for the sentinels or package names),
  and Nations publishes no host protocol for its BMS parts, so no undocumented
  "exit ship mode" command is known.

## 3. Why the charger on the bank did nothing

Common-port BMS: `B- —[DSG FET]—•—[CHG FET]— P-`, body diodes toward the
common node. With **both FETs open, each direction meets one reverse-biased
body diode — zero current in either direction.** The vendor's only documented
wake is "detects charging or discharging", i.e. current, which can never occur.
In a parallel bank the pack's terminals are additionally clamped to the healthy
pack, so it never even sees a voltage step. Whether AA's FETs are actually open is unobserved (they were on in its last
frame); a pack sitting 0.5 V below its parallel partner yet taking no charge
current behaves as if they are. A meter on the isolated pack's posts settles it.
The app still refuses output-off with standby on, as a precaution.

## 4. Options that remain on the radio (consent only; low value)

| Action | What it is | Risk | Expected value |
|---|---|---|---|
| `AT+RESET\r\n` on `FCF1` | if parsed, reboots the bridge only | unknown parser; a config-touching verb match could alter the module | ~none: a bridge reboot cannot reach NRST/WKUP of the MCU unless a wake line exists, and nothing suggests one |
| `EB 90 00 07 BB 03 40` (OTA begin) | asks the BMS **bootloader** to answer `FF 01 B1 02 EF` | the bootloader is on the same halted MCU; if it did answer, the pack is in update-wait and the app has no abort — small IAP loaders often erase the application on BEGIN; brick-on-abort plausibly 10–30 % | low (<15 %) chance of any reply; only attempt with the genuine `8803250506.bin` in hand and the intention to complete the flash |

Do not send: any OTA data/finish frame without a valid image, `AT+STRS` /
`AT+DEFAULT`-style factory verbs, `AT+SLEEP`, sleep-ON, the factory-reset bit,
or anything on the `1111…` / `e49a…` services beyond what was tried.

## 4a. Fuzz of the bridge (2026-09-22, with consent)

Bounded, logged fuzz on `FCF1`: `AT+X?`, `AT+X=?` and bare `AT+X` for every
X in A–Z and 0–9 (108 commands, no parameters, so no persisted-config write was
attempted), plus all 22 known begin/end sentinel pairs with an empty payload.
Result: **zero replies** other than one generic `'0'` early in the session. The
bridge's parser has no verbs beyond `V` and `=`; there is no hidden reset, GPIO
or wake command. Log: session scratchpad `fuzz_aa.log`.

## 5. Physical recovery, least to most invasive

1. **Isolate the pack.** Disconnect AA's cables from the bank entirely. Nothing
   else attached.
2. **Charger alone, lithium profile**, directly on AA's terminals, 10–30 min;
   several connect/disconnect cycles to present voltage steps. Many smart
   chargers refuse a terminal reading that looks wrong, so if it shows "no
   battery" go to 3.
3. **A source that outputs regardless of battery detect:** a charger with a
   lithium "force / supply / 0 V activation" mode (Victron Blue Smart
   "Li-ion force"/"Supply", Redarc/Projecta lithium-wake modes) or a bench
   supply at 14.2–14.6 V with the current limit at ≤ 1 A. While it is attached,
   try the app: if AA starts streaming, tap Charge ON and Output ON at once and
   make sure Bluetooth standby is OFF.
4. **A direct load** (12 V lamp) on the isolated pack for 10–60 s, alternating
   with the charger — the opposite-polarity signal across the open FET stack.
5. Jump-pack / charged battery in parallel on the isolated pack: adds nothing
   beyond step 3; skip.
6. **No button or pinhole exists** on this product (guide photos, all listings).
7. **Opening the case** to lift B- for 60 s is the only certain MCU power-cycle,
   and **voids the warranty** ("Do not disassemble or open the battery case",
   Sphere EVO guide p.8). Not recommended on an in-warranty pack.
8. **Warranty / RMA.** The guide's spec row "BMS Re-Connect: Auto" is the basis.
   - Sphere is a Coast to Coast RV sub-brand (trade-only; go via the selling
     retailer) — service portal
     <https://coastrv.my.site.com/coastrv/s/contact-us>, warranty policy
     <https://www.coastrv.com.au/pages/warranty-policy>,
     technical@coastrv.com.au, warranty@coastrv.com.au; branches NSW 02 9645 7600,
     VIC 03 9930 0500, QLD 07 3386 7100, WA 08 9484 6000.
   - Manufacturer: Zhuhai JoySuny New Energy Tech, sales@joysuny.com,
     +86 137 2516 0159 (a Phoenix Technology Group JV).
   - State it precisely: *"BLE module (Nations NS-BLE-1.0) advertises and answers
     AT+V, but the BMS MCU is not running after output-off with Bluetooth standby
     on; with both MOS open no current path exists for the documented wake."* Ask
     for a terminal-side activation procedure or dealer tool.

## 6. Sources

- Sphere EVO Lithium User Guide (Coast to Coast RV, "Sphere - 2024"):
  <https://www.mygenerator.com.au/assets/files/CRM4840_Sphere_Battery_User_Guide.pdf>
- RV Battery app in-app help ("Bluetooth Standby"):
  `artifacts/rv-battery-1.0.4/apktool/res/values/strings.xml` line 147
- JoySuny JS 100-12-50 datasheet ("BMS Reconnect: Automatic"; 0.8 A low-voltage
  charging path): <https://www.joysuny.com/filedownload/108478>
- Nations N32WB03x datasheet (BLE SoC, PD wake sources):
  <https://www.nsing.com.sg/uploads/DS/EN_DS_N32WB03x.pdf>;
  N32G435 datasheet (STOP/STANDBY wake sources):
  <https://www.nsing.com.sg/uploads/DS/EN_DS_N32G435.pdf>
- Actions Technology SDK (the `e49a…` UUIDs are Actions', not Telink):
  <https://github.com/lvgl/lv_port_actions_technology>
- Daly BMS sleep/wake strategy (Bluetooth is not a wake source):
  <https://www.dalybms.com/news/daly-smart-bms-control-strategy/>
- ABLIC S-82B1B protection IC (charger-present release via VM pin):
  <https://www.ablic.com/en/doc/datasheet/battery_protection/S82B1B_E.pdf>
- Full agent reports: this session, 2026-09-21 (four parallel investigations:
  app/SDK re-reverse, BLE module, hardware/manuals, ecosystem).
