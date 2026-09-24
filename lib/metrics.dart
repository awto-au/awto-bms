/// The ONE metric catalogue (review pass C2, GitHub #51).
///
/// Before this pass the same set of metrics was enumerated in five places —
/// what the logger writes (`BatteryLogger._onEvent`), what the charts page
/// loads and draws, which rows get a sparkline on the detail page, the detail
/// page's key/value sections, and the console decode line. Each list drifted
/// on its own. Now [metricTable] is the single source: one [MetricDef] row per
/// metric says how it is EXTRACTED for logging, how it is FORMATTED for
/// display, its colour, whether it is signed (axis centred on 0), which chart
/// card and which detail section it belongs to, and whether it gets a
/// sparkline. The logger iterates it to decide what to log; the charts and
/// sparklines filter it; the detail rows render from it. Adding a metric is
/// adding one row.
///
/// The metric KEYS ([Metric]) are unchanged — they are the `metric` column of
/// the interval store and must stay byte-identical to the Python store's.
/// Two things stay special-cased in the logger, exactly as before: the
/// per-cell voltages (`cell1..cellN`, however many the pack reports, M14) and
/// the packed `flags` integer (written only once every contributing state is
/// known, M8). A handful of rows are DISPLAY-ONLY (`logged == false`): the
/// individual booleans that are logged packed inside `flags` (charge state,
/// load / charger connected, MOS / charge MOS / discharge MOS / passive
/// balancing — named after the `flags_bits` view columns) and the resync
/// byte counter. They appear on the detail page but never as their own row.
library;

import 'package:flutter/material.dart' show Color;

import 'battery_connection.dart';
import 'battery_protocol.dart' show BatteryState, ChargeState;
import 'fmt.dart';
import 'health_palette.dart';
import 'temp_unit.dart';

// ---------------------------------------------------------------------------
// Metric identifiers. One interval run per (serial, metric).
// ---------------------------------------------------------------------------

class Metric {
  // Per-cell voltages, volts. M14: `cell${i+1}` for EVERY cell the VOL frame
  // carries (its count prefix), not a fixed four — a bigger pack has more.
  static const cell1 = 'cell1';
  static const cell2 = 'cell2';
  static const cell3 = 'cell3';
  static const cell4 = 'cell4';
  static const cells = [cell1, cell2, cell3, cell4];

  /// The metric name for the [index]-th (0-based) cell: `cell1`, `cell2`, …
  static String cell(int index) => 'cell${index + 1}';

  /// The 1-based cell number encoded in a `cellN` metric name, or null for any
  /// other metric (including `cellSum` / `cellMax` / … which are not cells).
  static int? cellIndex(String metric) {
    if (!metric.startsWith('cell')) return null;
    return int.tryParse(metric.substring(4));
  }

  /// Sort key for cell metrics: `cell2` before `cell10` (numeric, not text).
  static int compareCells(String a, String b) =>
      (cellIndex(a) ?? 0).compareTo(cellIndex(b) ?? 0);

  // Pack / cell-aggregate numeric metrics.
  static const packVoltage = 'packV'; // volts
  static const cellSum = 'cellSum'; // volts
  static const cellMax = 'cellMax'; // volts
  static const cellMin = 'cellMin'; // volts
  static const cellAvg = 'cellAvg'; // volts
  static const cellDelta = 'cellDelta'; // volts
  static const packCurrent = 'packI'; // amps, SIGNED (+in / -out)
  static const power = 'power'; // watts, SIGNED (+in / -out)
  static const soc = 'soc'; // percent
  static const remainingAh = 'remAh';
  static const fullAh = 'fullAh';

  /// BMS time estimates (seconds), from the Time-estimate frame. Logged so a
  /// durable (soc, timeToFull, timeToEmpty, current/power) record accumulates
  /// for later comparison against our own coulomb-counted estimate.
  static const timeToFullSec = 'timeToFullSec';
  static const timeToEmptySec = 'timeToEmptySec';
  static const cycleCount = 'cycles'; // raw firmware counter (NOT a real odometer)
  // #114: the TEMP frame is two sensors each reported twice. The keys are NOT
  // in byte order (temp2 = byte[3], temp3 = byte[2]); they never change.
  static const temp0 = 'temp0'; // deg C (byte[0]) — sensor A copy, not shown
  static const temp1 = 'temp1'; // deg C (byte[1]) — sensor B: "Temp B"
  static const temp2 = 'temp2'; // deg C (byte[3]) — sensor A: "Temp A"
  static const temp3 = 'temp3'; // deg C (byte[2]) — sensor B copy, not shown
  static const chipTemp = 'chip'; // deg C (A2 57 byte[7]; always 0), not shown
  static const rssi = 'rssi'; // dBm

  /// Equivalent full cycles (EFC): cumulative |I| dt Ah throughput divided by
  /// the pack's rated capacity (fullAh). This is OUR computed cycle odometer;
  /// the BMS `cycles` value dithers 0<->1 at rest and is not a real count.
  static const efc = 'efc';

  // Byte-valued gates: their own numeric metrics (not single bits).
  static const tempControlGate = 'tempGate';
  static const smokeGate = 'smokeGate';
  static const heatGate = 'heatGate';

  static const firmwareVersion = 'firmware'; // string (value_text)

  /// #50: CMD_WARN_TEMP_ALARM byte[2] — the LATCHED over-temperature protection
  /// (1 = latched, charging inhibited; cleared by a BMS restart). Logged as its
  /// own 0/1 metric now that its meaning is known (it was `unknownTempB2`).
  static const overTempLatched = 'overTempLatched';

  /// All the boolean states, the three fault-category flags and the 2-bit
  /// chargeState packed LSB-first into one integer metric — the SAME layout the
  /// Python interval store uses, so a `flags` row means the same thing on both
  /// platforms. See `Flags` in battery_log.dart. Change-only interval row like
  /// any other metric.
  static const flags = 'flags';

  // Display-only rows (NOT metric keys of their own — these states are logged
  // packed inside [flags]; the names are the `flags_bits` view columns).
  static const displayChargeState = 'chargeState';
  static const displayLoad = 'load';
  static const displayCharger = 'charger';
  static const displayMos = 'mos';
  static const displayChgMos = 'chgMos';
  static const displayDisMos = 'disMos';
  static const displayPassiveBal = 'passiveBal';

  /// Display-only: stray bytes dropped on resync (#20). Never logged.
  static const displayUnrecognised = 'unrecognisedBytes';

  /// #53: ADDITIVE sample-mode markers written by the logger with every
  /// reading (not table rows — the logger writes them directly, like `flags`):
  /// [sampleMode] is 0 for a continuous (foreground / held-link) reading and
  /// 1 for a background sample; [sampleIntervalS] is the background sample
  /// interval in seconds in effect (0 = continuous). The charts derive the
  /// gap threshold and the lighter/dotted style from [sampleIntervalS].
  static const sampleMode = 'sampleMode';
  static const sampleIntervalS = 'sampleIntervalS';

  /// #61: display-only frame counter / last-frame age (Gates & status).
  static const displayFrames = 'frames';
  static const displayLastFrame = 'lastFrame';
}

// ---------------------------------------------------------------------------
// The catalogue.
// ---------------------------------------------------------------------------

/// The chart card a metric is drawn on (in page order). `cells` is the
/// dynamic per-cell card (no static rows; the pack's `cellN` metrics fill it).
enum ChartGroup { cells, packVoltage, current, temperature, soc }

/// The detail-page section a metric's key/value row belongs to (page order).
enum DetailSection { pack, capacity, cells, temperature, gates }

/// One metric's complete description. See the library note.
class MetricDef {
  /// The interval-store `metric` key (unchanged; see [Metric]).
  final String key;

  /// Short display label (sparkline row / chart legend).
  final String label;

  /// Unit suffix, for reference ('' where none applies).
  final String unit;

  /// The numeric value to LOG right now, or null to log nothing this event.
  /// Null for a text metric or a display-only row.
  final num? Function(BatteryConnection c)? extract;

  /// The text value to LOG (text metrics only, e.g. firmware version).
  final String? Function(BatteryConnection c)? extractText;

  /// The value as shown beside its sparkline row.
  final String Function(BatteryConnection c) format;

  /// Colour for the chart line (and the sparkline unless [sparkColor] /
  /// [socGraded] say otherwise).
  final Color color;

  /// Sparkline colour when it differs from the chart colour.
  final Color? sparkColor;

  /// The sparkline takes the SOC-graded health colour (state of charge and
  /// remaining capacity).
  final bool socGraded;

  /// Signed metric: axes are centred on 0 (symmetric −m..+m).
  final bool centreZero;

  /// The chart card this metric is drawn on, or null for no chart.
  final ChartGroup? chartGroup;

  /// Chart legend label when it differs from [label].
  final String? chartLabel;

  /// Detail-page section, or null for no detail row.
  final DetailSection? detailSection;

  /// Detail-row label when it differs from [label].
  final String? detailLabel;

  /// Detail-row value when it differs from [format].
  final String Function(BatteryConnection c)? detailFormat;

  /// Long form of a short label (#114), shown as the detail row's tooltip
  /// (e.g. "EFC" → "Equivalent full cycles").
  final String? tooltip;

  /// Position among the detail-page sparkline rows (1-based), or null for no
  /// sparkline.
  final int? spark;

  const MetricDef({
    required this.key,
    required this.label,
    required this.unit,
    required this.format,
    required this.color,
    this.extract,
    this.extractText,
    this.sparkColor,
    this.socGraded = false,
    this.centreZero = false,
    this.chartGroup,
    this.chartLabel,
    this.detailSection,
    this.detailLabel,
    this.detailFormat,
    this.tooltip,
    this.spark,
  });

  /// True iff this metric is written to the interval store as its own row.
  bool get logged => extract != null || extractText != null;

  /// Label on the detail page.
  String get labelOnDetail => detailLabel ?? label;

  /// Label in a chart legend.
  String get labelOnChart => chartLabel ?? label;

  /// Value text on the detail page.
  String detailValue(BatteryConnection c) =>
      (detailFormat ?? format)(c);

  /// The sparkline's colour for the live [c] (SOC-graded rows follow the pack's
  /// state of charge).
  Color sparkColorFor(BatteryConnection c) => socGraded
      ? HealthPalette.colorForSoc((c.state.socPercent ?? 0).toDouble())
      : (sparkColor ?? color);
}

// Chart colours (issue #22 / #32 palette). Temp A / Temp B keep the colours
// their series (temp2 / temp1) had as "Probe 2" / "Probe 1".
const _tempA = Color(0xFFEB5757);
const _tempB = Color(0xFFF2994A);

/// The long form behind the "EFC" label (#114), used as its tooltip.
const efcTooltip = 'Equivalent full cycles';

String _intOrDash(int? v) => v?.toString() ?? '—';

/// #91: a gate byte shown like the other switches: "On" / "Off" / "—".
/// The logged value (extract) stays the raw 0/1.
String _gateOnOff(int? v) => fBool(v == null ? null : v != 0);

/// The Status row's text: [BatteryState.status] as a word. Current flowing
/// with no direction reported reads "Active", never "Idle" or a dash.
String statusText(BatteryState s) {
  final st = s.status;
  if (st == ChargeState.unknown &&
      ((s.packCurrent ?? 0) > 0 || (s.power ?? 0) > 0)) {
    return 'Active';
  }
  return ChargeStateStyle.of(st).shortLabel;
}

/// THE metric table, in detail-page order (section by section). The logger
/// writes every `logged` row in this order; the charts draw each [ChartGroup]'s
/// rows in this order; the sparklines are ordered by [MetricDef.spark].
final List<MetricDef> metricTable = <MetricDef>[
  // --- Pack ----------------------------------------------------------------
  MetricDef(
    key: Metric.soc,
    label: 'SOC',
    unit: '%',
    extract: (c) => c.state.socPercent,
    format: (c) => fPct(c.state.socPercent),
    color: HealthPalette.healthy,
    socGraded: true,
    chartGroup: ChartGroup.soc,
    tooltip: 'State of charge',
    detailSection: DetailSection.pack,
    spark: 4,
  ),
  MetricDef(
    key: Metric.packVoltage,
    label: 'Voltage',
    unit: 'V',
    extract: (c) => c.state.packVoltage,
    format: (c) => fV(c.state.packVoltage),
    color: HealthPalette.telemetryAccent,
    chartGroup: ChartGroup.packVoltage,
    detailSection: DetailSection.pack,
    spark: 2,
  ),
  MetricDef(
    key: Metric.packCurrent,
    label: 'Current',
    unit: 'A',
    // Logged SIGNED (+in / −out); the detail row shows the BMS magnitude.
    // #71: "—" (not "0.0 A") while the pack never reported a current.
    extract: (c) => c.signedCurrent,
    format: (c) => fSignedA(c.signedCurrentOrNull),
    color: HealthPalette.healthy,
    sparkColor: HealthPalette.telemetryAccent,
    centreZero: true,
    chartGroup: ChartGroup.current,
    detailSection: DetailSection.pack,
    detailFormat: (c) => fA(c.state.packCurrent),
    spark: 1,
  ),
  MetricDef(
    key: Metric.power,
    label: 'Power',
    unit: 'W',
    extract: (c) => c.signedPower,
    format: (c) => fW(c.state.power),
    color: HealthPalette.telemetryAccent,
    centreZero: true,
    detailSection: DetailSection.pack,
    spark: 3,
  ),
  MetricDef(
    // The display-only key stays `chargeState` (the flags_bits column name);
    // the row is labelled "Status" and shows [BatteryState.status], not the
    // raw BAL s0 byte (#114 follow-up; docs/PROTOCOL.md "Status rule").
    key: Metric.displayChargeState,
    label: 'Status',
    unit: '',
    tooltip: 'Charging, discharging or idle, from the BMS status and the '
        'measured current',
    format: (c) => statusText(c.state),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.displayLoad,
    label: 'Load',
    unit: '',
    tooltip: 'Load connected',
    format: (c) => fBool(c.state.loadConnected),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.displayCharger,
    label: 'Charger',
    unit: '',
    tooltip: 'Charger connected',
    format: (c) => fBool(c.state.chargerConnected),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.cycleCount,
    label: 'Cycles',
    unit: '',
    tooltip: 'Cycle count as the BMS reports it (raw; not a real odometer)',
    extract: (c) => c.state.cycleCount,
    format: (c) => _intOrDash(c.state.cycleCount),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.efc,
    label: 'EFC',
    unit: '',
    tooltip: efcTooltip,
    extract: (c) => c.equivalentFullCycles,
    format: (c) => fCycles(c.equivalentFullCycles),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  // --- Capacity ------------------------------------------------------------
  MetricDef(
    key: Metric.remainingAh,
    label: 'Remaining',
    unit: 'Ah',
    extract: (c) => c.state.remainingAh,
    format: (c) => fAh(c.state.remainingAh),
    color: HealthPalette.healthy,
    socGraded: true,
    detailSection: DetailSection.capacity,
    spark: 5,
  ),
  MetricDef(
    key: Metric.fullAh,
    label: 'Full / rated',
    unit: 'Ah',
    extract: (c) => c.state.fullAh,
    format: (c) => fAh(c.state.fullAh),
    color: HealthPalette.idle,
    detailSection: DetailSection.capacity,
  ),
  MetricDef(
    key: Metric.timeToFullSec,
    label: 'Time to full',
    unit: 's',
    extract: (c) => c.state.timeToFullSec,
    format: (c) => fTime(c.state.timeToFullSec),
    color: HealthPalette.idle,
    detailSection: DetailSection.capacity,
  ),
  MetricDef(
    key: Metric.timeToEmptySec,
    label: 'Time to empty',
    unit: 's',
    extract: (c) => c.state.timeToEmptySec,
    format: (c) => fTime(c.state.timeToEmptySec),
    color: HealthPalette.idle,
    detailSection: DetailSection.capacity,
  ),
  // --- Cells (the per-cell list itself is dynamic: cell1..cellN) -----------
  MetricDef(
    key: Metric.cellSum,
    label: 'Sum of cells',
    unit: 'V',
    extract: (c) => c.state.cellSum,
    format: (c) => fV(c.state.cellSum),
    color: HealthPalette.idle,
    detailSection: DetailSection.cells,
  ),
  MetricDef(
    key: Metric.cellAvg,
    label: 'Average',
    unit: 'V',
    extract: (c) => c.state.cellAvg,
    format: (c) => fV(c.state.cellAvg),
    color: HealthPalette.idle,
    detailSection: DetailSection.cells,
  ),
  MetricDef(
    key: Metric.cellMax,
    label: 'Max',
    unit: 'V',
    extract: (c) => c.state.cellMax,
    format: (c) => fV(c.state.cellMax),
    color: HealthPalette.idle,
    detailSection: DetailSection.cells,
  ),
  MetricDef(
    key: Metric.cellMin,
    label: 'Min',
    unit: 'V',
    extract: (c) => c.state.cellMin,
    format: (c) => fV(c.state.cellMin),
    color: HealthPalette.idle,
    detailSection: DetailSection.cells,
  ),
  MetricDef(
    key: Metric.cellDelta,
    label: 'Delta',
    unit: 'V',
    extract: (c) => c.state.cellDiff,
    format: (c) => fV(c.state.cellDiff),
    color: HealthPalette.idle,
    detailSection: DetailSection.cells,
  ),
  // --- Temperature (#114) -------------------------------------------------
  // The TEMP frame carries two sensors, each reported twice (see BatteryState
  // in battery_protocol.dart). The UI shows ONE row per sensor:
  //   Temp A = temp2 (byte[3]; byte[0] = temp0 is an exact copy)
  //   Temp B = temp1 (byte[1]; byte[2] = temp3 reads within 1 C)
  // temp1/temp2 are the vendor's pair and the longest stored history. The
  // copies and the chip byte stay LOGGED (all data is kept) but are shown
  // nowhere: the chip byte (A2 57 byte[7]) is 0 in every real frame and a 0
  // must never read as 0 °C.
  MetricDef(
    key: Metric.temp2,
    label: 'Temp A',
    unit: '°C',
    extract: (c) => c.state.temp2,
    format: (c) => fmtTemp(c.state.temp2),
    color: _tempA,
    chartGroup: ChartGroup.temperature,
    detailSection: DetailSection.temperature,
    tooltip: 'Sensor A (frame bytes 0 and 3); location unknown',
    spark: 6,
  ),
  MetricDef(
    key: Metric.temp1,
    label: 'Temp B',
    unit: '°C',
    extract: (c) => c.state.temp1,
    format: (c) => fmtTemp(c.state.temp1),
    color: _tempB,
    chartGroup: ChartGroup.temperature,
    detailSection: DetailSection.temperature,
    tooltip: 'Sensor B (frame bytes 1 and 2); location unknown',
    spark: 7,
  ),
  // Logged only (no chart, no detail row, no sparkline).
  MetricDef(
    key: Metric.temp0,
    label: 'Temp A (byte 0)',
    unit: '°C',
    extract: (c) => c.state.temp0,
    format: (c) => fmtTemp(c.state.temp0),
    color: _tempA,
  ),
  MetricDef(
    key: Metric.temp3,
    label: 'Temp B (byte 2)',
    unit: '°C',
    extract: (c) => c.state.temp3,
    format: (c) => fmtTemp(c.state.temp3),
    color: _tempB,
  ),
  MetricDef(
    key: Metric.chipTemp,
    label: 'Chip',
    unit: '°C',
    extract: (c) => c.state.chipTemperature,
    // Unpopulated by this firmware (always 0): "not reported", never 0 °C.
    format: (c) => fChipTemp(c.state.chipTemperature),
    color: HealthPalette.idle,
  ),
  // --- Gates & status ------------------------------------------------------
  // #58: the two MOSFET switches are shown separately as "Charge switch"
  // (charge MOS) and "Output switch" (discharge MOS); "Both switches" is the
  // MOS_STATUS frame's combined flag. Metric keys unchanged (mos / chgMos /
  // disMos).
  MetricDef(
    key: Metric.displayMos,
    label: 'Both switches',
    unit: '',
    format: (c) => fBool(c.state.mosOn),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayChgMos,
    label: 'Charge switch',
    unit: '',
    format: (c) => fBool(c.state.chargeMos),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayDisMos,
    label: 'Output switch',
    unit: '',
    format: (c) => fBool(c.state.dischargeMos),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayPassiveBal,
    label: 'Passive balancing',
    unit: '',
    format: (c) => fBool(c.state.passiveBalancing),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  // #39: displayed labels renamed now the gate functions are known (the
  // metric keys tempGate / smokeGate / heatGate are unchanged).
  MetricDef(
    key: Metric.tempControlGate,
    label: 'Low-temp protection',
    unit: '',
    extract: (c) => c.state.tempControlGate,
    format: (c) => _gateOnOff(c.state.tempControlGate),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.smokeGate,
    label: 'Smoke sensor',
    unit: '',
    extract: (c) => c.state.smokeGate,
    format: (c) => _gateOnOff(c.state.smokeGate),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.heatGate,
    label: 'Heater',
    unit: '',
    extract: (c) => c.state.heatGate,
    format: (c) => _intOrDash(c.state.heatGate),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.overTempLatched,
    label: 'Over-temp latched',
    unit: '',
    // #50: logged as 0/1 once at least one temperature-alarm frame has been
    // decoded, so "not latched" is never confused with "not reported yet".
    extract: (c) => c.state.temperatureAlarmSeen
        ? (c.state.overTempLatched ? 1 : 0)
        : null,
    format: (c) => !c.state.temperatureAlarmSeen
        ? '—'
        : c.state.overTempLatched
            ? 'Yes — restart to clear'
            : 'No',
    color: HealthPalette.warn,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.firmwareVersion,
    label: 'Firmware',
    unit: '',
    extractText: (c) => c.state.firmwareVersion,
    format: (c) => c.state.firmwareVersion ?? '—',
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.rssi,
    label: 'RSSI',
    unit: 'dBm',
    tooltip: 'Bluetooth signal strength',
    extract: (c) => c.state.rssi,
    format: (c) => fRssi(c.state.rssi),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayUnrecognised,
    label: 'Stray bytes',
    unit: '',
    tooltip: 'Unrecognised bytes dropped on resync',
    // Issue #20: stray bytes dropped on resync (each is also written to the
    // raw log as an UNRECOGNISED line). 0 on healthy hardware.
    format: (c) => '${c.state.unrecognisedBytes}',
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  // #61: is data flowing? Frames decoded on this link and the age of the
  // last one (an em dash while not connected).
  MetricDef(
    key: Metric.displayFrames,
    label: 'Frames (this link)',
    unit: '',
    format: (c) => c.connState == ConnState.connected
        ? '${c.frameCount}'
            '${c.totalFrameCount > c.frameCount ? ' (${c.totalFrameCount} total)' : ''}'
        : '—',
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayLastFrame,
    label: 'Last frame',
    unit: '',
    format: (c) {
      final age = c.silenceMs;
      if (age == null) return '—';
      if (c.lastTelemetryMs == null) {
        return 'none yet (${fmtAgeShort(age)} linked)';
      }
      return '${fmtAgeShort(age)} ago';
    },
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
];

/// Lookup by key (null for `cellN`, `flags` and unknown-byte metrics, which
/// are not table rows).
MetricDef? metricDef(String key) {
  for (final m in metricTable) {
    if (m.key == key) return m;
  }
  return null;
}

/// The rows the logger writes as their own interval rows, in table order.
List<MetricDef> get loggedMetrics =>
    [for (final m in metricTable) if (m.logged) m];

/// The rows with a detail-page sparkline, in row order.
List<MetricDef> get sparkMetrics =>
    [for (final m in metricTable) if (m.spark != null) m]
      ..sort((a, b) => a.spark!.compareTo(b.spark!));

/// The keys the detail page loads for its sparklines.
List<String> get sparkMetricKeys => [for (final m in sparkMetrics) m.key];

/// The rows drawn on chart card [group], in table order.
List<MetricDef> chartSeries(ChartGroup group) =>
    [for (final m in metricTable) if (m.chartGroup == group) m];

/// The detail-page rows for [section], in table order.
List<MetricDef> detailMetrics(DetailSection section) =>
    [for (final m in metricTable) if (m.detailSection == section) m];

/// One key/value row as the detail page shows it: a single catalogue metric,
/// or (#107) several of one section's metrics on ONE line to save vertical
/// space — `Min / Max / Delta   3.305 / 3.320 / 0.015 V`.
class DetailRow {
  final String label;
  final String? tooltip;

  /// The catalogue metrics behind this row, in display order.
  final List<MetricDef> metrics;
  final String Function(BatteryConnection c) _value;

  DetailRow._(this.label, this.tooltip, this.metrics, this._value);

  /// The row's value text: "—" when none of its metrics is known.
  String value(BatteryConnection c) => _value(c);
}

/// A one-line group of same-unit metrics (#107): the parts, in display
/// order, joined " / " with the [unit] once at the end. Each part's number is
/// its catalogue row's own [MetricDef.extract] (the value that is logged).
class _DetailGroup {
  final String label;
  final String tooltip;
  final String unit;

  /// (metric key, decimals) per part, in display order.
  final List<(String, int)> parts;
  const _DetailGroup(this.label, this.tooltip, this.unit, this.parts);

  bool has(String key) => parts.any((p) => p.$1 == key);

  /// "3.305 / 3.320 / 0.015 V"; an unknown part is "—"; none known → "—".
  String value(List<MetricDef> metrics, BatteryConnection c) {
    final vs = [for (final m in metrics) m.extract!(c)];
    if (vs.every((v) => v == null)) return '—';
    final texts = [
      for (var i = 0; i < vs.length; i++)
        vs[i]?.toStringAsFixed(parts[i].$2) ?? '—',
    ];
    return '${texts.join(' / ')} $unit';
  }
}

/// #107: the Cells section's aggregates, two rows instead of five. Cell-level
/// figures read to the mV (three decimals, like the per-cell list above
/// them); the pack-level sum keeps two.
const List<_DetailGroup> _detailGroups = [
  _DetailGroup(
    'Sum / Average',
    'Sum of the cell voltages / average cell voltage',
    'V',
    [(Metric.cellSum, 2), (Metric.cellAvg, 3)],
  ),
  _DetailGroup(
    'Min / Max / Delta',
    'Lowest cell / highest cell / spread between them',
    'V',
    [(Metric.cellMin, 3), (Metric.cellMax, 3), (Metric.cellDelta, 3)],
  ),
];

/// The detail-page rows for [section], as rendered: [detailMetrics] in table
/// order, except that each #107 group's metrics collapse into ONE row at the
/// position of the group's first metric in the table.
List<DetailRow> detailRows(DetailSection section) {
  final metrics = detailMetrics(section);
  final rows = <DetailRow>[];
  final done = <_DetailGroup>{};
  for (final m in metrics) {
    final g = _detailGroups.where((g) => g.has(m.key)).firstOrNull;
    if (g == null) {
      rows.add(DetailRow._(m.labelOnDetail, m.tooltip, [m], m.detailValue));
    } else if (done.add(g)) {
      final parts = [
        for (final p in g.parts) metrics.firstWhere((x) => x.key == p.$1),
      ];
      rows.add(DetailRow._(
          g.label, g.tooltip, parts, (c) => g.value(parts, c)));
    }
  }
  return rows;
}

/// Metrics to load for the charts page: the pack's cells (however many were
/// ever logged, M14; a minimum of four so a pack with no history yet still
/// shows the familiar card) followed by every charted table row and the packed
/// `flags` (charge-state band + fault timeline). Pure.
List<String> chartMetrics(List<String> cells) => [
      ...(cells.isEmpty ? Metric.cells : cells),
      for (final m in metricTable)
        if (m.chartGroup != null) m.key,
      Metric.flags,
      Metric.sampleIntervalS, // #53: which gaps are expected sampling gaps
    ];
