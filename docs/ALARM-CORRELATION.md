# Alarm bits vs. measured values — correlation (data to 2026-09-23)

Sources: PC Python reader logs + `battery.db` (18–19 Sep), the phone app's raw
log (19 Sep 20:38 → 23 Sep, with gaps) and its interval DB (19 → 22 Sep).
Full method and queries: session analysis 2026-09-23 (`alarm_timeline.py`).

## Every alarm-byte change ever observed

| Pack | When | Frame / byte | Change | What was happening |
|---|---|---|---|---|
| AA | first contact 18 Sep 17:04 | temp p2 (latched over-temp) | already 1 | 0 A, 31–38 °C, cells 3.33 V, SOC held at 100 % |
| AA | **19 Sep 18:31:21.7** | temp p2 | **1 → 0** | BMS restart: SOC re-derived 100 → 93 % 90 ms later; all sensors 33 °C, 0 A |
| B8 | first contact 18 Sep 17:39 | temp p2 | already 1 | 0 A, 36–38 °C, charger present |
| B8 | **19 Sep 18:29:47.6** | temp p2 | **1 → 0** | BMS restart (same SOC 100 → 93 % signature) |
| B8 | **21 Sep 15:06:59.3 → 15:07:01.0** | **current p2 (short-circuit)** | 0 → 1 → 0 (1.7 s) | Output had been switched OFF at 15:06:50 while a ~90 A load was attached; switched ON again at 15:06:58.8. The bit set 0.5 s after the gate ack while current still read 0 A and MOS still read off, then cleared itself the moment the FETs closed; current ramped 1.5 → 19 → 81 → 89 A over the next 9 s. |
| B8 | 21 Sep 15:07:00.1 (one frame) | MOS-status p3 (undocumented) | 0 → 1 → 0 | between the short-circuit flag and FET closure — plausibly "retry / pre-charge in progress" |

Nothing else ever changed: current p0/p1, every voltage-alarm byte, temp
p0/p1/p3/p4/p5/p6, all zero in every frame of every source (13 000+ app
frames, 5 000+ Python frames, every interval-DB row).

## What each bit means, from the data

- **Temp p2 = latched over-temperature protection.** Set on both packs before
  any of our logging existed; not correlated with temperature while held (25 h
  at 31–38 °C, 0 A); cleared **only** by the restart, once per pack; has not
  re-set since, including B8's 2 h at 88–90 A (t1 43 °C) and 27.7 A charging.
  The original trip threshold is undetermined (predates data).
- **Temp p3 / p6 ("MOS over-temp" per the vendor app)** — never toggled under
  any condition we produced. Meaning unverified.
- **Current p2 (short-circuit)** — an **inrush check on FET turn-on with
  automatic retry**, not a steady-state threshold: 90 A continuous for nearly
  2 h never tripped it; closing the FETs into an attached 90 A load did, for
  two frames, and it self-cleared. Practical consequence: turning output ON with
  a large load already connected briefly trips short-circuit protection — the
  BMS handles it, but expect a 1–2 s blip.
- **Current p0 / p1 (over-current discharge / charge)** — thresholds are above
  90.4 A discharge and 27.7 A charge (never tripped).
- **Voltage bits** — never tripped between 3.24 and 3.56 V/cell.
- **Nothing is set by a handshake, restart, sleep or gate write**: 240
  handshakes and every restart/factory/sleep/gate command left all alarm bytes
  at 0 (except the one inrush event above).

## Corrections to earlier notes

- The latched bit **cleared at 18:31:21 (AA) / 18:29:47 (B8) on 19 Sep**, at the
  restart — not "around 20:38"; 20:38 is merely when raw logging began.
- **AA's output was never observed OFF.** Its last live telemetry (20 Sep
  06:56–07:03) shows MOS on, charge+discharge on, idle, 0 A, 93 %, 3.33 V, all
  alarm bytes 0. From 20 Sep 21:02 the app only ever saw "no telemetry". The
  app's "Charge — / Output —" at that point was the no-data display, not an
  OFF reading. Whatever silenced AA happened between 07:03 and 21:02 on 20 Sep
  with no observer and no alarm precursor. **Bluetooth standby was OFF on AA**
  (its stored flag read "mode=off" at every handshake on 19 Sep; no standby-ON
  was ever sent to it before it went silent — the only one in the log is at
  20 Sep 21:04, after it was already dormant). So the vendor's documented
  standby behaviour does not explain it: a pack with standby off, MOS on, idle,
  no alarms, stopped transmitting. Cause undetermined — a BMS hang or an
  undocumented protection state; the spec row "BMS Re-Connect: Auto" did not
  hold. Confidence in any specific cause: low (a 14 h blind spot, one event).

## Measured envelope (real frames only)

| | JS-2C14AA | JS-2C14B8 |
|---|---|---|
| max current | 0.0 A (never carried current while observed) | −90.4 A discharge, +27.7 A charge |
| temperatures t0..t3 | 25–38 °C | 25–43 °C |
| chip temperature | always 0 (field unused by this firmware) | always 0 |
| cell voltage | 3.33 V flat | 3.25–3.56 V |
| SOC | 100 % (latched) → 93 % after restart | 0–100 % |

## What remains undetermined, and the test that settles it

1. Temp p2 trip threshold — heat-soak / high-current test with raw logging, or
   the JS5.1 protection table from JoySuny/Nations.
2. Temp p3/p6 meaning — MOS heatsink thermal test.
3. Current p0/p1 thresholds — load ramp above 100 A; charger above 30 A.
4. Whether a *hard* short latches current p2 instead of self-clearing.
5. Voltage bits — full charge to 3.65 V/cell and deep discharge to ~2.5 V under
   logging.
6. AA's dormancy cause — physical/bench only (see WAKE-INVESTIGATION.md).

## Decoder consistency

Python reader and app agree byte-for-byte on every alarm frame. Differences
are labelling only: the Python reader still lists temp p2/p3/p6 as live
"MOS over-temp" faults (pre-#50), the app treats p2 as the latched protection
and p3/p6 as unknown; the reader decodes only t1/t2 where the app decodes
t0..t3. Log tag names differ cosmetically.
