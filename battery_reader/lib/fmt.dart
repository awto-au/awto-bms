/// The ONE set of shared formatters (review pass C2, GitHub #51).
///
/// Before this pass the same helpers were written four times over: a
/// zero-padded `yyyy-MM-dd HH:mm:ss.SSS` stamp in battery_log.dart,
/// raw_log.dart and diagnostics.dart; a hex-dump in battery_connection.dart,
/// raw_log.dart; `two()`/`p()`/`q()` padders in each; and the per-unit value
/// formatters (V / A / Ah / W / % / dBm) in main.dart. They live here now, and
/// every previous site delegates to (or was replaced by) these.
///
/// Pure Dart: no Flutter, no I/O — unit-tested directly.
library;

import 'battery_protocol.dart' show secondsToHms;

/// Zero-pad [v] to [width] digits.
String pad(int v, [int width = 2]) => v.toString().padLeft(width, '0');

/// Full local date-and-time text `yyyy-MM-dd HH:mm:ss.SSS` — the timestamp
/// shape shared by the interval store's text columns, the raw log and the
/// diagnostics log (zero-padded so it sorts chronologically).
String fmtStamp(DateTime d) => '${pad(d.year, 4)}-${pad(d.month)}-${pad(d.day)} '
    '${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)}.${pad(d.millisecond, 3)}';

/// [fmtStamp] of an epoch-ms instant (local time).
/// Console line with a local timestamp: `2026-09-22 08:41:03.117 [TAG] msg`.
/// Every console print in the app goes through this so the Windows console and
/// `adb logcat` output can be correlated with the raw log and Diagnostics.
void logLine(String tag, String message) =>
    // ignore: avoid_print
    print('${fmtStamp(DateTime.now())} [$tag] $message');

String fmtStampMs(int ms) => fmtStamp(DateTime.fromMillisecondsSinceEpoch(ms));

const _monthAbbr = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Short local stamp for an event list: `21 Sep 15:06:59` (#67).
String fmtShortStamp(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${_monthAbbr[d.month - 1]} '
      '${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)}';
}

/// Lowercase, space-separated two-hex-digit bytes: `a2 57 85 00`.
String hexOf(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join(' ');

/// A chart's x-axis tick for an epoch-ms instant: `HH:MM` for windows up to a
/// day and a half, `d/M` beyond that.
String fmtTick(int ms, double spanMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  if (spanMs > 36 * 3600 * 1000) return '${d.day}/${d.month}';
  return '${pad(d.hour)}:${pad(d.minute)}';
}

/// A chart's y-axis label: fewer decimals as the magnitude grows.
String fmtAxis(double v) {
  if (v.abs() >= 100) return v.toStringAsFixed(0);
  if (v.abs() >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2);
}

/// #70: a chart-card stats readout (current / max / min / median). Like
/// [fmtAxis] but with three decimals below 10 so cell voltages read to the mV.
String fmtStat(double v) =>
    v.abs() < 10 ? v.toStringAsFixed(3) : fmtAxis(v);

// --- unit formatters (an em dash for a missing value) ----------------------

String fPct(int? v) => v == null ? '—' : '$v%';
String fV(double? v) => v == null ? '—' : '${v.toStringAsFixed(2)} V';
String fA(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} A';
String fAh(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} Ah';
String fW(double? v) => v == null ? '—' : '${v.toStringAsFixed(0)} W';
String fBool(bool? v) => v == null ? '—' : (v ? 'On' : 'Off');
String fTime(int? s) => s == null ? '—' : secondsToHms(s);
String fRssi(int? v) => v == null ? '—' : '$v dBm';
String fCycles(double? v) => v == null ? '—' : v.toStringAsFixed(2);

/// Signed current text with direction words: "+12.3 A in" / "-12.3 A out".
String fSignedA(double? v) {
  if (v == null) return '—';
  final mag = v.abs().toStringAsFixed(1);
  if (v > 0.05) return '+$mag A in';
  if (v < -0.05) return '-$mag A out';
  return '0.0 A';
}

/// L9: "1 battery" / "3 batteries".
String pluralBatteries(int n) => n == 1 ? '1 battery' : '$n batteries';

/// #61: a short age / countdown for the live indicator: "0.4 s" under 10 s,
/// "12 s" under a minute, then "2 min", "1 h 05 min", "3 d". Negative reads
/// as 0.
String fmtAgeShort(int ms) {
  if (ms < 0) ms = 0;
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)} s';
  final sec = ms ~/ 1000;
  if (sec < 60) return '$sec s';
  final min = sec ~/ 60;
  if (min < 60) return '$min min';
  final hr = min ~/ 60;
  if (hr < 24) return '$hr h ${pad(min % 60)} min';
  return '${hr ~/ 24} d';
}

/// Compact relative-time label ("just now", "5 min ago", "2 h ago", "3 d ago")
/// for an offline favourite's last-seen timestamp (#34). Null / unknown reads
/// "unknown".
String relativeTime(int? ms, {int? nowMs}) {
  if (ms == null || ms <= 0) return 'unknown';
  final diff = (nowMs ?? DateTime.now().millisecondsSinceEpoch) - ms;
  if (diff < 0) return 'just now';
  final sec = diff ~/ 1000;
  if (sec < 45) return 'just now';
  final min = sec ~/ 60;
  if (min < 60) return '$min min ago';
  final hr = min ~/ 60;
  if (hr < 24) return '$hr h ago';
  final days = hr ~/ 24;
  return '$days d ago';
}
