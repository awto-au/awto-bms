/// Background-monitoring policy (issue #52): the pure decisions behind the
/// Android foreground service and the BLE scan/reconnect loop.
///
/// Pass 14 added the foreground service so alerts keep firing while the app is
/// backgrounded — but it was too eager: the 300 ms UI tick re-started it after
/// every stop, and the plugin's own restart alarms resurrected it after a
/// swipe / force-stop, so there was no way to make the app let go of the
/// batteries (one BLE central at a time) for the PC tools.
///
/// This class owns three inputs and derives two outputs from them:
///
///  * [backgroundMonitoring] — the Settings toggle (persisted, default ON).
///  * [userStopped] — an EXPLICIT stop: the "Stop monitoring" action on the
///    persistent notification, or "Pause monitoring (release batteries)" in the
///    app. It is never cleared by the tick; only a fresh launch (a new
///    instance), [resume], or turning the toggle back ON clears it.
///  * [inForeground] — whether the app is currently resumed.
///
///  * [serviceShouldRun] — the foreground service runs only while there is
///    something to monitor AND background monitoring is on AND the user has
///    not stopped it. The tick calls this every 300 ms, so a user stop wins
///    over the tick by construction.
///  * [bleShouldRun] — the BLE scan/reconnect loop runs unless the user
///    stopped it, and, with background monitoring OFF, only in the foreground:
///    backgrounding / swiping the app then releases every pack.
///
/// Pure Dart (no Flutter / plugin imports) so it is unit-testable.
library;

/// #53: the Settings choice "Background sample interval". Continuous keeps
/// every BLE link held while backgrounded (instant alerts, the highest drain);
/// the others release every pack when the app is backgrounded and reconnect
/// once per interval for ONE full telemetry cycle, radio idle in between.
enum BackgroundSampleInterval {
  continuous(0, 'Continuous'),
  m1(60, '1 min'),
  m5(300, '5 min'),
  m15(900, '15 min');

  const BackgroundSampleInterval(this.seconds, this.label);

  /// Seconds between samples; 0 = continuous.
  final int seconds;

  /// Segment label.
  final String label;

  static const BackgroundSampleInterval defaultValue = m5;

  int get ms => seconds * 1000;
  bool get isContinuous => seconds == 0;

  /// The persisted seconds value back to a choice (unknown -> the default).
  static BackgroundSampleInterval fromSeconds(int? s) =>
      values.firstWhere((v) => v.seconds == s, orElse: () => defaultValue);

  /// The alert-latency trade-off, shown under the selector.
  String get latencyNote => isContinuous
      ? 'Continuous: alerts are instant, but the phone holds every '
          'Bluetooth link the whole time (the highest battery drain).'
      : 'In the background a fault is noticed up to $label late; the radio '
          'is idle between samples.';
}

class MonitoringPolicy {
  MonitoringPolicy({this.backgroundMonitoring = true});

  /// Settings toggle "Background monitoring" (persisted, default ON).
  bool backgroundMonitoring;

  /// #53: the background sample interval (persisted, default 5 min).
  BackgroundSampleInterval sampleInterval =
      BackgroundSampleInterval.defaultValue;

  /// #53: true when the app should be SAMPLING (periodic connect / capture /
  /// disconnect) rather than holding the links: BLE may run, the app is in
  /// the background and the interval is not Continuous. In the foreground
  /// this is always false — foreground is continuous, immediately.
  bool get shouldSample =>
      bleShouldRun && !inForeground && !sampleInterval.isContinuous;

  /// #53: whether the CONTINUOUS scan/reconnect loop should be running (BLE
  /// allowed and not in sampling mode).
  bool get continuousShouldRun => bleShouldRun && !shouldSample;

  /// Set by an explicit user stop (notification action / pause). Cleared only
  /// by a fresh launch, [resume], or turning [backgroundMonitoring] ON.
  bool userStopped = false;

  /// Whether the app is resumed. A fresh launch is in the foreground.
  bool inForeground = true;

  /// #54: the user chose Exit (notification button / in-app). A full shutdown
  /// is in progress: nothing may start the service or BLE again.
  bool exiting = false;

  /// Whether the monitoring foreground service should be running for
  /// [monitoredCount] monitored (connected or fleet) batteries.
  bool serviceShouldRun(int monitoredCount) =>
      !exiting && monitoredCount > 0 && backgroundMonitoring && !userStopped;

  /// Whether the BLE scan / reconnect loop should be running right now.
  bool get bleShouldRun =>
      !exiting && !userStopped && (inForeground || backgroundMonitoring);

  /// #54: Exit = a user stop that also shuts the app down. Distinct from
  /// [stopByUser] (pause keeps the app alive); nothing clears it — the process
  /// ends.
  void exitApp() {
    userStopped = true;
    exiting = true;
  }

  /// "Stop monitoring" (notification action) / "Pause monitoring" (app).
  void stopByUser() => userStopped = true;

  /// "Resume monitoring".
  void resume() => userStopped = false;

  /// The Settings toggle. Turning it ON is an explicit request to monitor
  /// again, so it also clears a previous user stop; turning it OFF leaves the
  /// service stopped and prevents any start.
  void setBackgroundMonitoring(bool on) {
    backgroundMonitoring = on;
    if (on) userStopped = false;
  }

  /// App lifecycle: resumed -> true; paused / detached -> false.
  void setForeground(bool foreground) => inForeground = foreground;
}

/// #54: the ordered Exit shutdown. Each step is supplied by the app so the
/// ORDER is unit-testable: stop the foreground service, release every battery
/// (stop scanning / disconnect), cancel the alert notifications, FLUSH the
/// interval logger + raw log, and only then [terminate]. A step that throws
/// is recorded through [onError] and skipped — a failure to (say) cancel a
/// notification must never leave the app half-exited and still holding the
/// packs; the sequence always reaches [terminate].
Future<void> runExitSequence({
  required Future<void> Function() stopService,
  required Future<void> Function() releaseBle,
  required Future<void> Function() cancelNotifications,
  required Future<void> Function() flushLogs,
  required void Function() terminate,
  void Function(String step, Object error)? onError,
}) async {
  final steps = <(String, Future<void> Function())>[
    ('stop service', stopService),
    ('release BLE', releaseBle),
    ('cancel notifications', cancelNotifications),
    ('flush logs', flushLogs),
  ];
  for (final (name, step) in steps) {
    try {
      await step();
    } catch (e) {
      onError?.call(name, e);
    }
  }
  terminate();
}
