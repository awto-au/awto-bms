/// On-device telemetry logging as an **append-only interval store**.
///
/// The model (agreed with the user) is deliberately lossless — there is NO
/// downsampling, NO heartbeat and NO deletion, ever:
///
///  * **Durable store = one append-only interval table.** A row is one run of a
///    single value for one (serial, metric): it holds from `start_time` to
///    `end_time` (full local date-and-time text, `yyyy-MM-dd HH:mm:ss.SSS`, to
///    match the text log and the Python store; interval arithmetic stays on
///    epoch-ms internally). On each observed reading we either *extend* the
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

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'battery_connection.dart';
import 'battery_protocol.dart';

// ---------------------------------------------------------------------------
// Metric identifiers. One interval run per (serial, metric).
// ---------------------------------------------------------------------------

class Metric {
  // Per-cell voltages, volts.
  static const cell1 = 'cell1';
  static const cell2 = 'cell2';
  static const cell3 = 'cell3';
  static const cell4 = 'cell4';
  static const cells = [cell1, cell2, cell3, cell4];

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
  static const cycleCount = 'cycles';
  static const temp1 = 'temp1'; // deg C
  static const temp2 = 'temp2'; // deg C
  static const chipTemp = 'chip'; // deg C
  static const rssi = 'rssi'; // dBm

  // Byte-valued gates: their own numeric metrics (not single bits).
  static const tempControlGate = 'tempGate';
  static const smokeGate = 'smokeGate';
  static const heatGate = 'heatGate';

  static const firmwareVersion = 'firmware'; // string (value_text)

  /// All the boolean states, the three fault-category flags and the 2-bit
  /// chargeState packed LSB-first into one integer metric — the SAME layout the
  /// Python interval store uses, so a `flags` row means the same thing on both
  /// platforms. See [Flags]. Change-only interval row like any other metric.
  static const flags = 'flags';
}

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

// ---------------------------------------------------------------------------
// A finalized (or in-progress) interval. Immutable value type for queries and
// for the pure [buildIntervals] output.
// ---------------------------------------------------------------------------

class ReadingInterval {
  final String serial;
  final String metric;
  final double? valueNum;
  final String? valueText;
  final int startMs;
  final int endMs;

  const ReadingInterval({
    this.serial = '',
    this.metric = '',
    this.valueNum,
    this.valueText,
    required this.startMs,
    required this.endMs,
  });

  @override
  String toString() =>
      'Interval($metric ${valueText ?? valueNum} $startMs..$endMs)';
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

  bool contiguous(int openEndMs, int nowMs) => (nowMs - openEndMs) <= gapMs;

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

// ---------------------------------------------------------------------------
// The SQLite-backed logger. One instance per app; wires to each connection.
// ---------------------------------------------------------------------------

class BatteryLogger {
  /// App-wide singleton so any screen (charts) can query the same store.
  static final BatteryLogger instance = BatteryLogger._();
  BatteryLogger._();

  // New filename for the date-and-time interval schema, so an existing device
  // with the older epoch-ms `battery_history.db` gets the new schema cleanly via
  // onCreate. The old file is left in place (never deleted), just unused.
  static const _dbName = 'battery_intervals.db';
  static const _kReadings = 'readings';

  /// Gap threshold: readings more than this apart break the run.
  static const int gapMs = 10 * 1000;

  /// How often the advancing `end_time` of an unchanged, open interval is
  /// flushed to SQLite. Value CHANGES are written immediately, not batched.
  static const int flushIntervalMs = 60 * 1000;

  /// Format epoch-ms as full local date-and-time text `yyyy-MM-dd HH:mm:ss.SSS`
  /// (the durable timestamp form; interval arithmetic stays on epoch-ms).
  static String fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(d.year, 4)}-${p(d.month)}-${p(d.day)} '
        '${p(d.hour)}:${p(d.minute)}:${p(d.second)}.${p(d.millisecond, 3)}';
  }

  /// Inverse of [fmtTime]: parse the stored local date-and-time text to
  /// epoch-ms for the chart math.
  static int parseTime(String s) => DateTime.parse(s).millisecondsSinceEpoch;

  /// Rolling in-memory window kept at full resolution for live graphing.
  static const int hourMs = 60 * 60 * 1000;
  static const int _bufferCapPerMetric = 8000;

  final IntervalRule _rule = const IntervalRule(gapMs: gapMs);

  Database? _db;
  bool _dbFailed = false;
  int _nextId = 1;
  Timer? _flushTimer;

  // key = '$serial|$metric'
  final Map<String, _Open> _open = {};
  final Map<String, List<_Raw>> _buffer = {};
  final List<StreamSubscription<dynamic>> _subs = [];

  bool get enabled => _db != null && !_dbFailed;

  // --- serialized DB write queue (keeps insert/update ordering) -------------

  Future<void> _dbChain = Future<void>.value();
  void _enqueue(Future<void> Function() op) {
    final db = _db;
    if (db == null) return;
    _dbChain = _dbChain.then((_) => op()).catchError((Object _) {});
  }

  /// Open (or create) the database. Safe to call more than once. On failure the
  /// DB is disabled and only the in-memory hour (live charts) remains, so the
  /// app keeps running on a device without SQLite.
  Future<void> init() async {
    if (_db != null || _dbFailed) return;
    try {
      final dir = await getDatabasesPath();
      _db = await openDatabase(
        p.join(dir, _dbName),
        version: 1,
        onCreate: (db, _) async {
          // Timestamps are stored as full local date-and-time text with
          // millisecond precision (`yyyy-MM-dd HH:mm:ss.SSS`) — zero-padded so
          // lexicographic order matches chronological order — to stay
          // byte-compatible with the text log and the Python interval store.
          await db.execute('CREATE TABLE $_kReadings ('
              ' id INTEGER PRIMARY KEY,'
              ' serial TEXT NOT NULL,'
              ' metric TEXT NOT NULL,'
              ' value_num REAL,'
              ' value_text TEXT,'
              ' start_time TEXT NOT NULL,'
              ' end_time TEXT NOT NULL)');
          await db.execute('CREATE INDEX ix_readings ON $_kReadings '
              '(serial, metric, start_time)');
          // Convenience view so per-state queries stay plain (no bit-unpacking
          // in queries). Mirrors the Python store's `flags_bits` view exactly.
          await db.execute('CREATE VIEW IF NOT EXISTS flags_bits AS SELECT '
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
        },
      );
      final maxRow =
          await _db!.rawQuery('SELECT MAX(id) AS m FROM $_kReadings');
      final maxId = (maxRow.first['m'] as num?)?.toInt() ?? 0;
      _nextId = maxId + 1;
      _flushTimer = Timer.periodic(
          const Duration(milliseconds: flushIntervalMs), (_) => _flushOpens());
    } catch (_) {
      _dbFailed = true;
      _db = null;
    }
  }

  /// Subscribe to a connection's events (telemetry) and connection-state
  /// (finalize on disconnect). Call once per connection.
  void attach(BatteryConnection conn) {
    _subs.add(conn.events.listen((_) => _onEvent(conn)));
    _subs.add(conn.connection.listen((cs) {
      if (cs == ConnState.disconnected) {
        final serial = conn.state.serial;
        if (serial != null && serial.isNotEmpty) _onDisconnect(serial);
      }
    }));
  }

  void _onEvent(BatteryConnection conn) {
    final serial = conn.state.serial;
    if (serial == null || serial.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = conn.state;

    // Per-cell voltages (volts) — only the cells actually present.
    for (var i = 0; i < s.cellsMv.length && i < Metric.cells.length; i++) {
      _num(serial, Metric.cells[i], now, s.cellsMv[i] / 1000.0);
    }
    _num(serial, Metric.packVoltage, now, s.packVoltage);
    _num(serial, Metric.cellSum, now, s.cellSum);
    _num(serial, Metric.cellMax, now, s.cellMax);
    _num(serial, Metric.cellMin, now, s.cellMin);
    _num(serial, Metric.cellAvg, now, s.cellAvg);
    _num(serial, Metric.cellDelta, now, s.cellDiff);
    _num(serial, Metric.packCurrent, now, conn.signedCurrent); // +in / -out
    _num(serial, Metric.power, now, conn.signedPower); // +in / -out
    _num(serial, Metric.soc, now, s.socPercent?.toDouble());
    _num(serial, Metric.remainingAh, now, s.remainingAh);
    _num(serial, Metric.fullAh, now, s.fullAh);
    _num(serial, Metric.cycleCount, now, s.cycleCount?.toDouble());
    _num(serial, Metric.temp1, now, s.temp1?.toDouble());
    _num(serial, Metric.temp2, now, s.temp2?.toDouble());
    _num(serial, Metric.chipTemp, now, s.chipTemperature?.toDouble());
    _num(serial, Metric.rssi, now, s.rssi?.toDouble());

    // Byte-valued gates: their own numeric metrics.
    _num(serial, Metric.tempControlGate, now, s.tempControlGate?.toDouble());
    _num(serial, Metric.smokeGate, now, s.smokeGate?.toDouble());
    _num(serial, Metric.heatGate, now, s.heatGate?.toDouble());
    _text(serial, Metric.firmwareVersion, now, s.firmwareVersion);

    // Booleans + fault-category flags + 2-bit chargeState packed into one
    // integer metric (same LSB-first layout as the Python store). Only written
    // once at least one contributing state is known (a 0 bit means off).
    final flags = _packFlags(s);
    if (flags != null) _num(serial, Metric.flags, now, flags.toDouble());
  }

  /// Pack the boolean/enum state into the shared [Flags] integer, or null while
  /// nothing that contributes is known yet.
  int? _packFlags(BatteryState s) {
    final known = s.mosOn != null ||
        s.loadConnected != null ||
        s.chargerConnected != null ||
        s.chargeMos != null ||
        s.dischargeMos != null ||
        s.passiveBalancing != null ||
        s.sleepModeOn != null ||
        s.chargeState != ChargeState.unknown ||
        s.currentWarnings.isNotEmpty ||
        s.voltageWarnings.isNotEmpty ||
        s.temperatureWarnings.isNotEmpty;
    if (!known) return null;
    var f = 0;
    if (s.mosOn == true) f |= Flags.mos;
    if (s.loadConnected == true) f |= Flags.load;
    if (s.chargerConnected == true) f |= Flags.charger;
    if (s.chargeMos == true) f |= Flags.chgMos;
    if (s.dischargeMos == true) f |= Flags.disMos;
    if (s.passiveBalancing == true) f |= Flags.passiveBal;
    if (s.sleepModeOn == true) f |= Flags.sleep;
    if (s.currentWarnings.isNotEmpty) f |= Flags.faultCurrent;
    if (s.voltageWarnings.isNotEmpty) f |= Flags.faultVoltage;
    if (s.temperatureWarnings.isNotEmpty) f |= Flags.faultTemperature;
    final cs = switch (s.chargeState) {
      ChargeState.charging => 1,
      ChargeState.discharging => 2,
      _ => 0, // idle or unknown -> 0 (2-bit field has no "unknown" code)
    };
    f |= (cs & 0x3) << Flags.chargeStateShift;
    return f;
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

    // 2) Durable interval store (skipped if SQLite is unavailable).
    if (_db == null) return;
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
    // A value change is persisted immediately as a fresh row.
    _enqueue(() => _db!.insert(_kReadings, {
          'id': id,
          'serial': serial,
          'metric': metric,
          'value_num': valueNum,
          'value_text': valueText,
          'start_time': ts,
          'end_time': ts,
        }));
  }

  /// Push the open interval's advanced end_time to the DB (no-op if unchanged).
  void _finalize(_Open open) {
    if (open.endMs <= open.flushedEndMs) return;
    final id = open.id;
    final end = open.endMs;
    open.flushedEndMs = end;
    _enqueue(() => _db!.update(_kReadings, {'end_time': fmtTime(end)},
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

  // --- rolling in-memory hour ----------------------------------------------

  void _pushBuffer(
      String serial, String metric, int now, double? value, String? text) {
    final key = '$serial|$metric';
    final list = _buffer.putIfAbsent(key, () => <_Raw>[]);
    list.add(_Raw(now, value, text));
    final cutoff = now - hourMs;
    var drop = 0;
    while (drop < list.length && list[drop].ms < cutoff) {
      drop++;
    }
    if (drop > 0) list.removeRange(0, drop);
    if (list.length > _bufferCapPerMetric) {
      list.removeRange(0, list.length - _bufferCapPerMetric);
    }
  }

  /// The last-hour raw readings run-length-encoded into intervals (same
  /// change/extend/gap rules as the DB). Synchronous — reads memory only.
  List<ReadingInterval> hourSegments(String serial, String metric) {
    final list = _buffer['$serial|$metric'];
    if (list == null || list.isEmpty) return const [];
    final obs = [for (final r in list) Obs(r.ms, value: r.value, text: r.text)];
    return buildIntervals(obs,
        serial: serial, metric: metric, gapMs: gapMs);
  }

  // --- queries for the charts screen ---------------------------------------

  /// Durable interval rows for [serial]/[metric] overlapping [sinceMs..now],
  /// oldest first.
  Future<List<ReadingInterval>> intervals(String serial, String metric,
      {int sinceMs = 0}) async {
    final db = _db;
    if (db == null) return const [];
    // end_time is zero-padded text, so a lexicographic `>=` is chronological.
    final rows = await db.query(
      _kReadings,
      where: 'serial = ? AND metric = ? AND end_time >= ?',
      whereArgs: [serial, metric, fmtTime(sinceMs)],
      orderBy: 'start_time ASC',
    );
    return [
      for (final r in rows)
        ReadingInterval(
          serial: r['serial'] as String,
          metric: r['metric'] as String,
          valueNum: (r['value_num'] as num?)?.toDouble(),
          valueText: r['value_text'] as String?,
          startMs: parseTime(r['start_time'] as String),
          endMs: parseTime(r['end_time'] as String),
        )
    ];
  }

  /// Merge durable intervals with the live in-memory tail for one metric. The
  /// DB supplies the body; the in-memory hour extends the currently-open
  /// interval up to `now` (the part not yet flushed to SQLite).
  Future<List<ReadingInterval>> mergedSeries(String serial, String metric,
      {int sinceMs = 0}) async {
    final db = await intervals(serial, metric, sinceMs: sinceMs);
    final buf = hourSegments(serial, metric);
    var maxEnd = sinceMs;
    for (final iv in db) {
      if (iv.endMs > maxEnd) maxEnd = iv.endMs;
    }
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
    return [...db, ...tail];
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

  Future<void> dispose() async {
    _flushOpens();
    _flushTimer?.cancel();
    _flushTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _dbChain; // let queued writes drain
    await _db?.close();
    _db = null;
  }
}
