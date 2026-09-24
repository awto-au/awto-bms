/// shared_preferences-backed app settings (#35): persists the Settings-page
/// choices so they survive a restart. Since review pass C1 it is a thin table
/// of [BoolSetting]s over the shared [PrefsStore] base: every read/write is
/// best-effort (falls back to the default) and every failure is recorded in
/// Diagnostics. Keys are unchanged so existing persisted data still loads.
library;

import 'prefs_store.dart';

/// One persisted boolean setting: its preferences key and default.
class BoolSetting {
  final String key;
  final bool defaultValue;
  const BoolSetting(this.key, this.defaultValue);
}

class SettingsStore extends PrefsStore {
  SettingsStore({super.prefs}) : super('SettingsStore');

  /// Demo mode default OFF — the app defaults to Live (#35).
  static const demoMode = BoolSetting('demo_mode_v1', false);

  /// Temperature-unit choice (#43). Default OFF = °C; ON = °F. Display-only —
  /// nothing sent to the BMS and the stored/logged values stay in °C.
  static const useFahrenheit = BoolSetting('temp_fahrenheit_v1', false);

  /// System alert notifications (#45). Default ON — faults/alerts surface as
  /// Android notifications (incl. when backgrounded). Off disables the system
  /// notifications only; the in-app beep + red banner (and the monitoring
  /// foreground service, when needed) are unaffected.
  static const alertNotifications = BoolSetting('alert_notifications_v1', true);

  /// Background monitoring (#52). Default ON — the foreground service keeps
  /// BLE + alerts alive while the app is backgrounded. Off: the service never
  /// runs, the app monitors only while in the foreground, and backgrounding /
  /// swiping it away releases every battery (no BLE activity).
  static const backgroundMonitoring =
      BoolSetting('background_monitoring_v1', true);

  /// Chart Y-axis default (#70). Default OFF = full range (the 0-based /
  /// symmetric #32 policy); ON = fit the axis to the data seen in the window.
  /// Display-only; each chart card can override it for the session.
  static const chartYAxisFit = BoolSetting('chart_y_axis_fit_v1', false);

  /// Every persisted boolean setting.
  static const all = [
    demoMode,
    useFahrenheit,
    alertNotifications,
    backgroundMonitoring,
    chartYAxisFit,
  ];

  Future<bool> load(BoolSetting s) =>
      readBool(s.key, fallback: s.defaultValue);
  Future<void> save(BoolSetting s, bool v) => writeBool(s.key, v);

  // Named accessors kept for the existing callers.
  Future<bool> loadDemoMode() => load(demoMode);
  Future<void> saveDemoMode(bool v) => save(demoMode, v);
  Future<bool> loadUseFahrenheit() => load(useFahrenheit);
  Future<void> saveUseFahrenheit(bool v) => save(useFahrenheit, v);
  Future<bool> loadAlertNotifications() => load(alertNotifications);
  Future<void> saveAlertNotifications(bool v) => save(alertNotifications, v);
  Future<bool> loadBackgroundMonitoring() => load(backgroundMonitoring);
  Future<void> saveBackgroundMonitoring(bool v) =>
      save(backgroundMonitoring, v);
  Future<bool> loadChartYAxisFit() => load(chartYAxisFit);
  Future<void> saveChartYAxisFit(bool v) => save(chartYAxisFit, v);

  /// #53: background sample interval, persisted as SECONDS (0 = continuous).
  /// Additive key; the default (5 min) applies when absent or unreadable.
  static const sampleIntervalKey = 'background_sample_interval_v1';
  static const int defaultSampleIntervalS = 300;

  Future<int> loadSampleIntervalS() =>
      readInt(sampleIntervalKey, fallback: defaultSampleIntervalS);
  Future<void> saveSampleIntervalS(int seconds) =>
      writeInt(sampleIntervalKey, seconds);

  /// #111: "Keep data" in months; 0 (the default, also when absent or
  /// unreadable) keeps everything and nothing is ever deleted.
  static const keepDataMonthsKey = 'keep_data_months_v1';

  Future<int> loadKeepDataMonths() => readInt(keepDataMonthsKey, fallback: 0);
  Future<void> saveKeepDataMonths(int months) =>
      writeInt(keepDataMonthsKey, months);

  /// #68: the desktop window's last bounds (logical px) + maximized flag,
  /// stored as JSON. Desktop only; absent / unreadable = let the runner fit
  /// the window to the screen as on first run.
  static const windowBoundsKey = 'window_bounds_v1';

  Future<WindowBounds?> loadWindowBounds() async {
    final raw = await readJson(windowBoundsKey);
    return raw is Map ? WindowBounds.fromMap(raw) : null;
  }

  Future<void> saveWindowBounds(WindowBounds b) =>
      writeJson(windowBoundsKey, b.toMap());
}

/// #68: a remembered desktop window placement in LOGICAL pixels (the runner
/// scales by the monitor's DPI). Pure value type; [fromMap] rejects anything
/// that is not four finite numbers of a plausible size.
class WindowBounds {
  final double left;
  final double top;
  final double width;
  final double height;
  final bool maximized;
  const WindowBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.maximized = false,
  });

  /// The runner's minimum window size (windows/runner/main.cpp).
  static const double minWidth = 900;
  static const double minHeight = 600;

  static WindowBounds? fromMap(Map<dynamic, dynamic> m) {
    double? at(String k) {
      final v = m[k];
      return v is num && v.isFinite ? v.toDouble() : null;
    }

    final l = at('left'), t = at('top'), w = at('width'), h = at('height');
    if (l == null || t == null || w == null || h == null) return null;
    if (w < minWidth || h < minHeight || w > 20000 || h > 20000) return null;
    return WindowBounds(
        left: l, top: t, width: w, height: h, maximized: m['maximized'] == true);
  }

  Map<String, Object> toMap() => {
        'left': left,
        'top': top,
        'width': width,
        'height': height,
        'maximized': maximized,
      };

  @override
  bool operator ==(Object other) =>
      other is WindowBounds &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(left, top, width, height, maximized);

  @override
  String toString() =>
      'WindowBounds($left, $top, ${width}x$height${maximized ? ', maximized' : ''})';
}
