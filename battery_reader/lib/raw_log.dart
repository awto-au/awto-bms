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
/// untouched. Verbose logging can be turned OFF from the UI ([enabled]) if the
/// file grows large; it defaults ON.
///
/// SIZE CAP (review pass C1, M9): at ~60-90 MB/day/battery the file used to
/// grow without bound. Once it exceeds [maxBytes] (50 MB) it is rotated ONCE to
/// `battery_raw.1.log` (overwriting the previous rotation) and a fresh file is
/// started, so at most ~2 x [maxBytes] is ever on disk. The current size is
/// shown in Settings.
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

  /// The single rotation target (M9). Overwritten on every rotation.
  static const rotatedFileName = 'battery_raw.1.log';

  /// Rotation threshold (M9).
  static const int defaultMaxBytes = 50 * 1024 * 1024;

  /// Size at which the file is rotated to [rotatedFileName].
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

  /// Absolute path of the raw-log file, or null before [init] resolves it (or if
  /// no writable directory was found). Surfaced in the UI so the user can find
  /// and retrieve the file.
  String? get path => _path;

  /// Absolute path of the rotated file (may not exist yet), or null.
  String? get rotatedPath =>
      _path == null ? null : p.join(p.dirname(_path!), rotatedFileName);

  /// Current size of the live file in bytes (tracked in memory; exact after
  /// [init], then advanced by every flushed chunk).
  int get sizeBytes => _sizeBytes;

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

  /// Move the live file to [rotatedFileName] (replacing any previous rotation)
  /// and start a fresh, empty live file. Runs inside the write chain so it never
  /// races an append.
  Future<void> _rotate(File file) async {
    final ok = await guard<bool>('rotate raw log', () async {
      final target = File(rotatedPath!);
      if (await target.exists()) await target.delete();
      await file.rename(target.path);
      return true;
    }, fallback: false, source: _source);
    if (ok == true) {
      _sizeBytes = 0;
      _rotations++;
      // `file` still points at the live path; the next append recreates it.
    }
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
    await _chain;
  }
}
