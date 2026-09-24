/// Inline per-row sparklines (issue #14).
///
/// Compact summaries of a single metric's recent history, drawn beside each
/// telemetry row on the battery detail page. They reuse the interval-store
/// series ([ReadingInterval]) and follow the same rules as the full charts —
/// through the SAME shared helpers (intervals.dart, review pass C2):
///
///  * HELD / step segments (a value holds from `start_ms` to `end_ms`).
///  * OFFLINE GAPS are left UNBRIDGED — a gap between abutting rows wider than
///    [BatteryLogger.gapMs] splits the line into separate runs ([splitRuns]).
///  * the y-axis always includes 0 ([yBounds]) — or, when the app-wide
///    [gYAxisMode] is FIT (#70), is tight to the data seen in the window.
///  * an ALPHA-BLENDED area fill under the line.
///
/// [buildSparklineRuns] is the pure, unit-tested core: it groups intervals into
/// unbridged runs and DOWNSAMPLES each run for drawing only (it never mutates
/// stored data). The [Sparkline] widget paints those runs.
library;

import 'package:flutter/material.dart';

import 'battery_log.dart';
import 'intervals.dart';

/// One point of a sparkline run (epoch-ms x, metric-value y). [bg] marks a
/// point taken in background sampling mode (#53): the segment on either side
/// of it is drawn lighter/dotted in the same colour.
class SparkPoint {
  final double ms;
  final double v;
  final bool bg;
  const SparkPoint(this.ms, this.v, {this.bg = false});
}

/// Group held intervals into runs of consecutive rows that ABUT (gap ≤
/// [gapMs], or per the sample-interval [policy] — #53: an expected sampling
/// gap is bridged, only a gap wider than interval + margin is offline); a
/// wider gap starts a new run so the offline window is left unbridged. Each
/// run is emitted as step points (start,v)(end,v) and then DOWNSAMPLED to at
/// most [maxPointsPerRun] points for drawing — the stored data is never
/// touched. Null-valued rows are skipped.
List<List<SparkPoint>> buildSparklineRuns(
  List<ReadingInterval> ivs, {
  int gapMs = BatteryLogger.gapMs,
  int maxPointsPerRun = 240,
  GapPolicy? policy,
}) {
  final groups = splitRuns(ivs,
      gapMs: gapMs, policy: policy, where: (iv) => iv.valueNum != null);
  final runs = <List<SparkPoint>>[];
  for (final g in groups) {
    final pts = <SparkPoint>[];
    for (final iv in g) {
      final v = iv.valueNum!;
      pts.add(SparkPoint(iv.startMs.toDouble(), v,
          bg: policy?.isBackgroundAt(iv.startMs) ?? false));
      pts.add(SparkPoint(iv.endMs.toDouble(), v,
          bg: policy?.isBackgroundAt(iv.endMs) ?? false));
    }
    runs.add(_downsample(pts, maxPointsPerRun));
  }
  return runs;
}

/// Even-stride downsample that always keeps the first and last point. O(n).
List<SparkPoint> _downsample(List<SparkPoint> p, int max) {
  if (max < 2 || p.length <= max) return p;
  final out = <SparkPoint>[p.first];
  final step = (p.length - 2) / (max - 2);
  for (var i = 1; i < max - 1; i++) {
    final idx = (1 + i * step).floor().clamp(1, p.length - 2);
    out.add(p[idx]);
  }
  out.add(p.last);
  return out;
}

/// The sparkline's y-axis bounds (#32): the shared [yBounds] policy with no
/// outward padding — 0..max for level metrics, symmetric about 0 for signed
/// ([centreZero]) ones, a flat-at-0 series widened to −1..+1 so its held line
/// sits mid-height. In [YAxisMode.fit] (#70) exactly min..max of the data.
/// Null when there is no finite data.
(double, double)? sparkYBounds(List<List<SparkPoint>> runs,
    {bool centreZero = false, YAxisMode mode = YAxisMode.full}) {
  var lo = double.infinity, hi = -double.infinity;
  for (final run in runs) {
    for (final p in run) {
      if (p.v < lo) lo = p.v;
      if (p.v > hi) hi = p.v;
    }
  }
  if (!lo.isFinite || !hi.isFinite) return null;
  return yBounds(lo, hi, centreZero: centreZero, pad: 0, mode: mode);
}

/// L8: runs built per interval LIST INSTANCE. The detail page hands the same
/// list to every rebuild between two history loads (~3 s apart, plus every
/// live event in between), so the O(n) run build happens once per load, not
/// once per frame. Entries die with their list.
final Expando<List<List<SparkPoint>>> _runsFor = Expando('sparkline runs');

/// A compact inline sparkline: held/step line with a translucent area fill,
/// offline gaps left as breaks. Draws nothing (an em dash placeholder) when
/// there is no data in the window.
class Sparkline extends StatelessWidget {
  final List<ReadingInterval> intervals;
  final int fromMs;
  final int toMs;
  final Color color;
  final double height;

  /// Force the y-range to include zero (e.g. signed current) so the sign reads.
  final bool centreZero;

  /// #53: the sample-interval policy for this window (null = continuous).
  final GapPolicy? policy;

  /// #70: the Y-axis mode; null (the default) follows the app-wide
  /// [gYAxisMode] — the sparklines always track the Settings default.
  final YAxisMode? mode;

  const Sparkline({
    super.key,
    required this.intervals,
    required this.fromMs,
    required this.toMs,
    required this.color,
    this.height = 30,
    this.centreZero = false,
    this.policy,
    this.mode,
  });

  @override
  Widget build(BuildContext context) {
    final runs = intervals.isEmpty
        ? const <List<SparkPoint>>[]
        : (_runsFor[intervals] ??=
            buildSparklineRuns(intervals, policy: policy));
    return SizedBox(
      height: height,
      width: double.infinity,
      child: runs.isEmpty
          ? Align(
              alignment: Alignment.centerLeft,
              child: Text('—',
                  style: TextStyle(
                      color: color.withValues(alpha: 0.4), fontSize: 13)),
            )
          : CustomPaint(
              painter: _SparkPainter(
                runs: runs,
                dataSig: intervalsSignature(intervals),
                fromMs: fromMs,
                toMs: toMs,
                color: color,
                centreZero: centreZero,
                mode: mode ?? gYAxisMode,
              ),
            ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<List<SparkPoint>> runs;

  /// L8: cheap change signature of the source intervals — unchanged data with
  /// the same window and colour does not repaint.
  final int dataSig;
  final int fromMs;
  final int toMs;
  final Color color;
  final bool centreZero;
  final YAxisMode mode; // #70

  _SparkPainter({
    required this.runs,
    required this.dataSig,
    required this.fromMs,
    required this.toMs,
    required this.color,
    required this.centreZero,
    required this.mode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final span = (toMs - fromMs).toDouble();
    if (span <= 0) return;
    // #32: 0-based (or symmetric-about-0 for signed) y-range — never a zoomed
    // band far from zero — unless the Settings default is FIT (#70).
    final bounds = sparkYBounds(runs, centreZero: centreZero, mode: mode);
    if (bounds == null) return;
    final (lo, hi) = bounds;
    final vSpan = hi - lo;

    double x(double ms) => ((ms - fromMs) / span * size.width);
    double y(double v) => size.height - ((v - lo) / vSpan * size.height);

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.16);
    // #33: missing/offline periods are bridged by a straight DASHED line in the
    // SAME series colour (solid = real logged data, dashed = missing).
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: 0.85);
    // #53: background-sampled segments — same colour, lighter and DOTTED
    // (short dots, distinct from the offline dash) — the line stays
    // continuous across the expected sampling gaps.
    final dotted = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55);

    Offset? prevLast;
    for (final run in runs) {
      if (run.isEmpty) continue;
      final firstPt = Offset(x(run.first.ms), y(run.first.v));
      // Dashed straight bridge across the gap from the previous run.
      if (prevLast != null) {
        _drawDashedLine(canvas, prevLast, firstPt, dash);
      }
      final path = Path();
      final area = Path();
      var solidOpen = false;
      for (var i = 0; i < run.length; i++) {
        final px = x(run[i].ms);
        final py = y(run[i].v);
        if (i == 0) {
          area.moveTo(px, size.height);
          area.lineTo(px, py);
          continue;
        }
        area.lineTo(px, py);
        final prev = run[i - 1];
        final a = Offset(x(prev.ms), y(prev.v));
        final b = Offset(px, py);
        if (prev.bg || run[i].bg) {
          _drawDashedLine(canvas, a, b, dotted, dashLen: 1.2, gapLen: 3);
          solidOpen = false;
        } else {
          if (!solidOpen) {
            path.moveTo(a.dx, a.dy);
            solidOpen = true;
          }
          path.lineTo(b.dx, b.dy);
        }
      }
      // Close the area down to the baseline under the last point.
      area.lineTo(x(run.last.ms), size.height);
      area.close();
      canvas.drawPath(area, fill);
      canvas.drawPath(path, line);
      prevLast = Offset(x(run.last.ms), y(run.last.v));
    }
  }

  /// Draw a straight dashed segment from [a] to [b] (used to bridge offline
  /// gaps, #33). Even-length dashes with a gap between them.
  static void _drawDashedLine(Canvas c, Offset a, Offset b, Paint p,
      {double dashLen = 4, double gapLen = 3}) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final end = d + dashLen < total ? d + dashLen : total;
      c.drawLine(a + dir * d, a + dir * end, p);
      d += dashLen + gapLen;
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.dataSig != dataSig ||
      old.fromMs != fromMs ||
      old.toMs != toMs ||
      old.color != color ||
      old.centreZero != centreZero ||
      old.mode != mode;
}
