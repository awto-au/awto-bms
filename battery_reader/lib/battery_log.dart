/// On-device telemetry logging as an **append-only interval store**.
///
/// The model (agreed with the user) is deliberately lossless — there is NO
/// downsampling, NO heartbeat and NO deletion, ever:
///
///  * **Durable store = one append-only interval table.** A row is one run of a
///    single value for one (serial, metric): it holds from `start_time` to
///    `end_time` (full local date-and-time text, `yyyy-MM-dd HH:mm:ss.SSS`, to
///    match the text log and the Python store) AND — since schema v3 (review
///    pass C1, H2) — from `start_ms` to `end_ms` (epoch milliseconds). The text
///    columns are kept for readability; ALL ordering, window filtering,
///    watermark comparison, splicing and duration maths use the `*_ms` columns,
///    because local-time text is not monotonic across a DST change or a
///    timezone change (see [BatteryLogger] for the divergence from the frozen
///    Python store, which stays text-only). On each observed reading we either *extend* the
///    current open row (same value AND contiguous in time) or *finalize* it and
///    insert a *new* row starting now. See [IntervalRule] and [buildIntervals]
///    for the pure, unit-tested change/extend/gap logic.
///
///  * **Gaps are preserved.** If time since the open row's `end_time` exceeds
///    the gap threshold (~10 s), or the connection drops, we do NOT extend
///    across it: the old row keeps its last `end_time` and the next reading
///    opens a fresh row. The space between one row's `end_time` and the next
///    row's `start_time` is the known-disconnected window and the charts shade
///    it as offline.
///
///  * **DB write cadence.** Each metric's open interval is held in memory; its
///    advancing `end_time` is flushed to SQLite about once per minute (and
///    immediately on disconnect / app pause / dispose). Value CHANGES are
///    written immediately (a new row is inserted the moment the value changes);
///    only the `end_time` advance of an unchanged value is batched to ~60 s.
///
///  * **Rolling in-memory hour.** In addition, the last hour of raw readings per
///    (serial, metric) is kept in memory at full resolution for live graphing —
///    separate from the DB.
///
/// The pure pieces ([IntervalRule], [buildIntervals], [Obs], [ReadingInterval])
/// carry no Flutter/sqflite dependency, so they run on the Dart VM under test.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'battery_connection.dart';
import 'battery_protocol.dart';
import 'diagnostics.dart';
import 'fmt.dart';
import 'intervals.dart';
import 'metrics.dart';

// Review pass C2: the metric KEYS live in the metric catalogue (metrics.dart,
// one row per metric) and the interval value type + run/gap/splice helpers in
// intervals.dart. Both are re-exported here so existing importers still see
// `Metric` and `ReadingInterval` through the logger.
export 'intervals.dart' show ReadingInterval;
export 'metrics.dart' show Metric;

/// Bit layout for the packed [Metric.flags] integer (LSB-first). Kept identical
/// to the Python store so both platforms pack and read `flags` the same way.
class Flags {
  static const int mos = 1 << 0;
  static const int load = 1 << 1;
  static const int charger = 1 << 2;
  static const int chgMos = 1 << 3;
  static const int disMos = 1 << 4;
  static const int passiveBal = 1 << 5;
  static const int sleep = 1 << 6;
  static const int faultCurrent = 1 << 7;
  static const int faultVoltage = 1 << 8;
  static const int faultTemperature = 1 << 9;
  static const int faultMask = faultCurrent | faultVoltage | faultTemperature;
  static const int chargeStateShift = 10; // bits 10-11
  static const int chargeStateMask = 0x3 << chargeStateShift;

  static bool faultActive(int f) => (f & faultMask) != 0;

  static List<String> faultCategories(int f) => [
        if (f & faultCurrent != 0) 'Current',
        if (f & faultVoltage != 0) 'Voltage',
        if (f & faultTemperature != 0) 'Temperature',
      ];

  static int chargeState(int f) => (f & chargeStateMask) >> chargeStateShift;
}

/// M8: true once EVERY state that contributes to the packed `flags` row has
/// been decoded at least once — the same key set the Python store requires
/// (`REQUIRED_FLAG_KEYS`: mos, load, charger, chgMos, disMos, passiveBal,
/// chargeState, faultCurrent, faultVoltage, faultTemperature). `sleep` is
/// deliberately NOT required: a pack streaming telemetry is awake, so it
/// defaults to off and only flips on via an explicit sleep ack.
bool flagsComplete(BatteryState s) =>
    s.mosOn != null &&
    s.loadConnected != null &&
    s.chargerConnected != null &&
    s.chargeMos != null &&
    s.dischargeMos != null &&
    s.passiveBalancing != null &&
    s.chargeState != ChargeState.unknown &&
    s.currentAlarmSeen &&
    s.voltageAlarmSeen &&
    s.temperatureAlarmSeen;

/// Pack the boolean/enum state into the shared [Flags] integer, or null until
/// [flagsComplete] (M8) — so a `flags` row never carries a 0 bit that really
/// means "unknown". Pure; unit-tested without a database.
int? packFlags(BatteryState s) {
  if (!flagsComplete(s)) return null;
  var f = 0;
  if (s.mosOn == true) f |= Flags.mos;
  if (s.loadConnected == true) f |= Flags.load;
  if (s.chargerConnected == true) f |= Flags.charger;
  if (s.chargeMos == true) f |= Flags.chgMos;
  if (s.dischargeMos == true) f |= Flags.disMos;
  if (s.passiveBalancing == true) f |= Flags.passiveBal;
  if (s.sleepModeOn == true) f |= Flags.sleep;
  // Genuine faults only (temperature already excludes the latched byte [2]
  // and the status bits [3],[6]); a cleared alarm re-packs these as 0.
  if (s.faultCurrent) f |= Flags.faultCurrent;
  if (s.faultVoltage) f |= Flags.faultVoltage;
  if (s.faultTemperature) f |= Flags.faultTemperature;
  final cs = switch (s.chargeState) {
    ChargeState.charging => 1,
    ChargeState.discharging => 2,
    _ => 0, // idle (unknown is excluded by the gate above)
  };
  f |= (cs & 0x3) << Flags.chargeStateShift;
  return f;
}

/// One observation fed to the pure interval builder.
class Obs {
  final int ms;
  final num? value;
  final String? text;
  const Obs(this.ms, {this.value, this.text});
}

// ---------------------------------------------------------------------------
// Pure change/extend/gap decision. No Flutter, no sqflite — unit-testable.
// ---------------------------------------------------------------------------

enum IntervalAction {
  /// No interval is open yet: start a fresh one.
  openNew,

  /// Same value and contiguous in time: advance the open interval's end.
  extend,

  /// Value changed, or a gap larger than the threshold: finalize the open
  /// interval (it keeps its last end) and start a fresh one at `now`.
  closeAndOpen,
}

class IntervalRule {
  /// Readings more than this far apart are treated as a disconnect: the run is
  /// broken rather than extended across the gap.
  final int gapMs;

  /// Two numeric values within this are treated as equal (float-noise
  /// insurance; telemetry is already quantised).
  final double epsilon;

  const IntervalRule({this.gapMs = 10000, this.epsilon = 1e-9});

  bool sameValue(num? aNum, String? aText, num? bNum, String? bText) {
    if (aText != null || bText != null) return aText == bText;
    if (aNum == null || bNum == null) return aNum == bNum;
    return (aNum - bNum).abs() <= epsilon;
  }

  /// The shared gap rule ([abuts]): a reading is contiguous with the open
  /// interval iff it lands within [gapMs] of its end.
  bool contiguous(int openEndMs, int nowMs) => abuts(openEndMs, nowMs, gapMs);

  /// Decide what to do with a new observation given the currently open run.
  IntervalAction decide({
    required bool hasOpen,
    num? openNum,
    String? openText,
    int openEndMs = 0,
    num? newNum,
    String? newText,
    required int nowMs,
  }) {
    if (!hasOpen) return IntervalAction.openNew;
    final same = sameValue(openNum, openText, newNum, newText);
    final contig = contiguous(openEndMs, nowMs);
    if (same && contig) return IntervalAction.extend;
    return IntervalAction.closeAndOpen;
  }
}

/// Fold a list of observations into interval rows using [IntervalRule]. Pure:
/// mirrors exactly what [BatteryLogger] persists, so the model is testable
/// without a database. Observations must be in non-decreasing time order.
List<ReadingInterval> buildIntervals(
  List<Obs> obs, {
  String serial = '',
  String metric = '',
  int gapMs = 10000,
  double epsilon = 1e-9,
}) {
  final rule = IntervalRule(gapMs: gapMs, epsilon: epsilon);
  final out = <ReadingInterval>[];

  num? curNum;
  String? curText;
  int curStart = 0;
  int curEnd = 0;
  var hasOpen = false;

  void flush() {
    if (!hasOpen) return;
    out.add(ReadingInterval(
      serial: serial,
      metric: metric,
      valueNum: curNum?.toDouble(),
      valueText: curText,
      startMs: curStart,
      endMs: curEnd,
    ));
  }

  for (final o in obs) {
    final action = rule.decide(
      hasOpen: hasOpen,
      openNum: curNum,
      openText: curText,
      openEndMs: curEnd,
      newNum: o.value,
      newText: o.text,
      nowMs: o.ms,
    );
    switch (action) {
      case IntervalAction.extend:
        curEnd = o.ms;
      case IntervalAction.openNew:
      case IntervalAction.closeAndOpen:
        flush();
        curNum = o.value;
        curText = o.text;
        curStart = o.ms;
        curEnd = o.ms;
        hasOpen = true;
    }
  }
  flush();
  return out;
}

// ---------------------------------------------------------------------------
// Internal mutable open-interval bookkeeping for the live logger.
// ---------------------------------------------------------------------------

class _Open {
  final int id; // DB primary key (assigned by us, known synchronously)
  final String serial;
  final String metric;
  final double? valueNum;
  final String? valueText;
  final int startMs;
  int endMs;
  int flushedEndMs;

  _Open({
    required this.id,
    required this.serial,
    required this.metric,
    required this.valueNum,
    required this.valueText,
    required this.startMs,
  })  : endMs = startMs,
        flushedEndMs = startMs;
}

class _Raw {
  final int ms;
  final double? value;
  final String? text;
  const _Raw(this.ms, this.value, this.text);
}

/// One folded run of the rolling hour buffer: the same change/extend/gap fold
/// as [buildIntervals], maintained INCREMENTALLY (L8) so `hourSegments` is a
/// copy of a small list rather than a re-fold of up to 8000 raw points per
/// metric every tick. [count] is how many raw points the run covers, so that
/// dropping raw points from the front of the buffer trims the runs exactly.
class _Seg {
  final double? value;
  final String? text;
  int startMs;
  int endMs;
  int count;
  _Seg(this.value, this.text, this.startMs)
      : endMs = startMs,
        count = 1;
}

/// The rolling in-memory hour for one (serial, metric): the raw readings (the
/// source of truth for the hour cutoff and the size cap) plus their folded
/// runs and a cached immutable snapshot of those runs. The snapshot keeps its
/// IDENTITY until the next push, so a chart tick that finds nothing changed
/// can skip rebuilding that series.
class _HourBuffer {
  final List<_Raw> raw = [];
  final List<_Seg> segs = [];
  List<ReadingInterval>? snapshot;

  /// Append one reading and fold it into the runs with [rule] (identical to
  /// re-running [buildIntervals] over the raw list). Readings older than
  /// [cutoffMs], and any beyond [cap], are dropped from the front.
  void push(int now, double? value, String? text, IntervalRule rule,
      {required int cutoffMs, required int cap}) {
    raw.add(_Raw(now, value, text));
    final last = segs.isEmpty ? null : segs.last;
    final action = rule.decide(
      hasOpen: last != null,
      openNum: last?.value,
      openText: last?.text,
      openEndMs: last?.endMs ?? 0,
      newNum: value,
      newText: text,
      nowMs: now,
    );
    if (action == IntervalAction.extend) {
      last!.endMs = now;
      last.count++;
    } else {
      segs.add(_Seg(value, text, now));
    }
    var drop = 0;
    while (drop < raw.length && raw[drop].ms < cutoffMs) {
      drop++;
    }
    if (raw.length - drop > cap) drop = raw.length - cap;
    if (drop > 0) _dropFront(drop);
    snapshot = null;
  }

  /// Drop the oldest [drop] raw points and trim the runs to match: a run whose
  /// points are all gone is removed; the run that straddles the cut keeps its
  /// remaining points and now starts at the first surviving reading — exactly
  /// what a fresh fold over the surviving points would produce.
  void _dropFront(int drop) {
    raw.removeRange(0, drop);
    var removed = 0;
    while (drop > 0 && removed < segs.length) {
      final s = segs[removed];
      if (s.count <= drop) {
        drop -= s.count;
        removed++;
      } else {
        s.count -= drop;
        s.startMs = raw.first.ms;
        drop = 0;
      }
    }
    if (removed > 0) segs.removeRange(0, removed);
  }

  /// The runs as immutable intervals (cached until the next push).
  List<ReadingInterval> intervals(String serial, String metric) =>
      snapshot ??= List.unmodifiable([
        for (final s in segs)
          ReadingInterval(
            serial: serial,
            metric: metric,
            valueNum: s.value,
            valueText: s.text,
            startMs: s.startMs,
            endMs: s.endMs,
          ),
      ]);
}

// ---------------------------------------------------------------------------
// Lifetime aggregate totals for one battery (or a summed fleet). Read-only
// output of the periodic DB scan (task 7).
// ---------------------------------------------------------------------------

class AggregateTotals {
  final double chargeAh; // total Ah pushed IN (current > 0)
  final double dischargeAh; // total Ah drawn OUT (current < 0)
  final double efc; // equivalent full cycles = throughput / rated capacity

  const AggregateTotals({
    this.chargeAh = 0,
    this.dischargeAh = 0,
    this.efc = 0,
  });

  double get throughputAh => chargeAh + dischargeAh;

  AggregateTotals operator +(AggregateTotals o) => AggregateTotals(
        chargeAh: chargeAh + o.chargeAh,
        dischargeAh: dischargeAh + o.dischargeAh,
        efc: efc + o.efc,
      );
}

// ---------------------------------------------------------------------------
// Persisted, checkpointed LIFETIME totals for one battery (issue #37). Unlike
// the in-session [AggregateTotals] (a whole-history rescan), these are the
// durable running totals in the `lifetime_totals` table: each cheap update
// folds ONLY the `readings` rows newer than [aggregatedUpToMs] into the stored
// figures and advances the watermark, so cost is O(new rows) — never a rescan.
// ---------------------------------------------------------------------------

class LifetimeTotals {
  final double chargeAh; // lifetime Ah pushed IN (current > 0)
  final double dischargeAh; // lifetime Ah drawn OUT (current < 0)
  final double efc; // lifetime equivalent full cycles
  /// Newest reading `end_time` already folded in, as epoch-ms. 0 = nothing yet
  /// aggregated (first run scans from the very beginning).
  final int aggregatedUpToMs;

  const LifetimeTotals({
    this.chargeAh = 0,
    this.dischargeAh = 0,
    this.efc = 0,
    this.aggregatedUpToMs = 0,
  });

  double get throughputAh => chargeAh + dischargeAh;

  /// View as the display-facing [AggregateTotals] (drops the watermark).
  AggregateTotals get totals =>
      AggregateTotals(chargeAh: chargeAh, dischargeAh: dischargeAh, efc: efc);

  @override
  String toString() => 'charge=${chargeAh.toStringAsFixed(2)}Ah '
      'discharge=${dischargeAh.toStringAsFixed(2)}Ah '
      'efc=${efc.toStringAsFixed(3)} up_to=$aggregatedUpToMs';
}

/// Integrated charge / discharge Ah over a run of signed-current rows, plus the
/// newest `end_ms` seen (the next watermark). Output of [integrateCurrentRows].
class CurrentIntegral {
  final double chargeAh;
  final double dischargeAh;
  final int newestEndMs;
  const CurrentIntegral({
    this.chargeAh = 0,
    this.dischargeAh = 0,
    this.newestEndMs = 0,
  });
  double get throughputAh => chargeAh + dischargeAh;
}

/// The ONE Ah integrator behind [foldLifetime] (audit H1). [rows] are
/// change-only interval rows for one metric in start order (non-overlapping,
/// as the store writes them).
///
/// Each row's value is HELD from its start until the NEXT row's start — bounded
/// by [gapMs] past its own end, so a disconnect gap is not bridged — rather than
/// only over `[start, end]`. This matters because a row whose value changed on
/// EVERY sample (real hardware under load, or coalesced notifications) is
/// written with `start == end`: integrating only `end - start` gives it 0 s and
/// under-counts lifetime charge/discharge/EFC badly. The LAST row is held only
/// to its own end (it may still be growing; its hold is picked up next time).
///
/// Only the part strictly after [watermarkMs] counts, so an incremental caller
/// never re-counts history: `effStart = max(start, watermark)`.
CurrentIntegral integrateCurrentRows(
  List<ReadingInterval> rows, {
  int watermarkMs = 0,
  int gapMs = BatteryLogger.gapMs,
  GapPolicy? policy,
}) {
  var charge = 0.0, discharge = 0.0;
  var newest = watermarkMs;
  for (var k = 0; k < rows.length; k++) {
    final iv = rows[k];
    if (iv.endMs > newest) newest = iv.endMs;
    final i = iv.valueNum;
    if (i == null) continue;
    final effStart = iv.startMs > watermarkMs ? iv.startMs : watermarkMs;
    // Hold until the next row starts, but never further than the gap
    // threshold past our own end (offline gap; #53: the threshold in effect
    // for THAT gap when a sample-interval [policy] is given) and — for the
    // last row — never past our own end.
    int holdEnd;
    if (k + 1 < rows.length) {
      final next = rows[k + 1].startMs;
      final bound = iv.endMs + (policy?.gapFor(iv.endMs, next) ?? gapMs);
      holdEnd = next < bound ? next : bound;
    } else {
      holdEnd = iv.endMs;
    }
    final durS = (holdEnd - effStart) / 1000.0;
    if (durS <= 0) continue;
    final ah = i.abs() * durS / 3600.0;
    if (i > 0) {
      charge += ah;
    } else if (i < 0) {
      discharge += ah;
    }
  }
  return CurrentIntegral(
      chargeAh: charge, dischargeAh: discharge, newestEndMs: newest);
}

/// Pure incremental fold (issue #37, unit-tested without a database): given the
/// [prior] persisted totals+watermark and the signed-current interval rows with
/// `end_ms` at or beyond `prior.aggregatedUpToMs` (exactly what the DB query
/// returns), integrate the portion strictly AFTER the watermark and ADD it to
/// the prior totals, advancing the watermark to the newest row's end.
///
/// Integration is [integrateCurrentRows]: each row is HELD until the next
/// row's start (bounded by the gap threshold), `Ah = |current| * held_seconds / 3600`,
/// split into charge (current > 0) and discharge (current < 0). A row whose
/// start predates the watermark (an open interval that merely grew, or the
/// previous fold's last row now followed by a newer one) contributes ONLY its
/// part after the watermark, so already-aggregated history is never re-counted.
/// EFC for the batch = (batch throughput) / [ratedFullAh], added to prior EFC.
LifetimeTotals foldLifetime({
  required LifetimeTotals prior,
  required List<ReadingInterval> newRows,
  required double? ratedFullAh,
  int gapMs = BatteryLogger.gapMs,
  GapPolicy? policy,
}) {
  final wm = prior.aggregatedUpToMs;
  final integral = integrateCurrentRows(newRows,
      watermarkMs: wm, gapMs: gapMs, policy: policy);
  final deltaCharge = integral.chargeAh, deltaDischarge = integral.dischargeAh;
  final deltaEfc = (ratedFullAh != null && ratedFullAh > 0)
      ? (deltaCharge + deltaDischarge) / ratedFullAh
      : 0.0;
  return LifetimeTotals(
    chargeAh: prior.chargeAh + deltaCharge,
    dischargeAh: prior.dischargeAh + deltaDischarge,
    efc: prior.efc + deltaEfc,
    aggregatedUpToMs: integral.newestEndMs,
  );
}

// ---------------------------------------------------------------------------
// The SQLite-backed logger. One instance per app; wires to each connection.
// ---------------------------------------------------------------------------

/// Handle returned by [BatteryLogger.attach] (M11): cancelling it detaches the
/// logger's two stream subscriptions for that connection. Stored on the
/// [BatteryConnection] as [BatteryConnection.loggerAttachment] and cancelled by
/// its `dispose()`, so the logger's subscription set can no longer grow across
/// demo/live toggles or un-star.
class LoggerAttachment implements ConnectionAttachment {
  final BatteryLogger _logger;
  final List<StreamSubscription<dynamic>> _subs;
  bool _cancelled = false;

  LoggerAttachment._(this._logger, this._subs);

  bool get isCancelled => _cancelled;

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _logger._attachments.remove(this);
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// A typed opener so tests can inject a database (or a failing one).
typedef DatabaseOpener = Future<Database> Function(
    String path, OpenDatabaseOptions options);

class BatteryLogger {
  /// App-wide singleton so any screen (charts) can query the same store.
  static final BatteryLogger instance = BatteryLogger._();
  BatteryLogger._()
      : _opener = null,
        _path = null,
        reopenBackoff = defaultReopenBackoff;

  /// Test constructor: an explicit database [path] (e.g. a temp file or
  /// `inMemoryDatabasePath`), an optional [opener] (defaults to the global
  /// `databaseFactory`) and an optional retry backoff.
  @visibleForTesting
  BatteryLogger.custom({
    String? path,
    DatabaseOpener? opener,
    this.reopenBackoff = defaultReopenBackoff,
  })  : _opener = opener,
        _path = path;

  final DatabaseOpener? _opener;
  final String? _path;

  // New filename for the date-and-time interval schema, so an existing device
  // with the older epoch-ms `battery_history.db` gets the new schema cleanly via
  // onCreate. The old file is left in place (never deleted), just unused.
  static const _dbName = 'battery_intervals.db';
  static const _kReadings = 'readings';

  /// Schema version. v3 (review pass C1, H2) adds the epoch-ms columns.
  static const int schemaVersion = 3;

  /// Checkpointed per-battery lifetime totals (issue #37). One row per serial;
  /// updated incrementally from `readings` and never a source of truth for the
  /// raw history (which is read-only to the aggregation).
  static const _kLifetime = 'lifetime_totals';

  /// Gap threshold: readings more than this apart break the run.
  static const int gapMs = 10 * 1000;

  /// How often the advancing `end_time` of an unchanged, open interval is
  /// flushed to SQLite. Value CHANGES are written immediately, not batched.
  static const int flushIntervalMs = 60 * 1000;

  /// Format epoch-ms as full local date-and-time text `yyyy-MM-dd HH:mm:ss.SSS`
  /// (the human-readable timestamp form; all logic uses the epoch-ms columns).
  /// The shared [fmtStampMs] — the same stamp the raw log and diagnostics use.
  static String fmtTime(int ms) => fmtStampMs(ms);

  /// Inverse of [fmtTime]: parse the stored local date-and-time text to
  /// epoch-ms. Since v3 this is only used by the ONE-OFF backfill of the
  /// `*_ms` columns (and as a fallback for a row whose ms is missing): a local
  /// time inside a repeated DST hour is ambiguous, which is exactly why the
  /// live writer now stores the true epoch-ms alongside the text.
  static int parseTime(String s) => DateTime.parse(s).millisecondsSinceEpoch;

  /// Rolling in-memory window kept at full resolution for live graphing.
  static const int hourMs = 60 * 60 * 1000;
  static const int _bufferCapPerMetric = 8000;

  /// #53: the background sample interval in effect (ms; 0 = continuous),
  /// set by the manager when it enters / leaves sampling mode. It widens the
  /// gap rule to [currentGapMs] — so a same-value reading one interval later
  /// EXTENDS the open interval rather than opening a new row — and tags every
  /// reading with the additive [Metric.sampleMode] / [Metric.sampleIntervalS]
  /// metrics the charts use to style and to bridge the expected gaps.
  int sampleIntervalMs = 0;

  /// The gap threshold in effect: 10 s continuous, interval + margin sampling.
  int get currentGapMs => sampleGapMs(sampleIntervalMs, baseGapMs: gapMs);

  IntervalRule get _rule => IntervalRule(gapMs: currentGapMs);

  Database? _db;
  bool _disposed = false;
  int _nextId = 1;
  Timer? _flushTimer;

  // key = '$serial|$metric'
  final Map<String, _Open> _open = {};
  final Map<String, _HourBuffer> _buffer = {};
  final Set<LoggerAttachment> _attachments = {};

  /// How many connections are currently attached (M11 — must not grow across
  /// demo/live toggles).
  int get attachmentCount => _attachments.length;

  /// True while the durable store is open and usable. False before [init], if
  /// SQLite failed to open, and after [dispose] (M5) — callers on a timer
  /// (the lifetime-totals refresh) check this and skip their DB I/O.
  bool get enabled => _db != null && !_disposed;

  /// The open database, for tests that need to break it (close it under the
  /// logger) or inspect rows. Null when not open.
  @visibleForTesting
  Database? get debugDb => _db;

  // --- DB health: consecutive-failure counting + retry (M7 / L18) ----------

  /// Consecutive failed DB operations (opens or writes). Reset on any success.
  int _consecutiveFailures = 0;
  int get consecutiveFailures => _consecutiveFailures;

  /// After this many consecutive failures the store is flagged [dbDegraded],
  /// its handle is dropped and a re-open is scheduled after [reopenBackoff].
  static const int degradedThreshold = 5;

  /// The last DB error seen (open or write), or null once an operation
  /// succeeds. Shown in Settings/Diagnostics as "Logging is failing: …".
  String? lastDbError;

  /// True once [degradedThreshold] consecutive DB operations have failed and
  /// until a DB operation (the backed-off re-open, or a write) succeeds
  /// again (M7).
  bool get dbDegraded => _degraded;
  bool _degraded = false;

  /// Backoff before an open is retried after a failure (L18): starts here and
  /// doubles per consecutive failed open, up to [maxReopenBackoff].
  final Duration reopenBackoff;
  static const Duration defaultReopenBackoff = Duration(seconds: 5);
  static const Duration maxReopenBackoff = Duration(minutes: 5);
  Duration _currentBackoff = Duration.zero;
  int _nextOpenAttemptMs = 0;
  bool _opening = false;

  /// Epoch-ms before which no re-open is attempted (tests).
  int get nextOpenAttemptMs => _nextOpenAttemptMs;

  static const _source = 'BatteryLogger';

  void _noteFailure(String what, Object e) {
    _consecutiveFailures++;
    lastDbError = '$e';
    AppLog.instance.record(_source, '$what: $e');
    if (_consecutiveFailures >= degradedThreshold && !_degraded) {
      _degraded = true;
      AppLog.instance.record(_source,
          'logging degraded after $_consecutiveFailures consecutive failures; '
          'will retry after ${_backoffForNextAttempt().inSeconds} s');
    }
  }

  void _noteSuccess() {
    if (_consecutiveFailures == 0 && !_degraded) return;
    if (_degraded) {
      AppLog.instance.record(_source, 'logging recovered');
    }
    _consecutiveFailures = 0;
    _degraded = false;
    lastDbError = null;
    _currentBackoff = Duration.zero;
  }

  Duration _backoffForNextAttempt() {
    if (_currentBackoff == Duration.zero) return reopenBackoff;
    final next = _currentBackoff * 2;
    return next > maxReopenBackoff ? maxReopenBackoff : next;
  }

  void _armReopen() {
    _currentBackoff = _backoffForNextAttempt();
    _nextOpenAttemptMs =
        DateTime.now().millisecondsSinceEpoch + _currentBackoff.inMilliseconds;
  }

  // --- serialized DB write queue (keeps insert/update ordering) -------------

  Future<void> _dbChain = Future<void>.value();
  void _enqueue(String what, Future<void> Function(Database db) op) {
    final db = _db;
    if (db == null) return;
    _dbChain = _dbChain.then((_) async {
      // Skip a write whose handle was dropped for retry while it was queued.
      // On dispose the captured handle is still open until the chain drains,
      // so the final flush lands.
      if (_db != db && !_disposed) return;
      try {
        await op(db);
        _noteSuccess();
      } catch (e) {
        _noteFailure(what, e);
        if (_degraded) await _dropForRetry();
      }
    });
  }

  /// M7: after [degradedThreshold] consecutive write failures the handle is
  /// assumed dead (closed underneath us, disk full, corrupt file): close it
  /// best-effort, forget the open intervals (they would be extended on a row
  /// that may never have landed) and arm a backed-off re-open. Until then the
  /// in-memory hour keeps the live charts going.
  Future<void> _dropForRetry() async {
    final db = _db;
    if (db == null) return;
    _db = null;
    _open.clear();
    _armReopen();
    await guard<void>('close degraded db', db.close, source: _source);
  }

  /// Open (or create) the database. Safe to call more than once. On failure the
  /// error is recorded, a backed-off retry is armed (L18 — no longer a
  /// permanent disable after ONE transient failure) and only the in-memory
  /// hour (live charts) remains meanwhile, so the app keeps running on a
  /// device without SQLite.
  Future<void> init() async {
    if (_db != null || _disposed || _opening) return;
    _initRequested = true;
    _opening = true;
    try {
      final path = _path ?? p.join(await getDatabasesPath(), _dbName);
      final options = OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
      final db = await (_opener != null
          ? _opener(path, options)
          : databaseFactory.openDatabase(path, options: options));
      final maxRow = await db.rawQuery('SELECT MAX(id) AS m FROM $_kReadings');
      final maxId = (maxRow.first['m'] as num?)?.toInt() ?? 0;
      _nextId = maxId + 1;
      if (_disposed) {
        await db.close();
        return;
      }
      _db = db;
      _noteSuccess();
      _flushTimer ??= Timer.periodic(
          const Duration(milliseconds: flushIntervalMs), (_) => _flushOpens());
    } catch (e) {
      _noteFailure('open database', e);
      _armReopen();
      _db = null;
    } finally {
      _opening = false;
    }
  }

  /// Retry the open once the backoff has elapsed (called from the write path
  /// while the store is closed, so a failed device eventually recovers without
  /// anyone polling). Cheap when not due.
  void _maybeReopen() {
    if (_db != null || _disposed || _opening || !_initRequested) return;
    if (DateTime.now().millisecondsSinceEpoch < _nextOpenAttemptMs) return;
    unawaited(init());
  }

  /// Only a store whose [init] was requested at least once retries; a logger
  /// nobody opened (tests, in-memory-only use) stays memory-only.
  bool _initRequested = false;

  // --- schema --------------------------------------------------------------

  static Future<void> _onCreate(Database db, int version) async {
    // Timestamps are stored TWICE: as full local date-and-time text with
    // millisecond precision (`yyyy-MM-dd HH:mm:ss.SSS`, human-readable and
    // byte-compatible with the text log and the Python interval store) AND as
    // epoch-ms (`start_ms` / `end_ms`, v3) which every query, ORDER BY, window
    // filter, watermark comparison and duration calculation uses. Text sorts
    // wrongly across a DST fall-back (the repeated 02:00-03:00 hour) or a
    // timezone change; epoch-ms never does.
    //
    // DIVERGENCE NOTE: the frozen Python store (python_ble/) keeps text-only
    // columns; its files are NOT shared with this DB, so nothing breaks.
    await db.execute('CREATE TABLE $_kReadings ('
        ' id INTEGER PRIMARY KEY,'
        ' serial TEXT NOT NULL,'
        ' metric TEXT NOT NULL,'
        ' value_num REAL,'
        ' value_text TEXT,'
        ' start_time TEXT NOT NULL,'
        ' end_time TEXT NOT NULL,'
        ' start_ms INTEGER,'
        ' end_ms INTEGER)');
    await db.execute('CREATE INDEX ix_readings ON $_kReadings '
        '(serial, metric, start_time)');
    await _createMsIndex(db);
    await _createFlagsView(db);
    await _createLifetimeTable(db);
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    // v1 -> v2 (#37): add the checkpointed lifetime-totals table. Existing
    // `readings` history is untouched; first aggregation backfills totals.
    if (oldV < 2) await _createLifetimeTable(db);
    // v2 -> v3 (H2): add the epoch-ms columns + index and BACKFILL them ONCE by
    // parsing the existing text columns. The text columns are kept as they are.
    if (oldV < 3) await migrateToV3(db);
  }

  static Future<void> _createMsIndex(Database db) => db.execute(
      'CREATE INDEX IF NOT EXISTS ix_readings_ms ON $_kReadings '
      '(serial, metric, start_ms)');

  static Future<void> _createFlagsView(Database db) =>
      // Convenience view so per-state queries stay plain (no bit-unpacking
      // in queries). Mirrors the Python store's `flags_bits` view exactly.
      db.execute('CREATE VIEW IF NOT EXISTS flags_bits AS SELECT '
          'serial, start_time, end_time,'
          ' (CAST(value_num AS INTEGER) >> 0) & 1 AS mos,'
          ' (CAST(value_num AS INTEGER) >> 1) & 1 AS load,'
          ' (CAST(value_num AS INTEGER) >> 2) & 1 AS charger,'
          ' (CAST(value_num AS INTEGER) >> 3) & 1 AS chgMos,'
          ' (CAST(value_num AS INTEGER) >> 4) & 1 AS disMos,'
          ' (CAST(value_num AS INTEGER) >> 5) & 1 AS passiveBal,'
          ' (CAST(value_num AS INTEGER) >> 6) & 1 AS sleep,'
          ' (CAST(value_num AS INTEGER) >> 7) & 1 AS faultCurrent,'
          ' (CAST(value_num AS INTEGER) >> 8) & 1 AS faultVoltage,'
          ' (CAST(value_num AS INTEGER) >> 9) & 1 AS faultTemperature,'
          ' (CAST(value_num AS INTEGER) >> 10) & 3 AS chargeState'
          ' FROM $_kReadings WHERE metric = \'flags\'');

  /// The lifetime table in its v3 shape (text watermark + its epoch-ms twin).
  /// A v2 table created by an earlier build gets the ms column from
  /// [migrateToV3].
  static Future<void> _createLifetimeTable(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS $_kLifetime ('
        ' serial TEXT PRIMARY KEY,'
        ' total_charge_ah REAL NOT NULL DEFAULT 0,'
        ' total_discharge_ah REAL NOT NULL DEFAULT 0,'
        ' total_efc REAL NOT NULL DEFAULT 0,'
        ' aggregated_up_to TEXT,'
        ' aggregated_up_to_ms INTEGER)');
  }

  /// The v2 -> v3 migration (H2), exposed for the migration test. Adds
  /// `start_ms` / `end_ms` to `readings` and `aggregated_up_to_ms` to
  /// `lifetime_totals`, then backfills every existing row by parsing its text
  /// timestamp ONCE (in batches, inside the upgrade transaction). A row whose
  /// text cannot be parsed is left NULL (it is recorded) and falls back to a
  /// parse at read time.
  static Future<void> migrateToV3(DatabaseExecutor db) async {
    final cols = await db.rawQuery('PRAGMA table_info($_kReadings)');
    final names = {for (final c in cols) c['name'] as String};
    if (!names.contains('start_ms')) {
      await db.execute('ALTER TABLE $_kReadings ADD COLUMN start_ms INTEGER');
    }
    if (!names.contains('end_ms')) {
      await db.execute('ALTER TABLE $_kReadings ADD COLUMN end_ms INTEGER');
    }
    await db.execute('CREATE INDEX IF NOT EXISTS ix_readings_ms ON $_kReadings '
        '(serial, metric, start_ms)');

    // Backfill readings in id batches so a large history never materialises
    // in memory at once.
    const batchSize = 2000;
    var lastId = 0;
    var unparsable = 0;
    while (true) {
      final rows = await db.query(
        _kReadings,
        columns: ['id', 'start_time', 'end_time'],
        where: 'id > ? AND (start_ms IS NULL OR end_ms IS NULL)',
        whereArgs: [lastId],
        orderBy: 'id ASC',
        limit: batchSize,
      );
      if (rows.isEmpty) break;
      final batch = db.batch();
      for (final r in rows) {
        final id = r['id'] as int;
        lastId = id;
        final s = _tryParse(r['start_time'] as String?);
        final e = _tryParse(r['end_time'] as String?);
        if (s == null || e == null) {
          unparsable++;
          continue;
        }
        batch.update(_kReadings, {'start_ms': s, 'end_ms': e},
            where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
      if (rows.length < batchSize) break;
    }
    if (unparsable > 0) {
      AppLog.instance.record(
          _source, 'v3 backfill: $unparsable rows had unparsable timestamps');
    }

    // lifetime_totals: add + backfill the watermark's ms twin.
    final ltCols = await db.rawQuery('PRAGMA table_info($_kLifetime)');
    if (ltCols.isNotEmpty) {
      if (!ltCols.any((c) => c['name'] == 'aggregated_up_to_ms')) {
        await db.execute(
            'ALTER TABLE $_kLifetime ADD COLUMN aggregated_up_to_ms INTEGER');
      }
      final lts = await db.query(_kLifetime,
          columns: ['serial', 'aggregated_up_to'],
          where: 'aggregated_up_to_ms IS NULL');
      for (final r in lts) {
        final ms = _tryParse(r['aggregated_up_to'] as String?);
        if (ms == null) continue;
        await db.update(_kLifetime, {'aggregated_up_to_ms': ms},
            where: 'serial = ?', whereArgs: [r['serial']]);
      }
    }
  }

  static int? _tryParse(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return parseTime(s);
    } catch (_) {
      return null; // counted by the caller
    }
  }

  /// Row -> [ReadingInterval]: the `*_ms` columns are authoritative; a NULL
  /// (a row the backfill could not parse) falls back to parsing the text.
  static ReadingInterval _rowToInterval(Map<String, Object?> r,
      {String? serial, String? metric}) {
    final sMs = (r['start_ms'] as num?)?.toInt() ??
        parseTime(r['start_time'] as String);
    final eMs =
        (r['end_ms'] as num?)?.toInt() ?? parseTime(r['end_time'] as String);
    return ReadingInterval(
      serial: serial ?? r['serial'] as String,
      metric: metric ?? r['metric'] as String,
      valueNum: (r['value_num'] as num?)?.toDouble(),
      valueText: r['value_text'] as String?,
      startMs: sMs,
      endMs: eMs,
    );
  }

  // --- attach ---------------------------------------------------------------

  /// Subscribe to a connection's events (telemetry) and connection-state
  /// (finalize on disconnect). Returns a [LoggerAttachment] (M11) that is also
  /// stored on the connection as [BatteryConnection.loggerAttachment] — its
  /// `dispose()` cancels it. Attaching a connection that already has a live
  /// attachment replaces it (the old one is cancelled), so the logger's
  /// subscription set is bounded by the number of live connections.
  LoggerAttachment attach(BatteryConnection conn) {
    final previous = conn.loggerAttachment;
    if (previous != null) unawaited(previous.cancel());
    final subs = <StreamSubscription<dynamic>>[
      conn.events.listen((_) => _onEvent(conn)),
      conn.connection.listen((cs) {
        if (cs == ConnState.disconnected) {
          final serial = conn.state.serial;
          if (serial != null && serial.isNotEmpty) _onDisconnect(serial);
        }
      }),
    ];
    final handle = LoggerAttachment._(this, subs);
    _attachments.add(handle);
    conn.loggerAttachment = handle;
    return handle;
  }

  /// Test hook: fold the connection's CURRENT state into the store as if an
  /// event had just arrived at [nowMs].
  @visibleForTesting
  void observeConnection(BatteryConnection conn, {int? nowMs}) =>
      _onEvent(conn, nowMs: nowMs);

  void _onEvent(BatteryConnection conn, {int? nowMs}) {
    final serial = conn.state.serial;
    if (serial == null || serial.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final s = conn.state;

    // Per-cell voltages (volts) — EVERY cell present (M14): the VOL frame is
    // count-prefixed, so a bigger pack simply logs more `cellN` metrics.
    for (var i = 0; i < s.cellsMv.length; i++) {
      _num(serial, Metric.cell(i), now, s.cellsMv[i] / 1000.0);
    }

    // Every catalogued metric (metrics.dart): each row's extractor says what
    // to log right now (null = nothing this event). Adding a metric is adding
    // one row to the table — nothing to touch here.
    for (final m in loggedMetrics) {
      final extract = m.extract;
      if (extract != null) {
        _num(serial, m.key, now, extract(conn)?.toDouble());
      } else {
        _text(serial, m.key, now, m.extractText!(conn));
      }
    }

    // Unknown frame bytes: each captured as its own additive metric. Constant
    // on current hardware; a change is genuine new information (and alerts).
    s.unknownBytes.forEach((name, value) {
      _num(serial, name, now, value.toDouble());
    });

    // Booleans + fault-category flags + 2-bit chargeState packed into one
    // integer metric (same LSB-first layout AND the same gating as the Python
    // store, M8): only written once EVERY contributing state is known, so a 0
    // bit always means "off", never "not yet known".
    final flags = packFlags(s);
    if (flags != null) _num(serial, Metric.flags, now, flags.toDouble());

    // #53: additive sample-mode markers — 0/1 and the interval in seconds —
    // so the charts can tell a background sample from continuous data and
    // bridge the expected gap between samples.
    _num(serial, Metric.sampleMode, now, sampleIntervalMs > 0 ? 1 : 0);
    _num(serial, Metric.sampleIntervalS, now, (sampleIntervalMs ~/ 1000).toDouble());
  }

  // --- typed observe helpers ------------------------------------------------

  void _num(String serial, String metric, int now, double? v) {
    if (v == null) return;
    _observe(serial, metric, now, valueNum: v);
  }

  void _text(String serial, String metric, int now, String? v) {
    if (v == null || v.isEmpty) return;
    _observe(serial, metric, now, valueText: v);
  }

  // --- core interval logic --------------------------------------------------

  void _observe(String serial, String metric, int now,
      {num? valueNum, String? valueText}) {
    // 1) Always feed the rolling in-memory hour (drives live/high-res charts,
    //    and works even if the DB is disabled).
    _pushBuffer(serial, metric, now, valueNum?.toDouble(), valueText);

    // 2) Durable interval store (skipped while SQLite is unavailable — but a
    //    closed store re-tries its open once the backoff has elapsed, L18).
    if (_db == null) {
      _maybeReopen();
      return;
    }
    final key = '$serial|$metric';
    final open = _open[key];
    final action = _rule.decide(
      hasOpen: open != null,
      openNum: open?.valueNum,
      openText: open?.valueText,
      openEndMs: open?.endMs ?? 0,
      newNum: valueNum,
      newText: valueText,
      nowMs: now,
    );
    switch (action) {
      case IntervalAction.extend:
        // Advance in memory only; the DB end_time is batched to ~60 s.
        open!.endMs = now;
      case IntervalAction.closeAndOpen:
        _finalize(open!); // write its final end_time if it advanced
        _openNew(key, serial, metric, now, valueNum?.toDouble(), valueText);
      case IntervalAction.openNew:
        _openNew(key, serial, metric, now, valueNum?.toDouble(), valueText);
    }
  }

  void _openNew(String key, String serial, String metric, int now,
      double? valueNum, String? valueText) {
    final id = _nextId++;
    final open = _Open(
      id: id,
      serial: serial,
      metric: metric,
      valueNum: valueNum,
      valueText: valueText,
      startMs: now,
    );
    _open[key] = open;
    final ts = fmtTime(now);
    // A value change is persisted immediately as a fresh row. Both timestamp
    // forms are written: text for readability, epoch-ms for every query.
    _enqueue(
        'insert $metric',
        (db) => db.insert(_kReadings, {
              'id': id,
              'serial': serial,
              'metric': metric,
              'value_num': valueNum,
              'value_text': valueText,
              'start_time': ts,
              'end_time': ts,
              'start_ms': now,
              'end_ms': now,
            }));
  }

  /// Push the open interval's advanced end to the DB (no-op if unchanged).
  void _finalize(_Open open) {
    if (open.endMs <= open.flushedEndMs) return;
    final id = open.id;
    final end = open.endMs;
    open.flushedEndMs = end;
    _enqueue(
        'update end ${open.metric}',
        (db) => db.update(
            _kReadings, {'end_time': fmtTime(end), 'end_ms': end},
            where: 'id = ?', whereArgs: [id]));
  }

  /// Periodic batched flush of every open interval's end_ms (~once per minute).
  void _flushOpens() {
    for (final open in _open.values) {
      _finalize(open);
    }
  }

  /// Finalize and close every open interval for a serial when it disconnects,
  /// so the next reading starts a fresh row (preserving the offline gap).
  void _onDisconnect(String serial) {
    final prefix = '$serial|';
    final keys = _open.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in keys) {
      _finalize(_open[k]!);
      _open.remove(k);
    }
  }

  /// Flush everything immediately (call on app pause / dispose).
  void flushAll() => _flushOpens();

  /// Wait for every queued write to land (tests).
  @visibleForTesting
  Future<void> drain() => _dbChain;

  // --- rolling in-memory hour ----------------------------------------------

  void _pushBuffer(
      String serial, String metric, int now, double? value, String? text) {
    final key = '$serial|$metric';
    _buffer.putIfAbsent(key, _HourBuffer.new).push(now, value, text, _rule,
        cutoffMs: now - hourMs, cap: _bufferCapPerMetric);
  }

  /// The last-hour readings run-length-encoded into intervals (same
  /// change/extend/gap rules as the DB — the fold is maintained incrementally
  /// on each push, L8). Synchronous — reads memory only. The returned list is
  /// immutable and keeps its identity until the next reading for that metric,
  /// so callers can skip work when nothing changed.
  List<ReadingInterval> hourSegments(String serial, String metric) {
    final buf = _buffer['$serial|$metric'];
    if (buf == null || buf.segs.isEmpty) return const [];
    return buf.intervals(serial, metric);
  }

  // --- queries for the charts screen ---------------------------------------

  /// Durable interval rows for [serial]/[metric] overlapping [sinceMs..now],
  /// oldest first — ordered by the epoch-ms column (v3), with the row id as a
  /// tie-break, never by the local-time text.
  Future<List<ReadingInterval>> intervals(String serial, String metric,
      {int sinceMs = 0}) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query(
      _kReadings,
      where: 'serial = ? AND metric = ? AND end_ms >= ?',
      whereArgs: [serial, metric, sinceMs],
      orderBy: 'start_ms ASC, id ASC',
    );
    return [for (final r in rows) _rowToInterval(r)];
  }

  /// Every `cellN` metric ever logged for [serial] (DB rows plus the in-memory
  /// hour), sorted numerically — so the charts draw N cells, not a fixed four
  /// (M14).
  Future<List<String>> cellMetrics(String serial) async {
    final found = <String>{};
    final db = _db;
    if (db != null) {
      final rows = await db.rawQuery(
          'SELECT DISTINCT metric FROM $_kReadings '
          "WHERE serial = ? AND metric GLOB 'cell[0-9]*'",
          [serial]);
      for (final r in rows) {
        final m = r['metric'] as String;
        if (Metric.cellIndex(m) != null) found.add(m);
      }
    }
    final prefix = '$serial|';
    for (final key in _buffer.keys) {
      if (!key.startsWith(prefix)) continue;
      final m = key.substring(prefix.length);
      if (Metric.cellIndex(m) != null) found.add(m);
    }
    return found.toList()..sort(Metric.compareCells);
  }

  /// Merge durable intervals with the live in-memory tail for one metric. The
  /// DB supplies the body; the in-memory hour extends the currently-open
  /// interval up to `now` (the part not yet flushed to SQLite).
  Future<List<ReadingInterval>> mergedSeries(String serial, String metric,
      {int sinceMs = 0}) async {
    final db = await intervals(serial, metric, sinceMs: sinceMs);
    return spliceTail(db, hourSegments(serial, metric), sinceMs: sinceMs);
  }

  /// #53: the `sampleIntervalS` rows that decide the gap threshold from
  /// [sinceMs] on — every row overlapping the window PLUS the latest row that
  /// started before it (its value holds until the next row starts), in start
  /// order. Feed to [GapPolicy].
  Future<List<ReadingInterval>> sampleIntervalRows(String serial,
      {int sinceMs = 0}) async {
    final db = _db;
    if (db == null) return hourSegments(serial, Metric.sampleIntervalS);
    final rows = await intervals(serial, Metric.sampleIntervalS, sinceMs: sinceMs);
    final before = await db.query(
      _kReadings,
      where: 'serial = ? AND metric = ? AND start_ms < ?',
      whereArgs: [serial, Metric.sampleIntervalS, sinceMs],
      orderBy: 'start_ms DESC, id DESC',
      limit: 1,
    );
    final body = [
      for (final r in before) _rowToInterval(r),
      ...rows,
    ];
    return spliceTail(body, hourSegments(serial, Metric.sampleIntervalS),
        sinceMs: sinceMs);
  }

  /// Durable DB rows only (no live tail) for several metrics at once, keyed by
  /// metric. The charts page keeps this body and re-splices the in-memory tail
  /// onto it every tick with [spliceTail].
  Future<Map<String, List<ReadingInterval>>> multiIntervals(
      String serial, List<String> metrics,
      {int sinceMs = 0}) async {
    final out = <String, List<ReadingInterval>>{};
    for (final m in metrics) {
      out[m] = await intervals(serial, m, sinceMs: sinceMs);
    }
    return out;
  }

  /// Fetch several metrics' merged interval series at once (keyed by metric).
  Future<Map<String, List<ReadingInterval>>> multiSeries(
      String serial, List<String> metrics,
      {int sinceMs = 0}) async {
    final out = <String, List<ReadingInterval>>{};
    for (final m in metrics) {
      out[m] = await mergedSeries(serial, m, sinceMs: sinceMs);
    }
    return out;
  }

  /// Active-fault windows in [sinceMs..now], decoded from the `flags` metric's
  /// fault-category bits, as (label, start, end) for the timeline's text list.
  Future<List<({String label, int startMs, int endMs})>> activeFaults(
      String serial,
      {int sinceMs = 0}) async {
    final ivs = await mergedSeries(serial, Metric.flags, sinceMs: sinceMs);
    final out = <({String label, int startMs, int endMs})>[];
    for (final iv in ivs) {
      final f = (iv.valueNum ?? 0).toInt();
      if (!Flags.faultActive(f)) continue;
      out.add((
        label: '${Flags.faultCategories(f).join(', ')} alarm',
        startMs: iv.startMs,
        endMs: iv.endMs,
      ));
    }
    return out;
  }

  // --- checkpointed lifetime totals (issue #37) -----------------------------
  // (The legacy whole-history `aggregateTotals` rescan was removed in review
  // pass B, L5 — the displayed figures come only from the checkpointed path.)

  /// The persisted lifetime-totals record for [serial], or an empty record
  /// (watermark 0) when none exists yet (first run). The watermark is read
  /// from `aggregated_up_to_ms` (v3); the text twin is only a fallback.
  Future<LifetimeTotals> lifetimeTotals(String serial) async {
    final db = _db;
    if (db == null) return const LifetimeTotals();
    final rows = await db.query(_kLifetime,
        where: 'serial = ?', whereArgs: [serial], limit: 1);
    if (rows.isEmpty) return const LifetimeTotals();
    final r = rows.first;
    var upToMs = (r['aggregated_up_to_ms'] as num?)?.toInt();
    if (upToMs == null) {
      final upTo = r['aggregated_up_to'] as String?;
      upToMs = (upTo == null || upTo.isEmpty) ? 0 : parseTime(upTo);
    }
    return LifetimeTotals(
      chargeAh: (r['total_charge_ah'] as num?)?.toDouble() ?? 0,
      dischargeAh: (r['total_discharge_ah'] as num?)?.toDouble() ?? 0,
      efc: (r['total_efc'] as num?)?.toDouble() ?? 0,
      aggregatedUpToMs: upToMs,
    );
  }

  /// Incrementally extend the persisted lifetime totals for [serial]: fold ONLY
  /// the `readings` rows for [Metric.packCurrent] newer than the stored
  /// watermark into the running totals, advance the watermark, and persist.
  ///
  /// Cost is O(new rows) — already-aggregated history is never re-scanned, and
  /// `readings` rows are read-only (never mutated or deleted). On first run
  /// (no record) it folds from the very beginning once, then stays incremental
  /// across app restarts (the watermark persists). Returns the updated record.
  Future<LifetimeTotals> updateLifetimeTotals(String serial) async {
    final db = _db;
    if (db == null) return const LifetimeTotals();
    final prior = await lifetimeTotals(serial);
    // Watermark compare on epoch-ms (v3). A watermark of 0 predates any real
    // reading, so a fresh record scans everything.
    // `>=` (not `>`): the previous fold's LAST row ends exactly at the watermark
    // and was held only to its own end; it must be re-fetched so its hold up to
    // the row that followed it is counted now (H1). Its part before the
    // watermark is excluded by the fold, so nothing is double-counted.
    final rows = await db.query(
      _kReadings,
      columns: ['value_num', 'start_time', 'end_time', 'start_ms', 'end_ms'],
      where: 'serial = ? AND metric = ? AND end_ms >= ?',
      whereArgs: [serial, Metric.packCurrent, prior.aggregatedUpToMs],
      orderBy: 'start_ms ASC, id ASC',
    );
    if (rows.isEmpty) return prior;
    final newRows = [
      for (final r in rows)
        _rowToInterval(r, serial: serial, metric: Metric.packCurrent)
    ];
    final full = await _latestFullAh(serial);
    // #53: hold each row to the next one across an EXPECTED sampling gap —
    // the threshold in effect at that time, from the sampleIntervalS rows.
    final modeRows =
        await sampleIntervalRows(serial, sinceMs: newRows.first.startMs);
    final policy = GapPolicy(modeRows, baseGapMs: gapMs);
    final updated = foldLifetime(
        prior: prior, newRows: newRows, ratedFullAh: full, policy: policy);
    // Nothing new (only the watermark row itself came back): no write needed.
    if (updated.aggregatedUpToMs == prior.aggregatedUpToMs &&
        updated.chargeAh == prior.chargeAh &&
        updated.dischargeAh == prior.dischargeAh) {
      return prior;
    }
    await db.insert(
      _kLifetime,
      {
        'serial': serial,
        'total_charge_ah': updated.chargeAh,
        'total_discharge_ah': updated.dischargeAh,
        'total_efc': updated.efc,
        'aggregated_up_to': fmtTime(updated.aggregatedUpToMs),
        'aggregated_up_to_ms': updated.aggregatedUpToMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // ignore: avoid_print
    logLine('LIFETIME', 'lifetime totals $serial extended '
        '(${prior.totals.throughputAh.toStringAsFixed(2)}Ah) -> '
        '(${updated.totals.throughputAh.toStringAsFixed(2)}Ah) '
        'over ${newRows.length} new rows');
    return updated;
  }

  /// Latest logged `fullAh` (rated capacity) straight from `readings`, or null.
  /// Read-only single-row lookup — does not pull the in-memory hour.
  Future<double?> _latestFullAh(String serial) async {
    final db = _db;
    if (db == null) return null;
    final rows = await db.query(
      _kReadings,
      columns: ['value_num'],
      where: 'serial = ? AND metric = ? AND value_num IS NOT NULL',
      whereArgs: [serial, Metric.fullAh],
      orderBy: 'end_ms DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['value_num'] as num?)?.toDouble();
  }

  /// Close the store. M5: the disposed flag is raised and the handle detached
  /// FIRST, so a periodic lifetime-totals tick (or any other reader) that
  /// fires while the queued writes drain sees `enabled == false` and skips its
  /// query instead of racing the `close()`. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _flushOpens();
    _flushTimer?.cancel();
    _flushTimer = null;
    for (final a in _attachments.toList()) {
      await a.cancel();
    }
    _attachments.clear();
    final db = _db;
    _db = null; // new callers see the store as closed from here on
    await _dbChain; // let queued writes drain
    await db?.close();
  }
}
