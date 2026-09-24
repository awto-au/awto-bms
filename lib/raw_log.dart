/// Verbose single-file RAW log (issue #19).
///
/// A persistent, append-only text file that captures every raw piece of data
/// seen across ALL connected batteries — the app-side equivalent of the Python
/// reference reader's per-frame text log, but merged into one file with the
/// battery serial on every line so a whole fleet's traffic is traceable in one
/// place.
///
/// It is DELIBERATELY lossless and mirrors the Python reader's line style:
///
///   <yyyy-MM-dd HH:mm:ss.SSS>  <serial>  <label padded>  <raw hex>   <summary>
///
/// Five kinds of line are written:
///  * `Notification (raw)` — every inbound BLE notification, verbatim, BEFORE
///    framing, so nothing is ever lost (this is also the raw-notification
///    capture the stray-0x30 investigation needs).
///  * the decoded frame's plain-English label + a short decode summary, one per
///    parsed frame (mirrors the Python `RX_*` lines).
///  * `TX` — the handshake / command bytes the app sends.
///  * `UNRECOGNISED` — each stray byte the parser drops on resync (issue #20),
///    with its byte value, so no byte is ever silently dropped.
///  * `DIAG` — every [AppLog] diagnostic (a recorded best-effort failure), so
///    the raw log also tells the developer what went wrong around the traffic.
///
/// This is IN ADDITION to the interval SQLite store (battery_log.dart), which is
/// untouched. It is always on: there is no switch in the UI (#111).
///
/// SIZE CAP (review pass C1, M9) and KEEP EVERYTHING (#111): once the live
/// file exceeds [maxBytes] (50 MB) it is renamed to
/// `battery_raw.<yyyymmdd-hhmmss>.log` (the local time it was closed) and a
/// fresh file is started. Rotated files are NEVER deleted automatically; only
/// the user's explicit choice in Settings → Data removes them (the "Keep
/// data" period, "Delete data older than…", "Delete all data"). A
/// `battery_raw.1.log` left by an older build is kept and treated as one more
/// rotated file. The total across all files is shown in Settings.
///
/// The line FORMATTING ([formatLine]) is a pure function with no I/O, so it is
/// unit-tested directly. File I/O is best-effort and self-disables if the
/// platform has no writable directory (e.g. under `flutter test`, where
/// path_provider has no plugin) — the app keeps running either way; every
/// failure is recorded in [AppLog].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'diagnostics.dart';
import 'fmt.dart' as fmt;

/// Append-only single-file raw logger. App-wide singleton, like [BatteryLogger].
class RawLogger {
  static final RawLogger instance = RawLogger._();
  RawLogger._() : _testDir = null {
    _registerDiagSink();
  }

  /// Test constructor: logs into [dir] (no path_provider) with a small cap so
  /// rotation can be exercised. Does NOT register as the [AppLog] sink.
  @visibleForTesting
  RawLogger.forTest({required Directory dir, int? maxBytes}) : _testDir = dir {
    if (maxBytes != null) this.maxBytes = maxBytes;
  }

  final Directory? _testDir;

  /// The one raw-log filename. Never per-serial; the same file is re-opened in
  /// append mode across reconnects and app restarts, until it is rotated.
  static const fileName = 'battery_raw.log';

  /// The single rotation target of builds before #111 (overwritten on every
  /// rotation then). Still recognised, kept and exported as a rotated file.
  static const legacyRotatedFileName = 'battery_raw.1.log';

  /// #111: `battery_raw.20260924-140501.log` (the local time it was closed;
  /// `-2`, `-3`… is appended if that name is already taken).
  static final RegExp _rotatedName =
      RegExp(r'^battery_raw\.(\d{8})-(\d{6})(?:-\d+)?\.log$');

  /// #111: the file name a rotation at [t] (local time) gets.
  static String rotatedFileNameAt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = t.toLocal();
    return 'battery_raw.${l.year}${two(l.month)}${two(l.day)}'
        '-${two(l.hour)}${two(l.minute)}${two(l.second)}.log';
  }

  /// #111: when a rotated file was closed — from its name, or null when
  /// [name] is not a timestamped rotated file (the legacy `.1` file, the live
  /// file, anything else). Pure.
  static DateTime? rotatedAt(String name) {
    final m = _rotatedName.firstMatch(name);
    if (m == null) return null;
    final d = m.group(1)!, t = m.group(2)!;
    int at(String s, int i, int n) => int.parse(s.substring(i, i + n));
    return DateTime(at(d, 0, 4), at(d, 4, 2), at(d, 6, 2), at(t, 0, 2),
        at(t, 2, 2), at(t, 4, 2));
  }

  /// #111: is [name] a rotated raw log (timestamped, or the legacy `.1`)?
  static bool isRotatedName(String name) =>
      name == legacyRotatedFileName || _rotatedName.hasMatch(name);

  /// Rotation threshold (M9).
  static const int defaultMaxBytes = 50 * 1024 * 1024;

  /// Size at which the live file is rotated to a timestamped file.
  int maxBytes = defaultMaxBytes;

  /// Verbose raw logging on/off (issue #19). Default ON; the UI can turn it off
  /// if the file grows large. When off, nothing is captured or written.
  bool enabled = true;

  /// Test/console hook: called synchronously with every formatted line as it is
  /// produced, regardless of whether a file is available. Lets tests assert on
  /// the exact lines without touching the filesystem.
  void Function(String line)? onLine;

  File? _file;
  String? _path;
  bool _initTried = false;
  int _sizeBytes = 0;
  int _rotations = 0;
  int _rotatedBytes = 0;
  int _rotatedCount = 0;

  /// Absolute path of the raw-log file, or null before [init] resolves it (or if
  /// no writable directory was found). Surfaced in the UI so the user can find
  /// and retrieve the file.
  String? get path => _path;

  /// The folder holding the live file and every rotated one, or null.
  String? get dir => _path == null ? null : p.dirname(_path!);

  /// #111: every rotated raw log on disk (timestamped files and a legacy
  /// `battery_raw.1.log`), oldest first. Empty before [init] or with no
  /// writable folder. Best effort: a listing failure reads as empty.
  Future<List<RotatedLog>> rotatedLogs() async {
    final d = dir;
    if (d == null) return const [];
    final out = await guard<List<RotatedLog>>('list raw logs', () async {
      final found = <RotatedLog>[];
      await for (final e in Directory(d).list(followLinks: false)) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!isRotatedName(name)) continue;
        final stat = await e.stat();
        found.add(RotatedLog(
          path: e.path,
          closedAt: rotatedAt(name) ?? stat.modified,
          bytes: stat.size,
        ));
      }
      found.sort((a, b) => a.closedAt.compareTo(b.closedAt));
      return found;
    }, fallback: const [], source: _source);
    return out ?? const [];
  }

  /// #111: every rotated file (oldest first) then the live file — what the
  /// data export includes.
  Future<List<String>> allLogPaths() async => [
        for (final r in await rotatedLogs()) r.path,
        if (_path != null) _path!,
      ];

  /// Current size of the live file in bytes (tracked in memory; exact after
  /// [init], then advanced by every flushed chunk).
  int get sizeBytes => _sizeBytes;

  /// #111: bytes in the rotated files (refreshed at [init], on each rotation
  /// and after a deletion).
  int get rotatedBytes => _rotatedBytes;

  /// #111: how many rotated files are kept.
  int get rotatedCount => _rotatedCount;

  /// #111: the live file plus every rotated file.
  int get totalBytes => _sizeBytes + _rotatedBytes;

  /// Re-read the rotated files' count and size from disk.
  Future<void> refreshRotatedStats() async {
    final all = await rotatedLogs();
    _rotatedCount = all.length;
    _rotatedBytes = all.fold(0, (a, r) => a + r.bytes);
  }

  /// When the live file was last written (its modification time), or null if
  /// there is no file yet. Shown in Settings so a log that was switched OFF
  /// (and silently stopped) is obvious: "Logging is OFF — last wrote <when>".
  /// Best effort: a stat failure reads as "never".
  DateTime? get lastWrittenAt {
    final file = _file;
    if (file == null) return null;
    try {
      if (!file.existsSync()) return null;
      return file.lastModifiedSync();
    } catch (_) {
      return null;
    }
  }

  /// One-line logging status for the Settings page: states plainly when the
  /// log is OFF (and when it last wrote), else the total across every file
  /// (#111: rotated files are kept, so the total is what uses the space).
  static String statusLine({
    required bool enabled,
    required int sizeBytes,
    required int maxBytes,
    required DateTime? lastWrittenAt,
    int rotatedBytes = 0,
    int rotatedCount = 0,
  }) {
    if (!enabled) {
      final when = lastWrittenAt == null ? 'never' : _fmtWhen(lastWrittenAt);
      return 'Logging is OFF — last wrote $when';
    }
    final files = rotatedCount + 1;
    return 'Logging — ${fmtSize(sizeBytes + rotatedBytes)} in $files '
        '${files == 1 ? 'file' : 'files'} (new file every '
        '${fmtSize(maxBytes)}, all kept)';
  }

  /// `2026-09-20 14:05` (local time, minute resolution).
  static String _fmtWhen(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  /// How many rotations have happened this session (tests / diagnostics).
  int get rotations => _rotations;

  final List<String> _buffer = [];
  // Safety cap so an un-flushed buffer (e.g. file unavailable) can never grow
  // without bound. Oldest lines are dropped first.
  static const int _bufferCap = 20000;
  Timer? _flushTimer;
  Future<void> _chain = Future<void>.value();

  /// Route every [AppLog] diagnostic into the raw log as a `DIAG` line (when
  /// verbose logging is on). Entries whose source is this logger are skipped so
  /// a failing raw-log write can never feed back into itself.
  void _registerDiagSink() {
    AppLog.instance.sink = (e) {
      if (e.source == _source) return;
      logEvent('', 'DIAG', '${e.source}: ${e.message}');
    };
  }

  static const _source = 'RawLogger';

  /// Resolve the per-platform log directory and open the file for appending.
  /// Safe to call more than once. On any failure the file is left null and only
  /// the in-memory/onLine path remains, so the app never crashes over logging.
  ///
  ///  * Android/iOS: the app's external files dir (`getExternalStorageDirectory`)
  ///    so the user can retrieve it; falls back to the documents dir.
  ///  * Windows/Linux/macOS: the app-support dir (`getApplicationSupportDirectory`).
  Future<void> init() async {
    if (_initTried) return;
    _initTried = true;
    final ok = await guard<bool>('open raw log', () async {
      Directory? dir = _testDir;
      if (dir == null) {
        if (Platform.isAndroid || Platform.isIOS) {
          dir = await getExternalStorageDirectory();
          dir ??= await getApplicationDocumentsDirectory();
        } else {
          dir = await getApplicationSupportDirectory();
        }
      }
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, fileName));
      _sizeBytes = await file.exists() ? await file.length() : 0;
      _file = file;
      _path = file.path;
      return true;
    }, fallback: false, source: _source);
    if (ok != true) {
      _file = null;
      _path = null;
      return;
    }
    await refreshRotatedStats();
    // Start the periodic flush so buffered lines reach disk even without a
    // share/dispose. Value CHANGES nothing about the append-only file.
    _flushTimer ??=
        Timer.periodic(const Duration(seconds: 2), (_) => unawaited(flush()));
    // Flush anything buffered before init resolved the path.
    unawaited(flush());
  }

  // --- pure line formatting (unit-tested) ----------------------------------

  /// Lowercase, space-separated two-hex-digit bytes: `a2 57 85 00` (the shared
  /// [fmt.hexOf]).
  static String hexOf(List<int> bytes) => fmt.hexOf(bytes);

  /// Full local timestamp `yyyy-MM-dd HH:mm:ss.SSS` (same shape as the interval
  /// store and the Python log, zero-padded so it sorts chronologically) — the
  /// shared [fmt.fmtStamp].
  static String fmtTime(DateTime d) => fmt.fmtStamp(d);

  /// Format ONE raw-log line. Pure — no I/O. Fields, in order: timestamp,
  /// serial, the plain-English label (left-padded to a fixed column so lines
  /// align), the raw hex bytes, then the short decode summary. Mirrors the
  /// Python reader's `emit()` line so both logs read the same way.
  static String formatLine({
    required DateTime time,
    required String serial,
    required String label,
    List<int> raw = const [],
    String summary = '',
  }) {
    final ts = fmtTime(time);
    final who = serial.isEmpty ? '-' : serial;
    final hx = hexOf(raw);
    final tail = hx.isEmpty
        ? summary
        : (summary.isEmpty ? hx : '$hx   $summary');
    return '$ts  $who  ${label.padRight(22)} $tail';
  }

  /// Human-readable size: "12.3 MB", "840 KB", "512 B".
  static String fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }

  // --- log entry points -----------------------------------------------------

  /// Every inbound BLE notification, verbatim, BEFORE framing. This is the
  /// loss-free capture: it includes the stray 0x30 resync byte and any bytes
  /// that never form a recognised frame.
  void logRaw(String serial, List<int> data) =>
      _write(formatLine(
        time: DateTime.now(),
        serial: serial,
        label: 'Notification (raw)',
        raw: data,
        summary: '${data.length} bytes',
      ));

  /// One decoded frame: its plain-English label, the frame's raw bytes and a
  /// short decode summary.
  void logEvent(String serial, String label, String summary,
          {List<int> frame = const []}) =>
      _write(formatLine(
        time: DateTime.now(),
        serial: serial,
        label: label,
        raw: frame,
        summary: summary,
      ));

  /// A command the app sent to the pack (handshake opener, version/est request,
  /// gate-control write, …), with its raw bytes.
  void logTx(String serial, String name, List<int> bytes) =>
      _write(formatLine(
        time: DateTime.now(),
        serial: serial,
        label: 'TX: $name',
        raw: bytes,
        summary: 'sent',
      ));

  /// One stray byte dropped by the parser's resync path (issue #20). Logged so
  /// no byte is ever silently discarded; the running per-battery count is passed
  /// through in the summary for context.
  /// #60: the ASCII '0' status byte the firmware's AT bridge returns for
  /// `AT+V` (live-confirmed, #23). Known and harmless — logged under its own
  /// label, never as UNRECOGNISED, and not counted.
  void logAtStatus(String serial, int byte) => _write(
        formatLine(
          time: DateTime.now(),
          serial: serial,
          label: 'AT status',
          raw: [byte],
          summary: "AT+V status byte '0' (AT bridge return code)",
        ),
      );

  void logUnrecognised(String serial, int byte, {int? runningCount}) => _write(
        formatLine(
          time: DateTime.now(),
          serial: serial,
          label: 'UNRECOGNISED',
          raw: [byte],
          summary: 'dropped stray byte 0x${(byte & 0xff).toRadixString(16).padLeft(2, '0')}'
              '${runningCount == null ? '' : ' (count=$runningCount)'}',
        ),
      );

  void _write(String line) {
    if (!enabled) return;
    onLine?.call(line);
    _buffer.add(line);
    if (_buffer.length > _bufferCap) {
      _buffer.removeRange(0, _buffer.length - _bufferCap);
    }
  }

  /// Append all buffered lines to the file in one write (append-only, flushed),
  /// then rotate if the file has grown past [maxBytes] (M9). No-op when
  /// disabled, empty, or no file is available. Never throws.
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    final file = _file;
    if (file == null) return;
    final chunk = '${_buffer.join('\n')}\n';
    _buffer.clear();
    _chain = _chain.then((_) async {
      // Best effort — logging never crashes the app; a failure is recorded.
      final wrote = await guard<bool>('append raw log', () async {
        await file.writeAsString(chunk, mode: FileMode.append, flush: true);
        return true;
      }, fallback: false, source: _source);
      if (wrote == true) {
        _sizeBytes += chunk.length;
        if (_sizeBytes > maxBytes) await _rotate(file);
      }
    });
    await _chain;
  }

  /// #111: rename the live file to `battery_raw.<yyyymmdd-hhmmss>.log` and
  /// start a fresh, empty live file. Nothing is ever deleted: a name that is
  /// already taken gets a `-2`, `-3`… suffix. Runs inside the write chain so
  /// it never races an append.
  Future<void> _rotate(File file) async {
    final moved = await guard<File?>('rotate raw log', () async {
      final folder = p.dirname(file.path);
      final base = rotatedFileNameAt(clock());
      var target = File(p.join(folder, base));
      for (var n = 2; await target.exists(); n++) {
        target = File(p.join(folder, base.replaceFirst('.log', '-$n.log')));
      }
      return file.rename(target.path);
    }, fallback: null, source: _source);
    if (moved != null) {
      final bytes = await guard<int>('size rotated raw log', moved.length,
          fallback: _sizeBytes, source: _source);
      _rotatedBytes += bytes ?? _sizeBytes;
      _rotatedCount++;
      _sizeBytes = 0;
      _rotations++;
      // `file` still points at the live path; the next append recreates it.
    }
  }

  /// The time source for rotation names (tests pin it).
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// #111: delete the rotated files closed before [cutoff] (so their newest
  /// line is older than the cutoff). The live file is never touched. Only for
  /// the user's explicit choice in Settings. Runs on the write chain. Returns
  /// how many files were deleted.
  Future<int> deleteRotatedBefore(DateTime cutoff) =>
      _deleteFiles((r) => r.closedAt.isBefore(cutoff), emptyLive: false);

  /// #111: "Delete all data": every rotated file is deleted and the live file
  /// is emptied (it stays the live file, so logging carries straight on;
  /// lines still buffered are written after it). Runs on the write chain.
  /// Returns how many rotated files were deleted.
  Future<int> deleteAllFiles() => _deleteFiles((_) => true, emptyLive: true);

  Future<int> _deleteFiles(bool Function(RotatedLog r) which,
      {required bool emptyLive}) {
    final done = Completer<int>();
    _chain = _chain.then((_) async {
      var n = 0;
      for (final r in await rotatedLogs()) {
        if (!which(r)) continue;
        final gone = await guard<bool>('delete ${p.basename(r.path)}',
            () async {
          await File(r.path).delete();
          return true;
        }, fallback: false, source: _source);
        if (gone == true) n++;
      }
      final file = _file;
      if (emptyLive && file != null) {
        final emptied = await guard<bool>('empty raw log', () async {
          await file.writeAsString('', flush: true);
          return true;
        }, fallback: false, source: _source);
        if (emptied == true) _sizeBytes = 0;
      }
      await refreshRotatedStats();
      done.complete(n);
    });
    return done.future;
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
    await _chain;
  }
}

/// #111: one rotated raw-log file on disk.
class RotatedLog {
  final String path;

  /// When it was closed (from the name; the file time for the legacy `.1`).
  final DateTime closedAt;
  final int bytes;
  const RotatedLog(
      {required this.path, required this.closedAt, required this.bytes});
}
