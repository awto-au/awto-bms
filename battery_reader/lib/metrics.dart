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
  static const temp0 = 'temp0'; // deg C (byte[0]) — second probe pair
  static const temp1 = 'temp1'; // deg C (byte[1])
  static const temp2 = 'temp2'; // deg C (byte[3])
  static const temp3 = 'temp3'; // deg C (byte[2]) — second probe pair
  static const chipTemp = 'chip'; // deg C
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

// Chart colours (issue #22 / #32 palette).
const _probe1 = Color(0xFFF2994A);
const _probe2 = Color(0xFFEB5757);
const _probe3 = Color(0xFFF2C94C);
const _probe4 = Color(0xFFBB6BD9);
const _chip = Color(0xFF56CCF2);

String _intOrDash(int? v) => v?.toString() ?? '—';

/// THE metric table, in detail-page order (section by section). The logger
/// writes every `logged` row in this order; the charts draw each [ChartGroup]'s
/// rows in this order; the sparklines are ordered by [MetricDef.spark].
final List<MetricDef> metricTable = <MetricDef>[
  // --- Pack ----------------------------------------------------------------
  MetricDef(
    key: Metric.soc,
    label: 'State of charge',
    unit: '%',
    extract: (c) => c.state.socPercent,
    format: (c) => fPct(c.state.socPercent),
    color: HealthPalette.healthy,
    socGraded: true,
    chartGroup: ChartGroup.soc,
    chartLabel: 'SOC',
    detailSection: DetailSection.pack,
    spark: 4,
  ),
  MetricDef(
    key: Metric.packVoltage,
    label: 'Pack voltage',
    unit: 'V',
    extract: (c) => c.state.packVoltage,
    format: (c) => fV(c.state.packVoltage),
    color: HealthPalette.telemetryAccent,
    chartGroup: ChartGroup.packVoltage,
    chartLabel: 'Pack',
    detailSection: DetailSection.pack,
    spark: 2,
  ),
  MetricDef(
    key: Metric.packCurrent,
    label: 'Current',
    unit: 'A',
    // Logged SIGNED (+in / −out); the detail row shows the BMS magnitude.
    extract: (c) => c.signedCurrent,
    format: (c) => fSignedA(c.signedCurrent),
    color: HealthPalette.healthy,
    sparkColor: HealthPalette.telemetryAccent,
    centreZero: true,
    chartGroup: ChartGroup.current,
    detailSection: DetailSection.pack,
    detailLabel: 'Pack current',
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
    key: Metric.displayChargeState,
    label: 'Charge state',
    unit: '',
    format: (c) => ChargeStateStyle.of(c.state.chargeState).shortLabel,
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.displayLoad,
    label: 'Load connected',
    unit: '',
    format: (c) => fBool(c.state.loadConnected),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.displayCharger,
    label: 'Charger connected',
    unit: '',
    format: (c) => fBool(c.state.chargerConnected),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.cycleCount,
    label: 'Cycles (BMS raw)',
    unit: '',
    extract: (c) => c.state.cycleCount,
    format: (c) => _intOrDash(c.state.cycleCount),
    color: HealthPalette.idle,
    detailSection: DetailSection.pack,
  ),
  MetricDef(
    key: Metric.efc,
    label: 'Equivalent full cycles',
    unit: '',
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
  // --- Temperature (probe order: temp1, temp2 primary; temp0, temp3 second) -
  MetricDef(
    key: Metric.temp1,
    label: 'Probe 1',
    unit: '°C',
    extract: (c) => c.state.temp1,
    format: (c) => fmtTemp(c.state.temp1),
    color: _probe1,
    chartGroup: ChartGroup.temperature,
    detailSection: DetailSection.temperature,
    detailLabel: 'Probe 1 (primary)',
    spark: 6,
  ),
  MetricDef(
    key: Metric.temp2,
    label: 'Probe 2',
    unit: '°C',
    extract: (c) => c.state.temp2,
    format: (c) => fmtTemp(c.state.temp2),
    color: _probe2,
    chartGroup: ChartGroup.temperature,
    detailSection: DetailSection.temperature,
    detailLabel: 'Probe 2 (primary)',
    spark: 7,
  ),
  MetricDef(
    key: Metric.temp0,
    label: 'Probe 3',
    unit: '°C',
    extract: (c) => c.state.temp0,
    format: (c) => fmtTemp(c.state.temp0),
    color: _probe3,
    chartGroup: ChartGroup.temperature,
    detailSection: DetailSection.temperature,
    detailLabel: 'Probe 3 (second pair)',
    spark: 8,
  ),
  MetricDef(
    key: Metric.temp3,
    label: 'Probe 4',
    unit: '°C',
    extract: (c) => c.state.temp3,
    format: (c) => fmtTemp(c.state.temp3),
    color: _probe4,
    chartGroup: ChartGroup.temperature,
    detailSection: DetailSection.temperature,
    detailLabel: 'Probe 4 (second pair)',
    spark: 9,
  ),
  MetricDef(
    key: Metric.chipTemp,
    label: 'Chip',
    unit: '°C',
    extract: (c) => c.state.chipTemperature,
    // Unpopulated by this firmware (always 0): "not reported", never 0 °C.
    format: (c) => fChipTemp(c.state.chipTemperature),
    color: _chip,
    chartGroup: ChartGroup.temperature,
    detailSection: DetailSection.temperature,
  ),
  // --- Gates & status ------------------------------------------------------
  MetricDef(
    key: Metric.displayMos,
    label: 'MOS',
    unit: '',
    format: (c) => fBool(c.state.mosOn),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayChgMos,
    label: 'Charge MOS',
    unit: '',
    format: (c) => fBool(c.state.chargeMos),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayDisMos,
    label: 'Discharge MOS',
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
    format: (c) => _intOrDash(c.state.tempControlGate),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.smokeGate,
    label: 'Smoke sensor',
    unit: '',
    extract: (c) => c.state.smokeGate,
    format: (c) => _intOrDash(c.state.smokeGate),
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
    label: 'Signal (RSSI)',
    unit: 'dBm',
    extract: (c) => c.state.rssi,
    format: (c) => fRssi(c.state.rssi),
    color: HealthPalette.idle,
    detailSection: DetailSection.gates,
  ),
  MetricDef(
    key: Metric.displayUnrecognised,
    label: 'Unrecognised bytes',
    unit: '',
    // Issue #20: stray bytes dropped on resync (each is also written to the
    // raw log as an UNRECOGNISED line). 0 on healthy hardware.
    format: (c) => '${c.state.unrecognisedBytes}',
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

/// Metrics to load for the charts page: the pack's cells (however many were
/// ever logged, M14; a minimum of four so a pack with no history yet still
/// shows the familiar card) followed by every charted table row and the packed
/// `flags` (charge-state band + fault timeline). Pure.
List<String> chartMetrics(List<String> cells) => [
      ...(cells.isEmpty ? Metric.cells : cells),
      for (final m in metricTable)
        if (m.chartGroup != null) m.key,
      Metric.flags,
    ];
