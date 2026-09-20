/// Shared interval helpers (review pass C2, GitHub #51).
///
/// The charts page, the sparklines and the logger all reason about the SAME
/// thing — held `[startMs, endMs]` runs of a value, with a gap wider than
/// [BatteryLogger.gapMs] meaning "offline" — and each used to carry its own
/// copy of the run / coverage / splice logic. This library holds the one
/// implementation of each rule, plus the shared y-axis policy and look-back
/// window, and is pure Dart (no Flutter, no DB) so every helper is unit-tested
/// directly:
///
///  * [ReadingInterval] — the interval value type (moved here from the logger;
///    battery_log.dart re-exports it).
///  * [abuts] — the ONE gap rule: two spans abut iff `next.start - prev.end`
///    is at most the threshold.
///  * [splitRuns] — group time-ordered intervals into runs of abutting rows
///    (offline gaps are never bridged).
///  * [mergeCoverage] / [uncoveredGaps] — the union of covered time, and its
///    complement within a window (the offline stretches the charts shade).
///  * [spliceTail] — append the live in-memory tail onto the durable DB body
///    without duplicating or dropping anything (audit H4).
///  * [yBounds] — the 0-inclusive / symmetric-about-0 axis policy (#32).
///  * [LookbackWindow] + [computeRange] — the selectable look-back windows and
///    the from/to derivation the charts and sparklines share.
library;

/// Anything that spans `[startMs, endMs]`.
abstract interface class TimeSpan {
  int get startMs;
  int get endMs;
}

/// A finalized (or in-progress) interval: one run of a single value for one
/// (serial, metric). Immutable value type for queries and for the pure
/// interval builder's output.
class ReadingInterval implements TimeSpan {
  final String serial;
  final String metric;
  final double? valueNum;
  final String? valueText;
  @override
  final int startMs;
  @override
  final int endMs;

  const ReadingInterval({
    this.serial = '',
    this.metric = '',
    this.valueNum,
    this.valueText,
    required this.startMs,
    required this.endMs,
  });

  /// The same interval clamped to start no earlier than [startMs].
  ReadingInterval withStart(int startMs) => ReadingInterval(
        serial: serial,
        metric: metric,
        valueNum: valueNum,
        valueText: valueText,
        startMs: startMs,
        endMs: endMs,
      );

  @override
  String toString() =>
      'Interval($metric ${valueText ?? valueNum} $startMs..$endMs)';
}

/// THE gap rule. A span starting at [nextStartMs] abuts one that ended at
/// [prevEndMs] iff the gap between them is at most [gapMs]; a wider gap is an
/// offline window and is never bridged (by a run, a chart line, a band segment
/// or the logger's open interval).
bool abuts(int prevEndMs, int nextStartMs, int gapMs) =>
    nextStartMs - prevEndMs <= gapMs;

/// #53: the margin added to a background sample interval before a gap counts
/// as offline — a sample takes a few seconds, a reconnect at weak signal (and
/// its backoff) considerably longer.
const int sampleGapMarginMs = 60 * 1000;

/// #53: the gap threshold for readings taken [intervalMs] apart in background
/// sampling mode: the interval plus [marginMs]. Continuous (`intervalMs <= 0`)
/// keeps the base rule ([baseGapMs], the logger's 10 s).
int sampleGapMs(int intervalMs,
        {int baseGapMs = 10000, int marginMs = sampleGapMarginMs}) =>
    intervalMs <= 0 ? baseGapMs : intervalMs + marginMs;

/// #53: the gap rule that knows the sample interval IN EFFECT at each instant.
///
/// Built from the logged `sampleIntervalS` series (seconds between background
/// samples, 0 = continuous; start-ordered). A row's value holds from its start
/// until the NEXT row starts (rows are sparse in sampling mode). Two spans abut
/// iff their gap is at most the LARGER of the thresholds at the previous end
/// and at the next start, so both transitions — continuous -> sampling (the
/// gap before the first sparse sample) and sampling -> continuous (the gap
/// after the last one) — are expected gaps, not offline. Only a gap wider than
/// (interval + margin) is offline. With no rows it is exactly [abuts].
class GapPolicy {
  /// `sampleIntervalS` intervals in start order (value = seconds, 0 = continuous).
  final List<ReadingInterval> rows;
  final int baseGapMs;
  final int marginMs;

  const GapPolicy(this.rows,
      {this.baseGapMs = 10000, this.marginMs = sampleGapMarginMs});

  /// The plain continuous rule (no sampling rows).
  static const GapPolicy continuous = GapPolicy([]);

  /// The sample interval (ms) in effect at [ms]: the latest row starting at or
  /// before it; 0 (continuous) when none.
  int intervalAt(int ms) {
    if (rows.isEmpty) return 0;
    // Binary search for the last row with startMs <= ms.
    var lo = 0, hi = rows.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (rows[mid].startMs <= ms) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found < 0) return 0;
    final s = rows[found].valueNum ?? 0;
    return s <= 0 ? 0 : (s * 1000).round();
  }

  /// True iff readings at [ms] were background samples.
  bool isBackgroundAt(int ms) => intervalAt(ms) > 0;

  /// True iff any row records background sampling.
  bool get hasBackground => rows.any((r) => (r.valueNum ?? 0) > 0);

  /// The gap threshold in effect at [ms].
  int gapAt(int ms) =>
      sampleGapMs(intervalAt(ms), baseGapMs: baseGapMs, marginMs: marginMs);

  /// The threshold for the gap between a span ending at [prevEndMs] and one
  /// starting at [nextStartMs]: the larger of the two instants' thresholds.
  int gapFor(int prevEndMs, int nextStartMs) {
    final a = gapAt(prevEndMs), b = gapAt(nextStartMs);
    return a > b ? a : b;
  }

  /// The policy-aware [abuts].
  bool abuts(int prevEndMs, int nextStartMs) =>
      nextStartMs - prevEndMs <= gapFor(prevEndMs, nextStartMs);
}

/// Group time-ordered intervals into runs of consecutive rows that abut
/// (gap <= [gapMs], or per [policy] when given — #53); a wider gap starts a
/// new run so the offline window is left unbridged. [where] optionally drops
/// rows (e.g. null-valued ones) BEFORE grouping, so a dropped row neither
/// starts nor extends a run.
List<List<T>> splitRuns<T extends TimeSpan>(
  Iterable<T> ivs, {
  required int gapMs,
  bool Function(T iv)? where,
  GapPolicy? policy,
}) {
  final runs = <List<T>>[];
  List<T>? cur;
  for (final iv in ivs) {
    if (where != null && !where(iv)) continue;
    final prev = cur;
    final joined = prev != null &&
        (policy != null
            ? policy.abuts(prev.last.endMs, iv.startMs)
            : abuts(prev.last.endMs, iv.startMs, gapMs));
    if (!joined) {
      cur = <T>[iv];
      runs.add(cur);
    } else {
      prev.add(iv);
    }
  }
  return runs;
}

/// The union of covered time across [ivs] (any order): sorted, with spans that
/// overlap or abut (within [gapMs], or per [policy] — #53) merged into one
/// `(start, end)`.
List<(int, int)> mergeCoverage(Iterable<TimeSpan> ivs,
    {required int gapMs, GapPolicy? policy}) {
  final covered = <(int, int)>[for (final iv in ivs) (iv.startMs, iv.endMs)];
  if (covered.isEmpty) return const [];
  covered.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  var (cs, ce) = covered.first;
  for (var i = 1; i < covered.length; i++) {
    final (s, e) = covered[i];
    final joined =
        policy != null ? policy.abuts(ce, s) : abuts(ce, s, gapMs);
    if (joined) {
      if (e > ce) ce = e;
    } else {
      merged.add((cs, ce));
      cs = s;
      ce = e;
    }
  }
  merged.add((cs, ce));
  return merged;
}

/// Offline windows: the stretches of `[from, to]` not covered by ANY of [ivs]
/// (the complement of [mergeCoverage]), keeping only gaps wider than [gapMs]
/// (or than the [policy]'s threshold for that gap — #53). Empty when nothing
/// is covered at all (nothing to contrast against).
List<(int, int)> uncoveredGaps(
  Iterable<TimeSpan> ivs,
  int from,
  int to, {
  required int gapMs,
  GapPolicy? policy,
}) {
  final merged = mergeCoverage(ivs, gapMs: gapMs, policy: policy);
  if (merged.isEmpty) return const [];
  final gaps = <(int, int)>[];
  var cursor = from;
  for (final (s, e) in merged) {
    if (s > cursor) gaps.add((cursor, s < to ? s : to));
    if (e > cursor) cursor = e;
  }
  if (cursor < to) gaps.add((cursor, to));
  return [
    for (final g in gaps)
      if (g.$2 - g.$1 > (policy?.gapFor(g.$1, g.$2) ?? gapMs)) g
  ];
}

/// Splice the live in-memory tail onto the durable DB body for one metric
/// (audit H4 — shared by the logger's `mergedSeries` and the charts page's
/// per-second live tick). EVERY DB row is kept; the in-memory segments are
/// appended only where they extend past the newest DB `end_ms` (clamped to
/// start there), so an open interval not yet flushed to SQLite is completed
/// without duplicating it — and history from a previous session (which the
/// in-memory buffer never held) is never dropped or replaced.
List<ReadingInterval> spliceTail(
  List<ReadingInterval> body,
  List<ReadingInterval> buffer, {
  int sinceMs = 0,
}) {
  var maxEnd = sinceMs;
  for (final iv in body) {
    if (iv.endMs > maxEnd) maxEnd = iv.endMs;
  }
  final tail = <ReadingInterval>[];
  for (final iv in buffer) {
    if (iv.endMs <= maxEnd) continue;
    tail.add(iv.startMs < maxEnd ? iv.withStart(maxEnd) : iv);
  }
  if (tail.isEmpty) return body;
  return [...body, ...tail];
}

/// The ONE y-axis policy (#32) for the charts and the sparklines. The axis
/// ALWAYS includes 0:
///  * explicit [minY]/[maxY] win (e.g. SOC 0..100);
///  * [centreZero] metrics (signed current / power) get a symmetric −m..+m
///    about 0 so the sign reads;
///  * otherwise it spans 0..max (or min..0 for all-negative data) — never a
///    zoomed band far from zero.
/// [pad] is the fraction of the span added outward past the extreme so it is
/// not flush with the frame (the charts use 0.1). With `pad == 0` (the
/// sparklines) nothing is added — except that a perfectly flat series at 0 is
/// widened to −1..+1 so its held line sits mid-height; with a positive pad a
/// flat series at 0 keeps 0 as the hard floor (0..1). [lo]/[hi] are the data
/// min/max; non-finite (no data) falls back to 0..1.
(double, double) yBounds(
  double lo,
  double hi, {
  double? minY,
  double? maxY,
  bool centreZero = false,
  double pad = 0.1,
}) {
  if (minY != null && maxY != null) return (minY, maxY);
  if (!lo.isFinite || !hi.isFinite) return (0, 1);
  if (centreZero) {
    final m = lo.abs() > hi.abs() ? lo.abs() : hi.abs();
    final top = m == 0 ? 1.0 : m + m * pad;
    return (-top, top);
  }
  final rawMin = lo < 0 ? lo : 0.0;
  final rawMax = hi > 0 ? hi : 0.0;
  final span = rawMax - rawMin;
  if (span.abs() < 1e-9) return pad > 0 ? (0, 1) : (rawMin - 1, rawMax + 1);
  final p = span * pad;
  final yMin = rawMin < 0 ? rawMin - p : 0.0;
  final yMax = rawMax > 0 ? rawMax + p : 0.0;
  return (yMin, yMax);
}

/// Selectable look-back windows. The charts page offers [chartWindows]; the
/// detail-page sparklines offer every value (wider, adding 7 days, #14).
enum LookbackWindow {
  h1('1h', 3600 * 1000),
  h6('6h', 6 * 3600 * 1000),
  h24('24h', 24 * 3600 * 1000),
  d7('7d', 7 * 24 * 3600 * 1000),
  all('All', null);

  const LookbackWindow(this.label, this.spanMs);

  /// Segment label.
  final String label;

  /// Milliseconds of look-back, or null for "all".
  final int? spanMs;

  /// The windows the charts page shows (no 7-day band there).
  static const chartWindows = [h1, h6, h24, all];
}

/// The `[from, to]` range to plot for a look-back [spanMs] ending at [nowMs]:
/// exactly `now - span .. now` for a fixed window, else (span null = "all")
/// the extent of the data in [series] — from its earliest start (or one hour
/// ago when there is none) to the later of its latest end and now, and never
/// shorter than one minute.
({int fromMs, int toMs}) computeRange(
  Iterable<Iterable<TimeSpan>> series,
  int? spanMs,
  int nowMs,
) {
  if (spanMs != null) return (fromMs: nowMs - spanMs, toMs: nowMs);
  int? lo, hi;
  for (final list in series) {
    for (final iv in list) {
      lo = (lo == null || iv.startMs < lo) ? iv.startMs : lo;
      hi = (hi == null || iv.endMs > hi) ? iv.endMs : hi;
    }
  }
  final from = lo ?? (nowMs - 3600 * 1000);
  var to = hi != null && hi > nowMs ? hi : nowMs;
  if (to <= from) to = from + 60 * 1000;
  return (fromMs: from, toMs: to);
}

/// A cheap change signature for an interval list, for `shouldRepaint` (L8).
/// Two lists with the same signature are treated as the same data: length,
/// first start, last start/end and last value — the only things a live
/// append/extend can change — so an unchanged series never repaints.
int intervalsSignature(List<ReadingInterval> ivs) {
  if (ivs.isEmpty) return 0;
  final f = ivs.first, l = ivs.last;
  return Object.hash(ivs.length, f.startMs, f.valueNum, l.startMs, l.endMs,
      l.valueNum, l.valueText);
}
