/// History / charts screen for one battery, backed by the append-only interval
/// store ([BatteryLogger]). It reads the in-memory hour for the live/high-res
/// tail and the DB for older data. Every metric is drawn as HELD segments from
/// `start_ms` to `end_ms` (step/hold interpolation); where consecutive rows do
/// not abut, the gap is shaded as an OFFLINE window rather than bridged by a
/// line. All data is read-only; nothing here touches BLE.
///
/// Review pass C2: which metrics are loaded and drawn, on which card, in which
/// colour, comes from the metric catalogue (metrics.dart); the run / gap /
/// splice / axis / window logic is the shared intervals.dart.
library;

import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'battery_log.dart';
import 'battery_protocol.dart' show ChargeState;
import 'diagnostics.dart';
import 'fmt.dart';
import 'health_palette.dart';
import 'intervals.dart';
import 'metrics.dart';
import 'temp_unit.dart';
import 'widgets.dart';

const _green = HealthPalette.healthy;
const _red = HealthPalette.faultRed;
const _grid = Color(0xFF2A333F);

/// A gap between abutting intervals wider than this is treated as offline.
const int _gapMs = BatteryLogger.gapMs;

class BatteryChartsPage extends StatefulWidget {
  final String serial;
  const BatteryChartsPage({super.key, required this.serial});

  @override
  State<BatteryChartsPage> createState() => _BatteryChartsPageState();
}

/// Legend colours for the per-cell series (M14): cycled for packs with more
/// cells than colours, so N cells always draw.
const cellPalette = <Color>[
  Color(0xFF4C9AFF),
  Color(0xFF2FBF71),
  Color(0xFFF2C94C),
  Color(0xFFBB6BD9),
  Color(0xFFF2994A),
  Color(0xFF56CCF2),
  Color(0xFFEB5757),
  Color(0xFF9B51E0),
];

/// Colour for the 0-based cell [index] (cycles through [cellPalette]).
Color cellColor(int index) => cellPalette[index % cellPalette.length];

/// Two interval lists with the same content (element identity or the same
/// span + value). Cheap: the DB body's elements are the same objects tick
/// after tick, so this is a run of pointer compares plus the live tail.
bool sameIntervals(List<ReadingInterval> a, List<ReadingInterval> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (identical(x, y)) continue;
    if (x.startMs != y.startMs ||
        x.endMs != y.endMs ||
        x.valueNum != y.valueNum ||
        x.valueText != y.valueText) {
      return false;
    }
  }
  return true;
}

class _BatteryChartsPageState extends State<BatteryChartsPage> {
  /// The cell metrics found for this serial (M14), refreshed on each [_load].
  List<String> _cells = const [];

  /// The metrics currently loaded/spliced — [chartMetrics] of [_cells].
  List<String> _metrics = chartMetrics(const []);

  LookbackWindow _window = LookbackWindow.h1;
  bool _loading = true;

  /// M6: why the last [_load] failed (a DB error), or null. Shown instead of
  /// an endless spinner; the Refresh button retries.
  String? _error;

  /// Displayed series = [_dbBody] with the live in-memory tail spliced on.
  Map<String, List<ReadingInterval>> _series = const {};

  /// H4: the durable DB rows for the window, loaded once per [_load] and kept
  /// INTACT — the live tick only re-splices the in-memory hour onto them, so
  /// history from a previous session (which the in-memory buffer never held)
  /// is never dropped after the first tick.
  Map<String, List<ReadingInterval>> _dbBody = const {};
  List<({String label, int startMs, int endMs})> _faults = const [];
  int _fromMs = 0;
  int _toMs = 0;
  int _lastLoadMs = 0;

  /// Re-read the DB body this often while the page stays open, so rows that
  /// the logger flushed since the last load (a grown open interval, new
  /// change rows) are picked up before the rolling hour buffer forgets them.
  static const _reloadEveryMs = 5 * 60 * 1000;

  Timer? _live;

  @override
  void initState() {
    super.initState();
    _load();
    // Graphing mode: refresh live from the in-memory buffer once per second.
    _live = Timer.periodic(const Duration(seconds: 1), (_) => _tickLive());
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  /// Load the DB body for the window. M6: any DB error is caught and shown as
  /// an error state; `_loading` is ALWAYS reset in `finally`, so a failed load
  /// can never leave the spinner up for good.
  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastLoadMs = now;
    final span = _window.spanMs;
    final since = span == null ? 0 : now - span;
    final log = BatteryLogger.instance;
    try {
      // M14: discover how many cells this pack has logged, then load them all.
      final cells = await log.cellMetrics(widget.serial);
      final metrics = chartMetrics(cells);
      // H4: keep the raw DB body separately; the displayed series is the body
      // with the live tail spliced on (the same splice mergedSeries uses).
      final body =
          await log.multiIntervals(widget.serial, metrics, sinceMs: since);
      final series = <String, List<ReadingInterval>>{
        for (final m in metrics)
          m: spliceTail(body[m] ?? const [],
              log.hourSegments(widget.serial, m),
              sinceMs: since),
      };
      final faults = await log.activeFaults(widget.serial, sinceMs: since);
      final range = computeRange(series.values, span, now);

      if (!mounted) return;
      setState(() {
        _cells = cells.isEmpty ? Metric.cells : cells;
        _metrics = metrics;
        _dbBody = body;
        _series = series;
        _faults = faults;
        _fromMs = range.fromMs;
        _toMs = range.toMs;
        _error = null;
      });
    } catch (e) {
      AppLog.instance
          .record('Charts', 'history load for ${widget.serial} failed: $e');
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  /// Cheap live refresh: re-read only the in-memory hour and splice its tail
  /// onto the UNCHANGED DB body ([_dbBody]) with the shared [spliceTail],
  /// then advance the right edge to now. H4: every DB row is kept — the buffer
  /// only holds THIS session's readings, so replacing the last hour of DB rows
  /// with it (as before) made the previous session's last hour vanish 1 s
  /// after load. L8: a series whose spliced content is unchanged keeps its
  /// previous list (same identity), so the chart card reuses its built runs;
  /// when nothing changed and the window edge need not move, no rebuild at all.
  void _tickLive() {
    if (_loading || !mounted) return;
    final log = BatteryLogger.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLoadMs > _reloadEveryMs) {
      _load(quiet: true); // async; ticks keep splicing onto the old body
      return;
    }
    final span = _window.spanMs;
    final since = span == null ? 0 : now - span;
    final next = <String, List<ReadingInterval>>{};
    var changed = false;
    for (final m in _metrics) {
      final spliced = spliceTail(
        _dbBody[m] ?? const [],
        log.hourSegments(widget.serial, m),
        sinceMs: since,
      );
      final prev = _series[m];
      if (prev != null && sameIntervals(prev, spliced)) {
        next[m] = prev;
      } else {
        next[m] = spliced;
        changed = true;
      }
    }
    final edgeMoves = span != null || now > _toMs;
    if (!changed && !edgeMoves) return;
    setState(() {
      _series = next;
      if (span != null) {
        _toMs = now;
        _fromMs = now - span;
      } else if (now > _toMs) {
        _toMs = now;
      }
    });
  }

  bool get _hasAnyData => _series.values.any((l) => l.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.serial} · history'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: PageShell(
        maxWidth: 720,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: SegmentedButton<LookbackWindow>(
                segments: [
                  for (final w in LookbackWindow.chartWindows)
                    ButtonSegment(value: w, label: Text(w.label)),
                ],
                selected: {_window},
                onSelectionChanged: (s) {
                  setState(() => _window = s.first);
                  _load();
                },
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _ErrorState(reason: _error!, onRetry: _load)
                      : !_hasAnyData
                          ? const _EmptyState()
                          : ListView(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 4, 12, 32),
                              children: _charts(),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  /// Chip temp is byte[7] of the Battery-data frame, unpopulated by this
  /// firmware (always 0). If every logged sample in the window is 0 we treat it
  /// as "not reported": draw no (misleading, flat-zero) line and mark the legend.
  bool get _chipUnreported {
    final ivs = _series[Metric.chipTemp] ?? const [];
    return ivs.isNotEmpty && ivs.every((iv) => (iv.valueNum ?? 0) == 0);
  }

  /// The card title / unit / fixed axis for each [ChartGroup].
  ({String title, String unit, double? minY, double? maxY}) _spec(
          ChartGroup g) =>
      switch (g) {
        ChartGroup.cells => (title: 'Cell voltages', unit: 'V', minY: null, maxY: null),
        ChartGroup.packVoltage => (title: 'Pack voltage', unit: 'V', minY: null, maxY: null),
        ChartGroup.current => (title: 'Current (+ in / − out)', unit: 'A', minY: null, maxY: null),
        // #43: axis, unit label and values follow the chosen unit. The logged
        // samples stay in °C; only the plotted/axis values are converted.
        ChartGroup.temperature => (title: 'Temperatures', unit: tempUnitLabel, minY: null, maxY: null),
        ChartGroup.soc => (title: 'State of charge', unit: '%', minY: 0, maxY: 100),
      };

  Widget _card(ChartGroup g) {
    final spec = _spec(g);
    final defs = chartSeries(g);
    final List<Series> series;
    if (g == ChartGroup.cells) {
      // M14: one series per logged cell, however many the pack has.
      series = [
        for (var i = 0; i < _cells.length; i++)
          Series('Cell ${Metric.cellIndex(_cells[i]) ?? i + 1}', cellColor(i),
              _series[_cells[i]] ?? const []),
      ];
    } else {
      final chipUnreported = _chipUnreported;
      series = [
        for (final m in defs)
          m.key == Metric.chipTemp && chipUnreported
              ? Series('${m.labelOnChart} — not reported', m.color, const [])
              : Series(m.labelOnChart, m.color, _series[m.key] ?? const []),
      ];
    }
    return _ChartCard(
      title: spec.title,
      unit: spec.unit,
      fromMs: _fromMs,
      toMs: _toMs,
      minY: spec.minY,
      maxY: spec.maxY,
      centreZero: defs.any((m) => m.centreZero),
      valueTransform: g == ChartGroup.temperature && gUseFahrenheit
          ? celsiusToFahrenheit
          : null,
      series: series,
    );
  }

  List<Widget> _charts() => [
        for (final g in ChartGroup.values) _card(g),
        _ChargeStateBandCard(
          fromMs: _fromMs,
          toMs: _toMs,
          flags: _series[Metric.flags] ?? const [],
        ),
        _FaultTimelineCard(
          fromMs: _fromMs,
          toMs: _toMs,
          flags: _series[Metric.flags] ?? const [],
          faults: _faults,
        ),
      ];
}

/// One named series: a metric's held intervals.
class Series {
  final String label;
  final Color color;
  final List<ReadingInterval> intervals;
  const Series(this.label, this.color, this.intervals);
}

/// L8: the bars built from one series' intervals, cached against the interval
/// list's IDENTITY (and the value transform) so an unchanged series is not
/// rebuilt on every 1 s tick.
class _BuiltSeries {
  final List<ReadingInterval> intervals;
  final Color color;
  final double Function(double)? transform;
  final List<LineChartBarData> bars;
  final List<LineChartBarData> dashed;
  final double lo;
  final double hi;
  const _BuiltSeries({
    required this.intervals,
    required this.color,
    required this.transform,
    required this.bars,
    required this.dashed,
    required this.lo,
    required this.hi,
  });

  bool matches(Series s, double Function(double)? transform) =>
      identical(intervals, s.intervals) &&
      color == s.color &&
      identical(this.transform, transform);

  /// Split the series into runs of abutting intervals; each run is one bar of
  /// held (step) points. Each offline gap between runs is BRIDGED by a straight
  /// DASHED line in the same colour (#33) — solid = real logged data, dashed =
  /// missing/offline.
  static _BuiltSeries build(Series s, double Function(double)? transform) {
    final bars = <LineChartBarData>[];
    final dashed = <LineChartBarData>[];
    var lo = double.infinity, hi = -double.infinity;
    FlSpot? prevEnd;
    for (final run in splitRuns(s.intervals, gapMs: _gapMs)) {
      final spots = <FlSpot>[];
      for (final iv in run) {
        final raw = iv.valueNum;
        if (raw == null) continue;
        final v = transform == null ? raw : transform(raw);
        spots.add(FlSpot(iv.startMs.toDouble(), v));
        spots.add(FlSpot(iv.endMs.toDouble(), v));
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      if (spots.isEmpty) continue;
      // Dashed straight bridge across the missing period to this run.
      if (prevEnd != null) {
        dashed.add(LineChartBarData(
          spots: [prevEnd, spots.first],
          isCurved: false,
          color: s.color.withValues(alpha: 0.85),
          barWidth: 1.5,
          dashArray: const [4, 4],
          dotData: const FlDotData(show: false),
        ));
      }
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        color: s.color,
        barWidth: 2,
        dotData: const FlDotData(show: false),
      ));
      prevEnd = spots.last;
    }
    return _BuiltSeries(
      intervals: s.intervals,
      color: s.color,
      transform: transform,
      bars: bars,
      dashed: dashed,
      lo: lo,
      hi: hi,
    );
  }
}

class _ChartCard extends StatefulWidget {
  final String title;
  final String unit;
  final int fromMs;
  final int toMs;
  final List<Series> series;
  final double? minY;
  final double? maxY;
  final bool centreZero;

  /// #43: optional per-value transform applied to the plotted Y (and thus the
  /// axis). Used to render temperatures in °F while the logged samples stay °C.
  final double Function(double)? valueTransform;

  const _ChartCard({
    required this.title,
    required this.unit,
    required this.fromMs,
    required this.toMs,
    required this.series,
    this.valueTransform,
    this.minY,
    this.maxY,
    this.centreZero = false,
  });

  @override
  State<_ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<_ChartCard> {
  /// L8: per-series built bars, keyed by position; rebuilt only for a series
  /// whose interval list (or transform) changed since the last build.
  final Map<int, _BuiltSeries> _built = {};

  List<_BuiltSeries> _buildAll() {
    final out = <_BuiltSeries>[];
    for (var i = 0; i < widget.series.length; i++) {
      final s = widget.series[i];
      final cached = _built[i];
      final b = cached != null && cached.matches(s, widget.valueTransform)
          ? cached
          : _BuiltSeries.build(s, widget.valueTransform);
      _built[i] = b;
      out.add(b);
    }
    _built.removeWhere((i, _) => i >= widget.series.length);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final hasData = widget.series.any((s) => s.intervals.isNotEmpty);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text(widget.unit,
                    style: const TextStyle(color: Colors.white54)),
              ],
            ),
            if (widget.series.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    for (final s in widget.series)
                      LegendSwatch(s.color, s.label),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              height: 180,
              child: hasData
                  ? LineChart(_data(_buildAll()))
                  : const Center(
                      child: Text('No samples in this window',
                          style: TextStyle(color: Colors.white38))),
            ),
          ],
        ),
      ),
    );
  }

  LineChartData _data(List<_BuiltSeries> built) {
    // Solid (real, held) bars and dashed (missing/offline bridge) bars are kept
    // separate so the dashed connectors draw UNDER the solid line (#33).
    final bars = <LineChartBarData>[];
    final dashed = <LineChartBarData>[];
    var lo = double.infinity, hi = -double.infinity;
    for (final b in built) {
      bars.addAll(b.bars);
      dashed.addAll(b.dashed);
      if (b.lo < lo) lo = b.lo;
      if (b.hi > hi) hi = b.hi;
    }

    // Y bounds (#32): the axis always includes 0 — 0..max for level metrics,
    // symmetric −max..+max about 0 for signed ones (centreZero).
    final (yMin, yMax) = yBounds(lo, hi,
        minY: widget.minY, maxY: widget.maxY, centreZero: widget.centreZero);

    final fromMs = widget.fromMs, toMs = widget.toMs;
    final spanMs = (toMs - fromMs).toDouble().clamp(1.0, double.infinity);
    return LineChartData(
      minX: fromMs.toDouble(),
      maxX: toMs.toDouble(),
      minY: yMin,
      maxY: yMax,
      clipData: const FlClipData.all(),
      // Dashed bridges first, solid held lines on top (#33).
      lineBarsData: [...dashed, ...bars],
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) =>
            const FlLine(color: _grid, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 42,
            getTitlesWidget: (v, _) => Text(
              fmtAxis(v),
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: spanMs / 4,
            getTitlesWidget: (v, meta) {
              if (v <= fromMs.toDouble() + 1 || v >= toMs.toDouble() - 1) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(fmtTick(v.toInt(), spanMs),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 10)),
              );
            },
          ),
        ),
      ),
      lineTouchData: const LineTouchData(enabled: false),
    );
  }
}

/// Offline windows: stretches of [from,to] not covered by ANY of [ivs], i.e.
/// the battery was disconnected. Returned as (start,end) pairs to shade.
List<(int, int)> _offlineGaps(List<ReadingInterval> ivs, int from, int to) =>
    uncoveredGaps(ivs, from, to, gapMs: _gapMs);

// ---------------------------------------------------------------------------
// Charge-state / load band (issue #22). A LINEAR horizontal band along the
// time axis showing, over the same window as the charts, when the pack was
// IDLE (no load) vs CHARGING vs DISCHARGING, plus whether a load/charger was
// connected. State is derived from the packed `flags` metric (chargeState in
// bits 10-11; load/charger are single bits) read from the same interval store
// as every other metric. Non-abutting flags rows leave the band uncovered
// (offline) — gaps are never bridged. Not circular: band/segments only.
// ---------------------------------------------------------------------------

/// One held segment of the band: a state that ran from [startMs] to [endMs],
/// with whether a load and/or a charger were connected during it. The state
/// is [ChargeState.idle] / `charging` / `discharging` (never `unknown`: a
/// flags chargeState code of 0 or any unknown code reads as idle — no flow).
class ChargeSegment implements TimeSpan {
  @override
  final int startMs;
  @override
  final int endMs;
  final ChargeState state;
  final bool loadConnected;
  final bool chargerConnected;
  const ChargeSegment({
    required this.startMs,
    required this.endMs,
    required this.state,
    required this.loadConnected,
    required this.chargerConnected,
  });

  ChargeSegment _extendedTo(int end) => ChargeSegment(
        startMs: startMs,
        endMs: end,
        state: state,
        loadConnected: loadConnected,
        chargerConnected: chargerConnected,
      );

  @override
  bool operator ==(Object other) =>
      other is ChargeSegment &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.state == state &&
      other.loadConnected == loadConnected &&
      other.chargerConnected == chargerConnected;

  @override
  int get hashCode =>
      Object.hash(startMs, endMs, state, loadConnected, chargerConnected);
}

/// Map a packed `flags` value to its charge state (bits 10-11).
ChargeState chargeStateOf(int flags) => switch (Flags.chargeState(flags)) {
      1 => ChargeState.charging,
      2 => ChargeState.discharging,
      _ => ChargeState.idle, // 0 idle, or any unknown code
    };

/// Fold held `flags` intervals into charge-state/load segments over time.
///
/// Pure and unit-testable (no Flutter/DB). Consecutive rows that abut (gap
/// ≤ [gapMs], the shared [abuts] rule) AND share the same derived state +
/// load/charger bits are merged into one segment; a value change or a gap
/// wider than [gapMs] starts a new segment, so an offline stretch is left as a
/// gap between segments rather than bridged. Input must be in non-decreasing
/// time order.
List<ChargeSegment> buildChargeSegments(
  List<ReadingInterval> flags, {
  int gapMs = _gapMs,
}) {
  final out = <ChargeSegment>[];
  for (final iv in flags) {
    final f = (iv.valueNum ?? 0).toInt();
    final st = chargeStateOf(f);
    final load = (f & Flags.load) != 0;
    final charger = (f & Flags.charger) != 0;
    final canExtend = out.isNotEmpty &&
        out.last.state == st &&
        out.last.loadConnected == load &&
        out.last.chargerConnected == charger &&
        abuts(out.last.endMs, iv.startMs, gapMs);
    if (canExtend) {
      out[out.length - 1] = out.last._extendedTo(iv.endMs);
    } else {
      out.add(ChargeSegment(
        startMs: iv.startMs,
        endMs: iv.endMs,
        state: st,
        loadConnected: load,
        chargerConnected: charger,
      ));
    }
  }
  return out;
}

/// Semantic colour per charge state (issue #22): idle = neutral grey,
/// charging = health green, discharging = amber — the shared
/// [ChargeStateStyle.bandColor].
Color _bandColor(ChargeState s) => ChargeStateStyle.of(s).bandColor;

/// The charge-state / load band card: a linear time-axis band (never circular).
class _ChargeStateBandCard extends StatelessWidget {
  final int fromMs;
  final int toMs;
  final List<ReadingInterval> flags;

  const _ChargeStateBandCard({
    required this.fromMs,
    required this.toMs,
    required this.flags,
  });

  @override
  Widget build(BuildContext context) {
    final segments = buildChargeSegments(flags);
    // Offline = window not covered by any flags row; leave it as a gap (grey).
    final offline = _offlineGaps(flags, fromMs, toMs);
    final anyLoad = segments.any((s) => s.loadConnected || s.chargerConnected);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_vert, size: 18, color: Colors.white70),
                const SizedBox(width: 6),
                Text('Charge state / load',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  LegendSwatch(_bandColor(ChargeState.idle), 'Idle · no load',
                      round: false),
                  LegendSwatch(_bandColor(ChargeState.charging), 'Charging',
                      round: false),
                  LegendSwatch(
                      _bandColor(ChargeState.discharging), 'Discharging',
                      round: false),
                  const LegendSwatch(
                      HealthPalette.telemetryAccent, 'Load connected',
                      round: false),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 30,
              child: flags.isEmpty
                  ? const Center(
                      child: Text('No charge-state history in this window',
                          style: TextStyle(color: Colors.white38)))
                  : CustomPaint(
                      size: Size.infinite,
                      painter: _ChargeBandPainter(
                        fromMs: fromMs,
                        toMs: toMs,
                        segments: segments,
                        offline: offline,
                      ),
                    ),
            ),
            if (flags.isNotEmpty && !anyLoad)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No load or charger connected in this window.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChargeBandPainter extends CustomPainter {
  final int fromMs;
  final int toMs;
  final List<ChargeSegment> segments;
  final List<(int, int)> offline;

  _ChargeBandPainter({
    required this.fromMs,
    required this.toMs,
    required this.segments,
    required this.offline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final span = (toMs - fromMs).toDouble();
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF1E2731));
    if (span <= 0) return;

    canvas.save();
    canvas.clipRRect(rrect);

    double x(int ms) =>
        ((ms - fromMs) / span * size.width).clamp(0.0, size.width);

    // Charge-state fills across the FULL height, split into runs (state colour).
    for (final seg in segments) {
      final x0 = x(seg.startMs);
      final x1 = x(seg.endMs);
      final w = (x1 - x0).clamp(1.0, size.width);
      canvas.drawRect(
        Rect.fromLTWH(x0, 0, w.toDouble(), size.height),
        Paint()..color = _bandColor(seg.state),
      );
    }

    // Load/charger connected: a thin strip along the BOTTOM of each segment
    // where a load or charger was attached (linear sub-band, not circular).
    const stripH = 6.0;
    for (final seg in segments) {
      if (!seg.loadConnected && !seg.chargerConnected) continue;
      final x0 = x(seg.startMs);
      final x1 = x(seg.endMs);
      final w = (x1 - x0).clamp(1.0, size.width);
      canvas.drawRect(
        Rect.fromLTWH(x0, size.height - stripH, w.toDouble(), stripH),
        Paint()..color = HealthPalette.telemetryAccent,
      );
    }

    // Offline windows (no flags coverage) shaded grey, left UNBRIDGED.
    for (final (s, e) in offline) {
      final x0 = x(s);
      final x1 = x(e);
      canvas.drawRect(
        Rect.fromLTWH(x0, 0, (x1 - x0).toDouble(), size.height),
        Paint()..color = const Color(0x552A333F),
      );
    }
    canvas.restore();
  }

  // L8: compare the (small) segment / gap lists by VALUE — they are rebuilt
  // every tick, so identity would always repaint.
  @override
  bool shouldRepaint(_ChargeBandPainter old) =>
      old.fromMs != fromMs ||
      old.toMs != toMs ||
      !listEquals(old.segments, segments) ||
      !listEquals(old.offline, offline);
}

/// A fault/alarm timeline: held bands where any alarm was active, grey where
/// the battery was offline (no coverage), plus a list of the active windows.
class _FaultTimelineCard extends StatelessWidget {
  final int fromMs;
  final int toMs;
  final List<ReadingInterval> flags;
  final List<({String label, int startMs, int endMs})> faults;

  const _FaultTimelineCard({
    required this.fromMs,
    required this.toMs,
    required this.flags,
    required this.faults,
  });

  @override
  Widget build(BuildContext context) {
    // Active bands = held `flags` intervals whose fault-category bits are set.
    final active = <(int, int)>[
      for (final iv in flags)
        if (Flags.faultActive((iv.valueNum ?? 0).toInt()))
          (iv.startMs, iv.endMs),
    ];
    // Offline bands = complement of coverage within the window.
    final offline = _offlineGaps(flags, fromMs, toMs);
    final everActive = active.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber,
                    size: 18, color: everActive ? _red : Colors.white38),
                const SizedBox(width: 6),
                Text('Fault / alarm timeline',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 26,
              child: flags.isEmpty
                  ? const Center(
                      child: Text('No fault history in this window',
                          style: TextStyle(color: Colors.white38)))
                  : CustomPaint(
                      size: Size.infinite,
                      painter: _TimelinePainter(
                        fromMs: fromMs,
                        toMs: toMs,
                        active: active,
                        offline: offline,
                      ),
                    ),
            ),
            if (!everActive && flags.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No alarms active in this window — all clear.',
                    style: TextStyle(color: _green, fontSize: 12)),
              ),
            for (final f in faults)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${fmtTick(f.startMs, (toMs - fromMs).toDouble())}  '
                  '${f.label}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  final int fromMs;
  final int toMs;
  final List<(int, int)> active;
  final List<(int, int)> offline;

  _TimelinePainter({
    required this.fromMs,
    required this.toMs,
    required this.active,
    required this.offline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final span = (toMs - fromMs).toDouble();
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF1E2731));
    if (span <= 0) return;

    canvas.save();
    canvas.clipRRect(rrect);

    void band(int start, int end, Color color, {double minW = 0}) {
      final x0 = ((start - fromMs) / span * size.width).clamp(0, size.width);
      final x1 = ((end - fromMs) / span * size.width).clamp(0, size.width);
      final w = (x1 - x0).clamp(minW, size.width);
      canvas.drawRect(
          Rect.fromLTWH(x0.toDouble(), 0, w.toDouble(), size.height),
          Paint()..color = color);
    }

    // Offline first (grey), then active alarms (red) on top.
    for (final (s, e) in offline) {
      band(s, e, const Color(0x552A333F));
    }
    for (final (s, e) in active) {
      band(s, e, _red, minW: 2);
    }
    canvas.restore();
  }

  // L8: value comparison (records compare structurally), not list identity.
  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.fromMs != fromMs ||
      old.toMs != toMs ||
      !listEquals(old.active, active) ||
      !listEquals(old.offline, offline);
}

/// M6: shown when the history query itself failed (DB error), with a retry.
class _ErrorState extends StatelessWidget {
  final String reason;
  final VoidCallback onRetry;
  const _ErrorState({required this.reason, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: _red),
            const SizedBox(height: 12),
            const Text("Couldn't load history",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(reason,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.show_chart, size: 48, color: Colors.white24),
            SizedBox(height: 12),
            Text('No history yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              'Telemetry is recorded once this battery is connected. '
              'Leave it running and charts will fill in.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
