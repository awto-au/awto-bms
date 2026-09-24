/// Data retention (#111): nothing is ever deleted automatically unless the
/// user chose it in Settings → Data.
///
///  * [KeepData]: "Keep data" = All (the default: nothing is deleted) or
///    12 / 6 / 3 months. A period is applied by [RetentionJob] at startup and
///    once a day; with All the job never runs.
///  * [deleteDataBefore] / [deleteAllData]: the one-off deletes.
///
/// What is deleted: `readings` (by `end_ms`), `alarm_events` (by `at_ms`) and
/// rotated raw-log files (by the time they were closed). What is NEVER
/// deleted: lifetime totals, battery names (aliases), the fleet / known
/// batteries and settings. Store deletes go through the [BatteryLogger] write
/// queue, so they cannot race logging. Every deletion is written to the raw
/// log as a `RETENTION` line.
///
/// One shared Dart implementation for the phone and Windows.
library;

import 'dart:async';

import 'battery_log.dart';
import 'fmt.dart' show logLine;
import 'raw_log.dart';

/// The "Keep data" choice. [all] is the default and deletes nothing.
enum KeepData {
  all(0, 'All'),
  months12(12, '12 months'),
  months6(6, '6 months'),
  months3(3, '3 months');

  const KeepData(this.months, this.label);

  /// 0 = keep everything.
  final int months;
  final String label;

  bool get keepsAll => months == 0;

  /// The stored month count back to a choice; anything unknown is [all], so a
  /// damaged setting can never delete data.
  static KeepData fromMonths(int months) =>
      values.firstWhere((k) => k.months == months, orElse: () => all);
}

/// [months] calendar months before [now], the day clamped to the target
/// month's length (31 May − 3 months = 28/29 Feb). Pure.
DateTime monthsBefore(DateTime now, int months) {
  final first = DateTime(now.year, now.month - months); // normalises the year
  final lastDay = DateTime(first.year, first.month + 1, 0).day;
  final day = now.day > lastDay ? lastDay : now.day;
  return DateTime(first.year, first.month, day, now.hour, now.minute,
      now.second, now.millisecond);
}

/// `24 Jun 2026` for dialogs. Pure.
String fmtDay(DateTime t) {
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${t.day} ${m[t.month - 1]} ${t.year}';
}

/// What a deletion removed.
class DataDeletion {
  /// False when the history store was not open or its delete failed.
  final bool storeDone;
  final int readings;
  final int alarmEvents;
  final int logFiles;
  const DataDeletion({
    required this.storeDone,
    required this.readings,
    required this.alarmEvents,
    required this.logFiles,
  });

  /// `Deleted 1204 readings, 3 alarm events and 2 log files`.
  String get summary {
    String n(int v, String one) => '$v $one${v == 1 ? '' : 's'}';
    final text = 'Deleted ${n(readings, 'reading')}, '
        '${n(alarmEvents, 'alarm event')} and ${n(logFiles, 'log file')}';
    return storeDone ? text : '$text (the history store was not available)';
  }
}

/// Delete readings, alarm events and rotated raw logs older than [cutoff].
/// The live raw log, lifetime totals, names, fleet and settings are kept.
Future<DataDeletion> deleteDataBefore(
  DateTime cutoff, {
  BatteryLogger? store,
  RawLogger? raw,
  bool compact = false,
  String why = 'user request',
}) async {
  final s = store ?? BatteryLogger.instance;
  final r = raw ?? RawLogger.instance;
  final h = await s.deleteHistory(
      beforeMs: cutoff.millisecondsSinceEpoch, compact: compact);
  final files = await r.deleteRotatedBefore(cutoff);
  final out = DataDeletion(
    storeDone: h.done,
    readings: h.readings,
    alarmEvents: h.alarmEvents,
    logFiles: files,
  );
  _record(r, '$why: older than ${fmtDay(cutoff)}: ${out.summary}');
  return out;
}

/// Delete every reading, alarm event and raw-log file (the live file is
/// emptied and carries on). Lifetime totals, names, fleet and settings are
/// kept.
Future<DataDeletion> deleteAllData(
    {BatteryLogger? store, RawLogger? raw}) async {
  final s = store ?? BatteryLogger.instance;
  final r = raw ?? RawLogger.instance;
  final h = await s.deleteHistory(compact: true);
  final files = await r.deleteAllFiles();
  final out = DataDeletion(
    storeDone: h.done,
    readings: h.readings,
    alarmEvents: h.alarmEvents,
    logFiles: files,
  );
  _record(r, 'user request: all data: ${out.summary}');
  return out;
}

void _record(RawLogger r, String text) {
  logLine('RETENTION', text);
  r.logEvent('', 'RETENTION', text);
}

/// Bytes on disk: the history store and the raw logs.
class StorageUsed {
  final int dbBytes;
  final int logBytes;
  final int logFiles;
  const StorageUsed(
      {required this.dbBytes, required this.logBytes, required this.logFiles});
  int get totalBytes => dbBytes + logBytes;

  /// `42.1 MB — history 12.0 MB · raw logs 30.1 MB in 2 files`.
  String get line {
    const f = RawLogger.fmtSize;
    return '${f(totalBytes)} — history ${f(dbBytes)} · raw logs '
        '${f(logBytes)} in $logFiles ${logFiles == 1 ? 'file' : 'files'}';
  }
}

Future<StorageUsed> storageUsed({BatteryLogger? store, RawLogger? raw}) async {
  final s = store ?? BatteryLogger.instance;
  final r = raw ?? RawLogger.instance;
  await r.refreshRotatedStats();
  return StorageUsed(
    dbBytes: await s.storageBytes(),
    logBytes: r.totalBytes,
    logFiles: r.rotatedCount + (r.path == null ? 0 : 1),
  );
}

/// Applies the "Keep data" period: once when configured (startup, or the
/// user's confirmed change) and then once a day. With [KeepData.all] there is
/// no timer and nothing runs.
class RetentionJob {
  RetentionJob({this.store, this.raw, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final BatteryLogger? store;
  final RawLogger? raw;
  final DateTime Function() _clock;

  static const Duration period = Duration(days: 1);

  KeepData _keep = KeepData.all;
  Timer? _timer;

  KeepData get keep => _keep;

  /// Whether the daily timer is armed (only for a non-default period).
  bool get scheduled => _timer != null;

  /// Set the period. A non-default period runs now and then daily; All
  /// cancels the timer. Returns the run's result (null for All).
  Future<DataDeletion?> configure(KeepData keep) {
    _keep = keep;
    _timer?.cancel();
    _timer = null;
    if (keep.keepsAll) return Future.value(null);
    _timer = Timer.periodic(period, (_) => unawaited(runOnce()));
    return runOnce();
  }

  /// One pass: delete what is older than the period. Does nothing for All.
  Future<DataDeletion?> runOnce() async {
    final keep = _keep;
    if (keep.keepsAll) return null;
    return deleteDataBefore(monthsBefore(_clock(), keep.months),
        store: store, raw: raw, why: 'keep ${keep.label}');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
