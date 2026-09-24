/// App diagnostics sink (review pass C1, GitHub #51).
///
/// Before this pass the app had 34 `catch (_) {}` / `.catchError((_) {})`
/// sites that swallowed failures SILENTLY: a shared_preferences plugin that
/// failed to load, a BLE disconnect that threw, a raw-log write that failed, a
/// notification the platform refused. Each swallow was intentional (best-effort
/// work must never crash the app) but nothing was ever recorded, so a device
/// that was quietly failing looked exactly like one that was fine.
///
/// [AppLog] is a bounded ring buffer of the last [AppLog.capacity] entries
/// (timestamp + source + message). Every entry is also `print`ed to the console
/// and, when verbose raw logging is on, appended to the raw log through the
/// registered [AppLog.sink] (the raw logger registers itself so this library
/// never imports it). The Settings page's Diagnostics tile shows the entries and
/// lets the user copy them.
///
/// [guard] / [guardSync] wrap a best-effort operation: they keep the SWALLOW
/// semantics (the caller gets [fallback] instead of an exception) but ALWAYS
/// record "what: error" first, so nothing is lost silently any more.
library;

import 'dart:async';
import 'dart:collection';

import 'fmt.dart' as fmt;

/// One recorded diagnostic.
class AppLogEntry {
  final DateTime time;
  final String source;
  final String message;
  const AppLogEntry(this.time, this.source, this.message);

  /// `2026-09-20 14:23:01.123  source  message` — the same timestamp shape as
  /// the raw log and the interval store (the shared [fmt.fmtStamp]).
  String format() => '${fmtStamp(time)}  $source  $message';

  static String fmtStamp(DateTime d) => fmt.fmtStamp(d);

  @override
  String toString() => format();
}

/// Bounded ring buffer of diagnostics. App-wide singleton.
class AppLog {
  static final AppLog instance = AppLog._();
  AppLog._();

  /// How many entries are kept; the oldest is dropped when full.
  static const int capacity = 500;

  final ListQueue<AppLogEntry> _entries = ListQueue<AppLogEntry>();

  /// Total entries ever recorded (including those dropped from the ring).
  int totalRecorded = 0;

  /// Echo every entry to the console (`print`). Tests may turn it off.
  bool echoToConsole = true;

  /// Optional secondary sink, e.g. the raw logger's "DIAG" line writer. Set by
  /// the raw logger on init; invoked for every entry when non-null. A throwing
  /// sink is ignored (diagnostics must never take the app down).
  void Function(AppLogEntry entry)? sink;

  /// Clock, injectable for tests.
  DateTime Function() now = DateTime.now;

  /// Snapshot of the entries, OLDEST first.
  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  /// The most recent [n] entries, NEWEST first (for the Diagnostics page).
  List<AppLogEntry> recent([int n = capacity]) {
    final out = <AppLogEntry>[];
    final it = _entries.toList().reversed.iterator;
    while (out.length < n && it.moveNext()) {
      out.add(it.current);
    }
    return out;
  }

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// Record one diagnostic.
  AppLogEntry record(String source, String message) {
    final e = AppLogEntry(now(), source, message);
    _entries.addLast(e);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    totalRecorded++;
    if (echoToConsole) {
      // ignore: avoid_print
      print('${fmt.fmtStamp(e.time)} [DIAG] ${e.source}: ${e.message}');
    }
    final s = sink;
    if (s != null) {
      try {
        s(e);
      } catch (_) {
        // A failing sink is the ONE place a swallow stays silent: recording the
        // failure would recurse straight back into the sink.
      }
    }
    return e;
  }

  /// Drop every entry (and the running total, so "older dropped" counts from
  /// the clear).
  void clear() {
    _entries.clear();
    totalRecorded = 0;
  }

  /// Every entry as text, OLDEST first, one per line (for "Copy").
  String dump() => _entries.map((e) => e.format()).join('\n');
}

/// Run a best-effort async operation. Applies [timeout] when given, catches
/// EVERYTHING, records `"$what: <error>"` under [source] in [AppLog] and returns
/// [fallback]. The swallow semantics of the old `catch (_) {}` sites are kept
/// exactly — only the silence is gone. Never throws.
Future<T?> guard<T>(
  String what,
  Future<T> Function() op, {
  T? fallback,
  Duration? timeout,
  String source = 'app',
}) async {
  try {
    var f = op();
    if (timeout != null) f = f.timeout(timeout);
    return await f;
  } catch (e) {
    AppLog.instance.record(source, '$what: $e');
    return fallback;
  }
}

/// Synchronous variant of [guard].
T? guardSync<T>(
  String what,
  T Function() op, {
  T? fallback,
  String source = 'app',
}) {
  try {
    return op();
  } catch (e) {
    AppLog.instance.record(source, '$what: $e');
    return fallback;
  }
}
