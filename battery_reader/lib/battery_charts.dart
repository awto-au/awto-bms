/// History / charts screen for one battery, backed by the append-only interval
/// store ([BatteryLogger]). It reads the in-memory hour for the live/high-res
/// tail and the DB for older data. Every metric is drawn as HELD segments from
/// `start_ms` to `end_ms` (step/hold interpolation); where consecutive rows do
/// not abut, the gap is shaded as an OFFLINE window rather than bridged by a
/// line. All data is read-only; nothing here touches BLE.
library;

import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'battery_log.dart';

const _green = Color(0xFF2FBF71);
const _red = Color(0xFFE5484D);
const _grid = Color(0xFF2A333F);
const _offline = Color(0x33FF6B6B); // translucent red = known-offline gap

/// A gap between abutting intervals wider than this is treated as offline.
const int _gapMs = BatteryLogger.gapMs;

/// Selectable look-back windows.
enum TimeWindow { h1, h6, h24, all }

extension _Win on TimeWindow {
  String get label => switch (this) {
        TimeWindow.h1 => '1h',
        TimeWindow.h6 => '6h',
        TimeWindow.h24 => '24h',
        TimeWindow.all => 'All',
      };

  /// Milliseconds of look-back, or null for "all".
  int? get spanMs => switch (this) {
        TimeWindow.h1 => 3600 * 1000,
        TimeWindow.h6 => 6 * 3600 * 1000,
        TimeWindow.h24 => 24 * 3600 * 1000,
        TimeWindow.all => null,
      };
}

class BatteryChartsPage extends StatefulWidget {
  final String serial;
  const BatteryChartsPage({super.key, required this.serial});

  @override
  State<BatteryChartsPage> createState() => _BatteryChartsPageState();
}

class _BatteryChartsPageState extends State<BatteryChartsPage> {
  static const _metrics = <String>[
    Metric.cell1, Metric.cell2, Metric.cell3, Metric.cell4,
    Metric.packVoltage, Metric.packCurrent,
    Metric.temp1, Metric.temp2, Metric.chipTemp,
    Metric.soc, Metric.flags,
  ];

  TimeWindow _window = TimeWindow.h1;
  bool _loading = true;

  Map<String, List<ReadingInterval>> _series = const {};
  List<({String label, int startMs, int endMs})> _faults = const [];
  int _fromMs = 0;
  int _toMs = 0;

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

  Future<void> _load() async {
    setState(() => _loading = true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final span = _window.spanMs;
    final since = span == null ? 0 : now - span;
    final log = BatteryLogger.instance;
    final series = await log.multiSeries(widget.serial, _metrics, sinceMs: since);
    final faults = await log.activeFaults(widget.serial, sinceMs: since);

    var from = since;
    var to = now;
    if (span == null) {
      int? lo, hi;
      for (final list in series.values) {
        for (final iv in list) {
          lo = (lo == null || iv.startMs < lo) ? iv.startMs : lo;
          hi = (hi == null || iv.endMs > hi) ? iv.endMs : hi;
        }
      }
      from = lo ?? (now - 3600 * 1000);
      to = hi != null && hi > now ? hi : now;
      if (to <= from) to = from + 60 * 1000;
    }

    if (!mounted) return;
    setState(() {
      _series = series;
      _faults = faults;
      _fromMs = from;
      _toMs = to;
      _loading = false;
    });
  }

  /// Cheap live refresh: re-read only the in-memory hour and splice its tail
  /// onto the already-loaded DB body, then advance the right edge to now.
  void _tickLive() {
    if (_loading || !mounted) return;
    final log = BatteryLogger.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    final span = _window.spanMs;
    final next = <String, List<ReadingInterval>>{};
    for (final m in _metrics) {
      final body = _series[m] ?? const [];
      // Keep DB body up to the last hour boundary; re-splice the live tail.
      final cutoff = now - BatteryLogger.hourMs;
      var maxEnd = span == null ? _fromMs : now - span;
      final kept = <ReadingInterval>[];
      for (final iv in body) {
        if (iv.startMs >= cutoff) break; // buffer will supply this region
        kept.add(iv);
        if (iv.endMs > maxEnd) maxEnd = iv.endMs;
      }
      final buf = log.hourSegments(widget.serial, m);
      final tail = <ReadingInterval>[];
      for (final iv in buf) {
        if (iv.endMs <= maxEnd) continue;
        final start = iv.startMs < maxEnd ? maxEnd : iv.startMs;
        tail.add(ReadingInterval(
          serial: iv.serial,
          metric: iv.metric,
          valueNum: iv.valueNum,
          valueText: iv.valueText,
          startMs: start,
          endMs: iv.endMs,
        ));
      }
      next[m] = [...kept, ...tail];
    }
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: SegmentedButton<TimeWindow>(
                  segments: [
                    for (final w in TimeWindow.values)
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
                    : !_hasAnyData
                        ? const _EmptyState()
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
                            children: _charts(),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _charts() {
    Series s(String metric, String label, Color color) =>
        Series(label, color, _series[metric] ?? const []);

    return [
      _ChartCard(
        title: 'Cell voltages',
        unit: 'V',
        fromMs: _fromMs,
        toMs: _toMs,
        series: [
          s(Metric.cell1, 'Cell 1', const Color(0xFF4C9AFF)),
          s(Metric.cell2, 'Cell 2', const Color(0xFF2FBF71)),
          s(Metric.cell3, 'Cell 3', const Color(0xFFF2C94C)),
          s(Metric.cell4, 'Cell 4', const Color(0xFFBB6BD9)),
        ],
      ),
      _ChartCard(
        title: 'Pack voltage',
        unit: 'V',
        fromMs: _fromMs,
        toMs: _toMs,
        series: [s(Metric.packVoltage, 'Pack', const Color(0xFF4C9AFF))],
      ),
      _ChartCard(
        title: 'Current (+ in / − out)',
        unit: 'A',
        fromMs: _fromMs,
        toMs: _toMs,
        centreZero: true,
        series: [s(Metric.packCurrent, 'Current', _green)],
      ),
      _ChartCard(
        title: 'Temperatures',
        unit: '°C',
        fromMs: _fromMs,
        toMs: _toMs,
        series: [
          s(Metric.temp1, 'Sensor 1', const Color(0xFFF2994A)),
          s(Metric.temp2, 'Sensor 2', const Color(0xFFEB5757)),
          s(Metric.chipTemp, 'Chip', const Color(0xFF56CCF2)),
        ],
      ),
      _ChartCard(
        title: 'State of charge',
        unit: '%',
        fromMs: _fromMs,
        toMs: _toMs,
        minY: 0,
        maxY: 100,
        series: [s(Metric.soc, 'SOC', _green)],
      ),
      _FaultTimelineCard(
        fromMs: _fromMs,
        toMs: _toMs,
        flags: _series[Metric.flags] ?? const [],
        faults: _faults,
      ),
    ];
  }
}

/// One named series: a metric's held intervals.
class Series {
  final String label;
  final Color color;
  final List<ReadingInterval> intervals;
  const Series(this.label, this.color, this.intervals);
}

class _ChartCard extends StatelessWidget {
  final String title;
  final String unit;
  final int fromMs;
  final int toMs;
  final List<Series> series;
  final double? minY;
  final double? maxY;
  final bool centreZero;

  const _ChartCard({
    required this.title,
    required this.unit,
    required this.fromMs,
    required this.toMs,
    required this.series,
    this.minY,
    this.maxY,
    this.centreZero = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = series.any((s) => s.intervals.isNotEmpty);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text(unit, style: const TextStyle(color: Colors.white54)),
              ],
            ),
            if (series.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [for (final s in series) _legendDot(s)],
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              height: 180,
              child: hasData
                  ? LineChart(_data())
                  : const Center(
                      child: Text('No samples in this window',
                          style: TextStyle(color: Colors.white38))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Series s) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 10,
              height: 10,
              decoration:
                  BoxDecoration(color: s.color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(s.label,
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      );

  LineChartData _data() {
    final bars = <LineChartBarData>[];
    var lo = double.infinity, hi = -double.infinity;

    for (final s in series) {
      // Split each series into runs of abutting intervals; each run is one bar
      // of held (step) points. A gap between runs is left unbridged.
      final runs = _runs(s.intervals);
      for (final run in runs) {
        final spots = <FlSpot>[];
        for (final iv in run) {
          final v = iv.valueNum;
          if (v == null) continue;
          spots.add(FlSpot(iv.startMs.toDouble(), v));
          spots.add(FlSpot(iv.endMs.toDouble(), v));
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        if (spots.isEmpty) continue;
        bars.add(LineChartBarData(
          spots: spots,
          isCurved: false,
          color: s.color,
          barWidth: 2,
          dotData: const FlDotData(show: false),
        ));
      }
    }

    // Y bounds.
    double yMin, yMax;
    if (minY != null && maxY != null) {
      yMin = minY!;
      yMax = maxY!;
    } else if (!lo.isFinite || !hi.isFinite) {
      yMin = 0;
      yMax = 1;
    } else if (centreZero) {
      final m = (lo.abs() > hi.abs() ? lo.abs() : hi.abs());
      final pad = m == 0 ? 1.0 : m * 0.15;
      yMax = m + pad;
      yMin = -yMax;
    } else {
      final pad = (hi - lo).abs() < 1e-9 ? 1.0 : (hi - lo) * 0.15;
      yMin = lo - pad;
      yMax = hi + pad;
    }

    final spanMs = (toMs - fromMs).toDouble().clamp(1.0, double.infinity);
    return LineChartData(
      minX: fromMs.toDouble(),
      maxX: toMs.toDouble(),
      minY: yMin,
      maxY: yMax,
      clipData: const FlClipData.all(),
      lineBarsData: bars,
      rangeAnnotations: RangeAnnotations(
        verticalRangeAnnotations: [
          for (final (a, b) in _offlineGaps(series, fromMs, toMs))
            VerticalRangeAnnotation(x1: a.toDouble(), x2: b.toDouble(),
                color: _offline),
        ],
      ),
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
              _fmtY(v),
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
                child: Text(_fmtTime(v.toInt(), spanMs),
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

  String _fmtY(double v) {
    if (v.abs() >= 100) return v.toStringAsFixed(0);
    if (v.abs() >= 10) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }
}

/// Group intervals into runs of consecutive rows that abut (gap ≤ threshold).
/// A larger gap starts a new run so no line bridges the offline window.
List<List<ReadingInterval>> _runs(List<ReadingInterval> ivs) {
  final runs = <List<ReadingInterval>>[];
  List<ReadingInterval>? cur;
  for (final iv in ivs) {
    if (cur == null || iv.startMs - cur.last.endMs > _gapMs) {
      cur = <ReadingInterval>[iv];
      runs.add(cur);
    } else {
      cur.add(iv);
    }
  }
  return runs;
}

/// Offline windows: stretches of [from,to] not covered by ANY series, i.e. the
/// battery was disconnected. Returned as (start,end) pairs to shade.
List<(int, int)> _offlineGaps(List<Series> series, int from, int to) {
  // Union of all covered intervals.
  final covered = <(int, int)>[];
  for (final s in series) {
    for (final iv in s.intervals) {
      covered.add((iv.startMs, iv.endMs));
    }
  }
  if (covered.isEmpty) return const [];
  covered.sort((a, b) => a.$1.compareTo(b.$1));

  // Merge overlapping/abutting (within threshold) coverage.
  final merged = <(int, int)>[];
  var (cs, ce) = covered.first;
  for (var i = 1; i < covered.length; i++) {
    final (s, e) = covered[i];
    if (s - ce <= _gapMs) {
      if (e > ce) ce = e;
    } else {
      merged.add((cs, ce));
      cs = s;
      ce = e;
    }
  }
  merged.add((cs, ce));

  // Complement within [from,to] = the offline gaps.
  final gaps = <(int, int)>[];
  var cursor = from;
  for (final (s, e) in merged) {
    if (s > cursor) gaps.add((cursor, s < to ? s : to));
    if (e > cursor) cursor = e;
  }
  if (cursor < to) gaps.add((cursor, to));
  return [for (final g in gaps) if (g.$2 - g.$1 > _gapMs) g];
}

/// Format an epoch-ms x tick. Shows HH:MM for windows under a day, else day/month.
String _fmtTime(int ms, double spanMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v < 10 ? '0$v' : '$v';
  if (spanMs > 36 * 3600 * 1000) {
    return '${d.day}/${d.month}';
  }
  return '${two(d.hour)}:${two(d.minute)}';
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
    final offline = _offlineGaps([Series('', _red, flags)], fromMs, toMs);
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
                  '${_fmtTime(f.startMs, (toMs - fromMs).toDouble())}  '
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

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.fromMs != fromMs ||
      old.toMs != toMs ||
      old.active != active ||
      old.offline != offline;
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
