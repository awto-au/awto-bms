# Proposal: Python Desktop GUI for Live Battery Status & Graphs

**Status: PROPOSAL / design document only.** Nothing in this document has been
implemented. No dependencies have been added, no application code written. This
is a design and recommendation to be reviewed before any build work starts.

**Author:** dan@awto.au · **Date:** 2026-09-19 · **Scope:** `awto-sphere`

---

## 1. Goal & scope

Build a cross-platform (Windows-first) Python desktop GUI that visualises the
JoySuny JS*/RV* BMS fleet already read by
[`python_ble/read_batteries.py`](../python_ble/read_batteries.py). The reader
today is headless: it scans/connects many packs over BLE (Bleak, asyncio),
decodes ~1 Hz telemetry frames, prints a 2 s fleet table, and logs to per-serial
text files plus SQLite. The GUI adds a live, graphical front end on top of the
**same decode logic** — no protocol re-implementation.

### 1.1 What the GUI must show

**Per battery (live status tiles):**

- SOC (%), pack voltage (V), pack current (A, signed by charge state), power (W)
- Per-cell voltages (n cells, mV → V) with min/max/avg/delta highlight
- Temperatures: `t1`, `t2`, chip temperature
- MOS status (charge+discharge FET), gate states (temp / smoke / heat / passive
  balance), charge state (idle / charging / discharging)
- Alarms: current (OCP/short), voltage (cell/pack over/under), temperature
  (chip/MOS over/under) — active/inactive with a visible latch
- RSSI (dBm), connected/offline state, firmware version, cycle count
- Estimated time-to-full / time-to-empty, remaining/full capacity (Ah)

**Fleet aggregate:** combined SOC, total capacity/remaining, net power, net
current, live-pack count — mirroring `print_table()` today.

**Time-series graphs (history + live):**

- Per-cell voltages (n lines) and pack voltage
- Pack current and power
- Temperatures (t1/t2/chip) and SOC
- A **fault/alarm timeline** (state bands, not a line plot)

### 1.2 Rendering semantics (must match the interval model)

The user is finalising an interval-based logging model:
`readings(serial, metric, value, start_ms, end_ms)` — **change-only, no
deletion**, plus a rolling in-memory last-hour buffer. The GUI's charts must
render that model faithfully:

- **Held segments:** a value is valid from `start_ms` to `end_ms`; the plot must
  draw a horizontal hold (step / ZOH), *not* linearly interpolate between two
  distant change points. LiFePO4 packs sit flat for long periods, so change-only
  storage produces sparse rows that must render as steps.
- **Offline gaps:** when a pack is offline (no coverage between an `end_ms` and
  the next `start_ms`), the line must **break** — draw a gap, never bridge it. A
  bridged line would fabricate telemetry across a disconnect.

These two behaviours are the visual contract with the storage model and drive
the plot-library choice (see §4.3).

### 1.3 Non-goals

- No control/write commands (MOS, gate, factory, OTA). The reader is read-only
  by design (PROTOCOL.md §"For a read-only reader"); the GUI stays read-only in
  every phase. A future "control" mode is explicitly out of scope here.
- No cloud/remote access, no multi-user server, no authentication (there is none
  on the wire anyway).
- Not a replacement for the SQLite store — the GUI is a consumer of it.

---

## 2. GUI framework options

Weighed on: live-update performance at 1 Hz across many series; packaging to a
single Windows `.exe`; licensing; dev effort; graphing quality.

### 2.1 PySide6 / PyQt6 + pyqtgraph  — *recommended*

Qt widgets for the shell (tiles, tables, docks), **pyqtgraph** for plots.

**Pros**

- pyqtgraph is built for exactly this: fast, OpenGL-optional 2D plotting that
  redraws many live series at ≥1 Hz without breaking a sweat (it targets
  real-time instrumentation). `setData()` on a curve is cheap; downsampling and
  clip-to-view are built in for long histories.
- Mature, native-looking desktop widgets; docking, tables, styling, hi-DPI on
  Windows all solid.
- **qasync** exists specifically to run asyncio (and therefore Bleak) *inside*
  the Qt event loop — a first-class answer to the integration problem (§3).
- Packages to a Windows `.exe` with PyInstaller; well-trodden path.
- Large ecosystem, long-term maintained.

**Cons**

- Qt is a big dependency; PyInstaller bundles are large (tens of MB+).
- Two APIs: **PySide6 is LGPL** (Qt Company official) vs **PyQt6 is GPL v3 or a
  paid commercial licence** (Riverbank). This matters — see §2.6. Prefer
  **PySide6** to avoid GPL obligations on a potentially closed distribution.
- pyqtgraph is functional-looking, not "pretty"; polish takes effort (though
  fine for an instrumentation tool).
- Threading rules are strict: **widgets may only be touched on the GUI thread**
  (see §3.3).

### 2.2 Dear PyGui

Immediate-mode GPU-rendered GUI with a built-in plotting module.

**Pros**

- Very fast rendering (GPU), built-in plots, no separate plot lib.
- Single dependency, small-ish, good for dashboards.
- Simple API; quick to stand up tiles + plots.

**Cons**

- Immediate-mode model is less natural for complex, stateful, dockable desktop
  UIs; fewer standard widgets (tables, tree views) than Qt.
- Smaller community; fewer answers when something goes wrong.
- Its plots are good but give less fine-grained control over *step + gap*
  rendering than pyqtgraph; you'd hand-build stepped series and gaps (feasible,
  but manual).
- Asyncio integration is DIY: no equivalent of qasync; you run Bleak in a
  background thread and marshal into DPG's render loop.
- Packaging works but is less documented than Qt+PyInstaller.

### 2.3 Web approach — Dash/Plotly, or FastAPI + WebSocket + JS charts

Serve a browser UI; Plotly (Dash) or a JS chart lib over websockets.

**Pros**

- Best-looking charts with least effort (Plotly is genuinely nice); zoom/pan/hover
  for free.
- Trivially remote-accessible (open in any browser, phone included).
- Clean separation: reader/server process vs presentation.

**Cons**

- **Live 1 Hz across many series is the weak spot.** Plotly/Dash redraw is
  heavier than pyqtgraph; many cells × many packs streaming every second can get
  janky without careful `extendTraces`/partial-update plumbing and throttling.
- Not a "desktop app" — packaging to a single `.exe` means bundling a server +
  launching a browser (or an Electron/pywebview shell), which is more moving
  parts, not fewer.
- More architecture: an HTTP/WS server, a client, serialization, state sync.
- Step + gap rendering is doable in Plotly (`line_shape="hv"`, `None` to break
  lines) but you're pushing JSON over the wire every tick.

Good fit **later** if remote/multi-viewer access becomes a requirement; overkill
for a Windows-first local tool now.

### 2.4 TUI — Textual

Rich terminal UI.

**Pros**

- Lightweight, fast to build, looks modern for a terminal, trivial to run over
  SSH, tiny packaging.
- A natural, low-risk upgrade path from today's `print_table()` — live tiles and
  a fleet table map directly onto Textual widgets.

**Cons**

- **Graphing is the dealbreaker.** Terminal plots (textual-plotext / braille
  charts) are coarse; per-cell voltage lines, held-segments and offline gaps do
  not render with the fidelity this tool needs. Fine for sparklines, not for the
  analysis graphs in §1.1.
- No pixel-accurate charts, limited hover/zoom.

Excellent as a **secondary** "headless-friendly live dashboard" (a stretch
goal), but it cannot satisfy the graphing requirement as the primary UI.

### 2.5 Quick comparison

| Criterion | PySide6 + pyqtgraph | Dear PyGui | Web (Dash/FastAPI) | Textual (TUI) |
|---|---|---|---|---|
| Live 1 Hz, many series | Excellent | Very good | Fair (needs tuning) | N/A (no real charts) |
| Graph quality / control | Excellent (step+gap easy) | Good (manual step+gap) | Excellent look, heavier | Poor |
| Windows `.exe` packaging | Good (PyInstaller) | OK | Complex (server+shell) | Trivial |
| Licensing | **LGPL (PySide6)** | MIT | MIT/BSD | MIT |
| asyncio/Bleak integration | **qasync (first-class)** | thread+queue | separate process | thread+queue |
| Dev effort | Medium | Medium-low | Medium-high | Low |
| Desktop-native feel | Excellent | Good | Not native | Terminal |

### 2.6 Licensing note (call it out early)

- **PySide6** — LGPL v3 (Qt Company). Can ship in a proprietary/closed app
  without releasing source, provided the usual LGPL conditions (dynamic linking /
  replaceable library, attribution) are met. **This is the safe default.**
- **PyQt6** — GPL v3 *or* a paid Riverbank commercial licence. Under GPL, a
  distributed app must be GPL too. Avoid unless a commercial licence is bought.
- pyqtgraph (MIT), Dear PyGui (MIT), Plotly/Dash (MIT), Textual (MIT), Bleak
  (MIT) are all permissive.

**Recommendation: PySide6** (not PyQt) to keep distribution options open.

---

## 3. The hard integration problem: Bleak (asyncio) + a GUI event loop

Bleak is asyncio-native: scanning, connecting, notifications and writes all run
on an asyncio event loop (`asyncio.run(run(...))` in the current reader). A Qt /
Dear PyGui app has **its own** event loop. Two loops cannot both "own" the main
thread naively. There are two robust patterns.

### 3.1 Option A — Bleak in a background thread + thread-safe queue (portable)

- Run the existing async `run(...)` machinery on a **dedicated background
  thread** with its own asyncio loop (`asyncio.new_event_loop()` +
  `loop.run_forever()` in the thread).
- The GUI runs its own loop on the **main thread**.
- Decoded updates cross the boundary via a **thread-safe `queue.Queue`** (the
  reader already uses this exact pattern for its SQLite writer — see
  `SqliteWriter`). The GUI drains the queue on a timer.

**Pros:** framework-agnostic (works for Qt, Dear PyGui, TUI); clean separation;
mirrors code already in the repo. **Cons:** you manage two loops and the
hand-off yourself; must never touch widgets from the BLE thread (§3.3).

### 3.2 Option B — Integrate the loops with qasync (Qt only) — *recommended*

- **qasync** provides an asyncio event loop implemented on top of Qt's event
  loop, so Bleak coroutines and Qt widgets live on the **same thread and same
  loop**. You `await` Bleak directly from slots; you update widgets directly from
  coroutines — no cross-thread marshalling needed for the common path.

**Pros:** eliminates the two-loops problem; no queue/threading for the hot path;
the cleanest possible Bleak↔Qt story; well-matched to the recommended stack.
**Cons:** Qt-specific (locks us to the Qt choice); a heavy CPU task inside a
coroutine would still block the shared loop — but decoding here is trivial and
BLE is I/O-bound, so this is a non-issue at 1 Hz.

### 3.3 Thread-safety of widget updates (the rule that bites people)

- **Qt: GUI objects may only be created/modified on the GUI (main) thread.**
  - With **qasync (Option B):** coroutines run on the GUI thread already →
    update widgets directly. Safe.
  - With a **background BLE thread (Option A):** never call `widget.setText(...)`
    from the BLE thread. Marshal to the GUI thread via a **`QueuedConnection`
    signal/slot** (`Signal.emit` is thread-safe and delivers on the receiver's
    thread), or drain a `queue.Queue` from a `QTimer` on the GUI thread. pyqtgraph
    `setData()` must likewise run on the GUI thread.
- **Dear PyGui:** mutate the UI only from the render thread; push data via a
  thread-safe queue drained in a frame callback.

### 3.4 Recommendation for §3

Use **qasync (Option B)** with the recommended Qt stack: it makes the whole
asyncio-vs-GUI conflict disappear and removes a class of threading bugs. Keep
the reader's async design intact and simply drive it from qasync's loop instead
of `asyncio.run`. If the project ever moves off Qt, fall back to **Option A**
(thread + queue), which the codebase already demonstrates.

---

## 4. Data flow

Three data sources feed the GUI: **live decoded values** (now), the **in-memory
last hour** (smooth recent plots), and the **SQLite interval store** (history).

### 4.1 Live decoded values → GUI

The reader's `Parser` already accumulates decoded state in `parser.state` (a
dict: `soc`, `volt`, `cur`, `cells`, `power`, `t1`, `t2`, `chip`, `mos`,
`charge_state`, `rssi`, `connected`, `fw`, alarms, …) and calls `emit()` on every
frame. Two clean tap points:

- **Pull:** the GUI already holds the `(name, parser)` list; a GUI timer reads
  `parser.state` snapshots for the live tiles (cheap, same as `print_table`).
- **Push (preferred for graphs):** extend `emit()`/`Parser` with an optional
  **callback/observer** (`on_update(serial, state, tag, ts)`), set by the GUI.
  With qasync this callback runs on the GUI loop and can update widgets directly;
  with the thread model it `Signal.emit`s or enqueues. This adds *one hook* to
  the parser and reuses all decoding — no duplication.

### 4.2 History from the SQLite interval store

- The GUI opens the same DB **read-only** (`sqlite3.connect("file:...?mode=ro",
  uri=True)`), on its own connection, off the GUI thread (a worker/`QThread` or a
  qasync `run_in_executor`) so a range query never freezes the UI.
- Query shape against `readings(serial, metric, value, start_ms, end_ms)`:
  `SELECT start_ms, end_ms, value FROM readings WHERE serial=? AND metric=? AND
  end_ms >= ? AND start_ms <= ? ORDER BY start_ms` (window = the visible time
  range). An index on `(serial, metric, start_ms)` keeps this fast; recommend
  adding it to the writer's DDL.
- **Note on today's schema:** the reader currently writes the wide
  `battery_frames(ts, serial, frame, message, data)` table, *not* `readings`. The
  proposal assumes the user's in-progress interval writer lands first. If the GUI
  is built before that, an adapter can derive per-metric series from
  `battery_frames.data` JSON — but building against `readings` is cleaner and is
  the intended path. **This is a dependency/sequencing risk (see §6.3).**

### 4.3 Rendering held-segments + offline gaps (pyqtgraph)

Both storage semantics map directly onto pyqtgraph primitives:

- **Held segments (ZOH / step):** plot with `stepMode` so each `(start_ms,
  value)` holds flat until the next change point (equivalently, expand each
  interval to two points `(start_ms, v)`,`(end_ms, v)`). This is the correct
  visual for change-only storage and avoids diagonal interpolation across long
  flat regions.
- **Offline gaps:** where there is no interval coverage (a hole between one
  `end_ms` and the next `start_ms`, i.e. the pack was offline), insert a **NaN /
  `connect="finite"` break** so pyqtgraph lifts the pen and the line breaks —
  never bridging a disconnect. pyqtgraph's `connect` array / NaN handling does
  exactly this.
- **Live tail:** append the in-memory last-hour buffer as the newest segment so
  the right edge of every chart advances smoothly at 1 Hz (`curve.setData(...)`
  on the GUI thread). The seam between "history from SQLite" and "live buffer" is
  a simple timestamp join.
- **Fault timeline:** render alarm/charge-state as colored horizontal bands
  (`LinearRegionItem` / filled rects) keyed on the same interval rows, not as a
  line.

### 4.4 Update cadence

- **Live tiles / fleet table:** refresh ~1–2 Hz (matches frame rate; no value in
  faster).
- **Live graphs (tail append):** ~1 Hz, appending only new points.
- **History (re-query):** only on user action — pan/zoom, range change, pack
  selection — not on a timer.

---

## 5. Architecture sketch

Keep the reader's proven pieces; add a thin presentation layer. **Reuse
`Parser`, the frame tables, and the decode math verbatim** — do not re-decode
frames in the GUI.

```
+---------------------------------------------------------------+
|  Main thread: Qt + qasync event loop (one loop)               |
|                                                               |
|  BleService (async)          UI layer (widgets)               |
|   - reuses read_batteries:    - FleetView (table/grid)        |
|     scan_all, stream,          - BatteryPanel per pack:       |
|     Parser, decode tables        tiles + cell bars + gauges   |
|   - discovers/reconnects      - ChartsView (pyqtgraph):       |
|   - on each emit -> callback     cells / V / A / W / temp /   |
|                                  SOC / fault timeline         |
|          | on_update(serial,state,tag,ts)  (same loop)        |
|          v                                                    |
|  AppState / models  <----- HistoryReader (SQLite, read-only, |
|   - per-serial live state         run in executor / worker)  |
|   - last-hour ring buffer                                     |
+---------------------------------------------------------------+
              ^                              ^
              | BLE (Bleak)                  | SQLite file (RO)
        [ JS*/RV* packs ]            logs/battery.db (readings)
```

### 5.1 Modules / classes

- **`ble_service.py`** — wraps the existing async `run()`/`scan_all()`/`stream()`
  and `Parser`. Exposes `start()`, `stop()`, and an `on_update` observer hook. Do
  this by **importing** from `python_ble/read_batteries.py` (after a light
  refactor to make `Parser`/`stream` importable — see §6.1), so there is a single
  source of decode truth.
- **`app_state.py`** — `FleetState` holding `{serial: BatteryState}`; each
  `BatteryState` mirrors `parser.state` plus a per-metric **last-hour ring
  buffer** for smooth live plotting.
- **`history_reader.py`** — read-only SQLite access to `readings`; windowed
  per-metric queries; returns interval rows ready for step/gap expansion. Runs
  off the GUI thread.
- **`series_model.py`** — turns interval rows + live buffer into pyqtgraph-ready
  arrays, applying **ZOH expansion** and **NaN gap insertion** (§4.3). One place
  owns the interval-model rendering contract.
- **UI:** `main_window.py` (shell, docks, pack selector), `fleet_view.py`
  (aggregate table like `print_table`), `battery_panel.py` (live tiles, per-cell
  bar strip, alarm lamps, RSSI/online badge), `charts_view.py` (the pyqtgraph
  plots + fault timeline), `theme.py`.
- **`app.py`** — builds the qasync loop, wires `BleService.on_update` → models →
  widgets, starts everything.

### 5.2 Threads

- **1 loop, 1 thread** for BLE + UI (qasync). BLE is I/O-bound; decode is
  trivial → no starvation at 1 Hz.
- **History queries** offloaded via `loop.run_in_executor` (or a `QThread`
  worker) so range scans never block the UI.
- Fallback (non-Qt) design keeps BLE on a background thread + `queue.Queue` +
  signal marshalling (§3.1).

---

## 6. Phased plan, effort, risks, packaging

Estimates assume one developer already fluent in the repo; ranges are calendar
days of focused work, not guarantees.

### 6.1 Phase 0 — Make the reader importable (prep) · ~1–2 days

- Refactor `read_batteries.py` so `Parser`, `stream`, `scan_all`, and the frame
  tables are importable without running `main()` (guarded by
  `if __name__ == "__main__"` — already the case). Add the `on_update` observer
  hook to `Parser.emit`. No behaviour change to the CLI.
- **Deliverable:** the CLI still works; a second module can drive the same
  decode.

### 6.2 Phase 1 — MVP: live-only GUI · ~3–5 days

- PySide6 window + qasync loop driving the existing scan/connect/stream.
- Fleet table (port of `print_table`) + per-battery live tiles (SOC, V, A, W,
  temps, MOS/charge-state, RSSI, online/offline, alarms, per-cell bar strip).
- Live graphs from the **in-memory last-hour buffer only** (pyqtgraph, step
  mode), no SQLite yet.
- **Deliverable:** a working live dashboard for the fleet, read-only.

### 6.3 Phase 2 — History from the interval store · ~3–5 days

- `history_reader.py` + `series_model.py`: read `readings`, expand to
  **held-segments**, insert **offline gaps**, seam history to the live tail.
- Range/zoom/pan controls; per-pack and per-metric selection; fault timeline.
- Add the recommended `(serial, metric, start_ms)` index to the writer's DDL.
- **Deliverable:** full history + live charts honouring the interval model.
- **Gating dependency:** the user's `readings` interval writer must exist. If it
  slips, either wait or ship a temporary `battery_frames`-JSON adapter.

### 6.4 Phase 3 — Polish & packaging · ~2–4 days

- Theming/hi-DPI, layout persistence, alarm latching/acknowledge, CSV/PNG export
  of a chart window, settings (DB path, scan interval).
- **PyInstaller** one-folder then one-file Windows build; smoke-test on a clean
  Windows 11 box.
- **Deliverable:** distributable `.exe`.

**Rough total:** ~9–16 focused days across phases 0–3.

### 6.5 Key risks

- **Bleak on Windows quirks** — multi-device connect, reconnect storms, WinRT
  adapter behaviour. Mitigated: the existing reader already handles multi-pack
  connect/reconnect; the GUI reuses it rather than rewriting BLE.
- **Schema timing** — GUI history depends on the in-progress `readings` model
  (§4.2/§6.3). Mitigation: build MVP (Phase 1) with zero DB dependency; add
  history once `readings` lands.
- **UI thread blocking** — a slow history query or a decode callback on the wrong
  thread freezes the UI. Mitigation: qasync single-loop for the hot path,
  executor for queries, strict "widgets on GUI thread only" rule (§3.3).
- **PyInstaller + Bleak/Qt bundling** — hidden imports, Qt plugins, WinRT
  dependencies can be fiddly. Mitigation: budget Phase 3 time; test one-folder
  before one-file.
- **Chart perf with many packs × many cells** — mitigated by pyqtgraph
  downsampling/clip-to-view and appending only new points.

### 6.6 Packaging story

- **PyInstaller** (Windows-first, one-file `.exe`). Ship the reader + GUI as one
  bundle. Expect to declare Qt plugins and Bleak/WinRT hidden imports.
- Alternatives noted, not recommended now: Nuitka (faster startup, more complex),
  a plain venv + launcher script (dev only).
- The `.exe` reads the same `logs/battery.db`; no server, no install of Python on
  the target.

---

## 7. Final recommendation

**Build the GUI with PySide6 (LGPL) + pyqtgraph, and integrate Bleak using
qasync so BLE and the UI share one asyncio event loop on the main thread.**

Why this combination wins:

1. **Live performance:** pyqtgraph is purpose-built for real-time instrument
   plots — many series at ≥1 Hz with downsampling and clip-to-view, and it makes
   the interval model's **step (held-segment)** and **NaN-break (offline-gap)**
   rendering first-class.
2. **The integration problem dissolves:** qasync runs Bleak coroutines *inside*
   Qt's loop, so there is no two-loops conflict and no cross-thread widget
   marshalling on the hot path — the single largest source of bugs in this class
   of app.
3. **Licensing is clean:** PySide6 is LGPL (ship closed if desired); PyQt's GPL
   trap is avoided.
4. **Native desktop + Windows packaging:** proper widgets/tables/docks and a
   proven PyInstaller `.exe` path.
5. **Maximum reuse, minimum duplication:** it drives the *existing* `Parser` and
   decode tables via one added observer hook — the protocol lives in exactly one
   place.

Fallbacks, if constraints change: **Dear PyGui** (if a single MIT dependency and
GPU rendering are preferred over Qt's breadth) with a thread+queue bridge; the
**web/Dash** stack only if remote/multi-viewer access becomes a hard
requirement; **Textual** as a lightweight secondary live dashboard, never as the
primary graphing UI.

**Reminder: this is a proposal. No code, dependencies, or schema changes have
been made.**
