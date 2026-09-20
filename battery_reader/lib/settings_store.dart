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

  /// Verbose raw logging default ON (matches [RawLogger.enabled]).
  static const verbose = BoolSetting('verbose_logging_v1', true);

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

  /// Every persisted boolean setting.
  static const all = [
    demoMode,
    verbose,
    useFahrenheit,
    alertNotifications,
    backgroundMonitoring,
  ];

  Future<bool> load(BoolSetting s) =>
      readBool(s.key, fallback: s.defaultValue);
  Future<void> save(BoolSetting s, bool v) => writeBool(s.key, v);

  // Named accessors kept for the existing callers.
  Future<bool> loadDemoMode() => load(demoMode);
  Future<void> saveDemoMode(bool v) => save(demoMode, v);
  Future<bool> loadVerbose() => load(verbose);
  Future<void> saveVerbose(bool v) => save(verbose, v);
  Future<bool> loadUseFahrenheit() => load(useFahrenheit);
  Future<void> saveUseFahrenheit(bool v) => save(useFahrenheit, v);
  Future<bool> loadAlertNotifications() => load(alertNotifications);
  Future<void> saveAlertNotifications(bool v) => save(alertNotifications, v);
  Future<bool> loadBackgroundMonitoring() => load(backgroundMonitoring);
  Future<void> saveBackgroundMonitoring(bool v) =>
      save(backgroundMonitoring, v);

  /// #53: background sample interval, persisted as SECONDS (0 = continuous).
  /// Additive key; the default (5 min) applies when absent or unreadable.
  static const sampleIntervalKey = 'background_sample_interval_v1';
  static const int defaultSampleIntervalS = 300;

  Future<int> loadSampleIntervalS() =>
      readInt(sampleIntervalKey, fallback: defaultSampleIntervalS);
  Future<void> saveSampleIntervalS(int seconds) =>
      writeInt(sampleIntervalKey, seconds);
}
