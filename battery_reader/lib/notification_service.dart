/// Runtime notification + foreground-service wrapper (issue #45).
///
/// Turns the pure decisions in [alert_notifications.dart] into real Android
/// system notifications via flutter_local_notifications, and keeps BLE + the
/// alert logic alive while backgrounded with an Android foreground service via
/// flutter_foreground_task.
///
/// Everything here is a best-effort no-op off Android/iOS (e.g. Windows desktop,
/// or `flutter test`), and every platform call is guarded so a missing plugin /
/// denied permission never crashes the app — the in-app beep + red banner keep
/// working regardless.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'alert_notifications.dart';
import 'diagnostics.dart';

/// Manages system notifications for battery faults/alerts and the persistent
/// monitoring foreground service.
class AlertNotificationService {
  static const _source = 'Notifications';
  AlertNotificationService({
    this.onOpenBattery,
    this.onStopRequested,
    this.onExitRequested,
  });

  /// Deep-link callback: invoked with the tapped notification's payload (the
  /// battery serial) so the app can navigate to that battery's detail page.
  final void Function(String serial)? onOpenBattery;

  /// #52: the user pressed "Stop monitoring" on the persistent notification
  /// (or dismissed it, Android 14+). The service is already stopping itself;
  /// the app must stop BLE and remember the user stop so the tick does not
  /// start it again.
  final void Function()? onStopRequested;

  /// #54: the user pressed "Exit" on the persistent notification: full
  /// shutdown (release BLE, flush logs, terminate). The service is already
  /// stopping itself.
  final void Function()? onExitRequested;

  /// #52: id of the "Stop monitoring" action on the persistent notification.
  static const stopButtonId = 'stop_monitoring';

  /// #54: id of the "Exit" action on the persistent notification.
  static const exitButtonId = 'exit_app';

  /// #52: message the task isolate sends to the main isolate for a user stop.
  static const stopCommand = 'stop_monitoring';

  /// #54: message the task isolate sends to the main isolate for Exit.
  static const exitCommand = 'exit_app';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // --- channels (issue #45) --------------------------------------------------
  static const faultsChannelId = 'faults';
  static const faultsChannelName = 'Faults';
  static const alertsChannelId = 'alerts';
  static const alertsChannelName = 'Alerts';

  /// The foreground-service channel (persistent low-importance "Monitoring …").
  static const monitoringChannelId = 'monitoring';
  static const monitoringChannelName = 'Battery monitoring';

  /// Fixed service id for the foreground service (kept away from the hashed
  /// per-condition notification ids).
  static const _serviceId = 4245;

  bool _available = false;
  bool _initDone = false;
  bool _serviceRunning = false;

  /// #41: true while the monitoring foreground service (with its wake lock)
  /// is confirmed running — the OTA pre-flight "device will stay awake" gate.
  bool get serviceRunning => _serviceRunning;

  /// #52: the notification text the running service was last given. The
  /// 300 ms tick calls [updateForegroundService] continuously; the service
  /// notification is re-posted ONLY when this changes (logcat showed the
  /// system UI re-inflating "Monitoring N batteries" many times a second).
  String? _serviceText;

  /// M10: in-flight guards. The UI ticker calls [apply] and
  /// [updateForegroundService] every 300 ms and never awaits them, so a slow
  /// platform call used to overlap the next tick: two `show()`s for the same
  /// id (replaying the Faults sound) or two `startService()`s. A tick that
  /// lands while the previous one is still running is simply skipped.
  bool _applying = false;
  bool _updatingService = false;

  /// Whether POST_NOTIFICATIONS is granted. When false, in-app alerts still work
  /// but no system notifications are posted.
  bool permissionGranted = false;

  /// Serial captured from a cold-start launch-by-tap, read once by the UI after
  /// the first frame to deep-link into that battery.
  String? pendingLaunchSerial;

  /// The notifications currently believed to be on screen, keyed by id — the
  /// baseline the next [apply] diffs against for de-dupe.
  Map<int, PendingNotification> _active = {};

  bool get _platformSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Initialise the plugin, create the channels, wire the tap handler and read
  /// any cold-start launch payload. Safe to call once; no-op off Android/iOS.
  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;
    if (!_platformSupported) return;
    // Plugin missing / platform without support: recorded; in-app alerts
    // still work.
    _available = await guard<bool>('init notifications', () async {
          const androidInit =
              AndroidInitializationSettings('@mipmap/ic_launcher');
          const iosInit = DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          );
          await _plugin.initialize(
            settings: const InitializationSettings(
                android: androidInit, iOS: iosInit),
            onDidReceiveNotificationResponse: _onTap,
          );
          await _createChannels();
          // Cold-start: launched by tapping a notification -> remember its
          // payload.
          final launch = await _plugin.getNotificationAppLaunchDetails();
          if (launch?.didNotificationLaunchApp ?? false) {
            final payload = launch?.notificationResponse?.payload;
            if (payload != null && payload.isNotEmpty) {
              pendingLaunchSerial = payload;
            }
          }
          _initForegroundTask();
          return true;
        }, fallback: false, source: _source) ??
        false;
  }

  Future<void> _createChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    await android.createNotificationChannel(const AndroidNotificationChannel(
      faultsChannelId,
      faultsChannelName,
      description: 'Genuine battery faults (current / voltage / temperature).',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      alertsChannelId,
      alertsChannelName,
      description: 'Status-byte changes and fleet disconnects.',
      importance: Importance.defaultImportance,
    ));
  }

  void _initForegroundTask() {
    // #52: the task isolate relays the notification's "Stop monitoring" button
    // to this (UI) isolate over the plugin's named port.
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: monitoringChannelId,
        channelName: monitoringChannelName,
        channelDescription: 'Keeps monitoring batteries while in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No repeating Dart task: the main isolate keeps BLE + the alert logic
        // running; the service exists to raise the process priority (and show
        // the persistent notification) so it survives BACKGROUNDING. The task
        // isolate only relays the notification button (#52).
        eventAction: ForegroundTaskEventAction.nothing(),
        // #52: NO resurrection. Every plugin restart path is off:
        //  * allowAutoRestart (plugin default TRUE) armed a 5 s restart alarm
        //    from onDestroy whenever the service was not "correctly stopped"
        //    (force-stop, task swipe, OS kill) — this was the app coming back
        //    on its own and re-grabbing the batteries.
        //  * autoRunOnBoot / autoRunOnMyPackageReplaced: never start on boot
        //    or after an update.
        //  * stopWithTask is left null so the manifest's
        //    android:stopWithTask="true" governs: START_NOT_STICKY, stopSelf()
        //    on task removal (instead of a 1 s restart alarm), reboot receiver
        //    ignored. (Setting it true HERE would install the plugin's
        //    visibility tracker, which stops the service as soon as the app is
        //    merely backgrounded — the one case the service exists for.)
        allowAutoRestart: false,
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
      ),
    );
  }

  /// #52: message from the task isolate — the user pressed "Stop monitoring".
  /// The task isolate stops the service itself, so it is no longer running
  /// here either; then hand the stop to the app.
  void _onTaskData(Object data) {
    if (data == stopCommand) {
      _serviceRunning = false;
      _serviceText = null;
      onStopRequested?.call();
    } else if (data == exitCommand) {
      _serviceRunning = false;
      _serviceText = null;
      onExitRequested?.call();
    }
  }

  /// #54: clear every alert notification (Exit). Best effort.
  Future<void> cancelAll() async {
    if (!_available) return;
    await guard<void>('cancel all notifications', () async {
      await _plugin.cancelAll();
      _active = {};
    }, source: _source);
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) onOpenBattery?.call(payload);
  }

  /// Request POST_NOTIFICATIONS at runtime (Android 13+ / iOS). Returns whether
  /// it is granted; a denial is handled gracefully (in-app alerts still work).
  Future<bool> requestPermission() async {
    if (!_available) return false;
    permissionGranted = await guard<bool>('request permission', () async {
          if (Platform.isAndroid) {
            final android = _plugin.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
            return await android?.requestNotificationsPermission() ?? false;
          } else if (Platform.isIOS) {
            return await _plugin
                    .resolvePlatformSpecificImplementation<
                        IOSFlutterLocalNotificationsPlugin>()
                    ?.requestPermissions(
                        alert: true, badge: true, sound: true) ??
                false;
          }
          return false;
        }, fallback: false, source: _source) ??
        false;
    return permissionGranted;
  }

  /// Reconcile the on-screen notifications with the desired set for [snapshots].
  /// De-dupes (unchanged notifications are not re-posted) and cancels cleared
  /// conditions. When [enabled] is false the desired set is empty, so this
  /// cancels every active alert notification (the Settings toggle path).
  Future<void> apply(
    List<BatterySnapshot> snapshots, {
    required bool enabled,
  }) async {
    if (!_available || _applying) return;
    _applying = true;
    try {
      final desired = desiredNotifications(snapshots, enabled: enabled);
      final plan = planNotifications(active: _active, desired: desired);
      if (plan.isEmpty) {
        _active = desired;
        return;
      }
      // M10: record each show/cancel as it SUCCEEDS, so a failure part-way
      // leaves `_active` describing exactly what is on screen — the next tick
      // retries only what is still missing, never re-posting (and re-sounding)
      // a notification that already went up.
      final active = Map<int, PendingNotification>.of(_active);
      // Best effort: a notification failure is recorded, never breaks the tick.
      final ok = await guard<bool>('apply notifications', () async {
        for (final n in plan.toShow) {
          await _plugin.show(
            id: n.id,
            title: n.title,
            body: n.body,
            notificationDetails: _detailsFor(n.channel),
            payload: n.payload,
          );
          active[n.id] = n;
        }
        for (final id in plan.toCancel) {
          await _plugin.cancel(id: id);
          active.remove(id);
        }
        return true;
      }, fallback: false, source: _source);
      // Everything applied, or only what actually succeeded.
      _active = ok == true ? desired : active;
    } finally {
      _applying = false;
    }
  }

  NotificationDetails _detailsFor(AlertChannel channel) => switch (channel) {
        AlertChannel.faults => const NotificationDetails(
            android: AndroidNotificationDetails(
              faultsChannelId,
              faultsChannelName,
              channelDescription:
                  'Genuine battery faults (current / voltage / temperature).',
              importance: Importance.high,
              priority: Priority.high,
              category: AndroidNotificationCategory.alarm,
            ),
            iOS: DarwinNotificationDetails(),
          ),
        AlertChannel.alerts => const NotificationDetails(
            android: AndroidNotificationDetails(
              alertsChannelId,
              alertsChannelName,
              channelDescription: 'Status-byte changes and fleet disconnects.',
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
            ),
            iOS: DarwinNotificationDetails(),
          ),
      };

  // --- foreground service ----------------------------------------------------

  /// Ensure the monitoring foreground service matches the decision: start (or
  /// update the count on) it while [shouldRun], stop it otherwise. The caller
  /// derives [shouldRun] from [MonitoringPolicy.serviceShouldRun] (#52) —
  /// monitored batteries > 0, background monitoring ON, no user stop — so a
  /// user stop always wins over the 300 ms tick. No-op off Android.
  Future<void> updateForegroundService({
    required bool shouldRun,
    required int monitoredCount,
  }) async {
    if (!_available || !Platform.isAndroid || _updatingService) return;
    _updatingService = true;
    try {
      if (!shouldRun) {
        await _stopService();
        return;
      }
      final text = 'Monitoring $monitoredCount '
          '${monitoredCount == 1 ? 'battery' : 'batteries'}';
      // Runtime FGS requirements not met / permission denied: recorded;
      // monitoring simply stays foreground-only. Never crashes the caller.
      await guard<void>('foreground service', () async {
        if (_serviceRunning) {
          if (text == _serviceText) return; // unchanged: no re-post
          await FlutterForegroundTask.updateService(
            notificationText: text,
            notificationButtons: _buttons,
          );
          _serviceText = text;
          return;
        }
        final result = await FlutterForegroundTask.startService(
          serviceId: _serviceId,
          serviceTypes: [ForegroundServiceTypes.connectedDevice],
          notificationTitle: 'Battery Reader',
          notificationText: text,
          notificationButtons: _buttons,
          // #52: the task isolate that relays the "Stop monitoring" button.
          callback: monitoringTaskEntry,
        );
        // M10: only a confirmed start flips the flag (a throw leaves it
        // false, so the next tick retries rather than believing a phantom
        // service). #52: a service that is ALREADY running (left over from a
        // previous instance of the page) is adopted rather than retried
        // forever.
        if (result is ServiceRequestSuccess) {
          _serviceRunning = true;
          _serviceText = text;
        } else if (result is ServiceRequestFailure &&
            result.error is ServiceAlreadyStartedException) {
          _serviceRunning = true;
          _serviceText = null; // adopted: text unknown, update once
        }
      }, source: _source);
    } finally {
      _updatingService = false;
    }
  }

  /// #52/#54: the persistent notification's action buttons.
  static const _buttons = [
    NotificationButton(id: stopButtonId, text: 'Stop monitoring'),
    NotificationButton(id: exitButtonId, text: 'Exit'),
  ];

  /// Stop the monitoring service (page dispose). Serialised with
  /// [updateForegroundService] through the same in-flight guard.
  Future<void> stopForegroundService() async {
    if (_updatingService) return;
    _updatingService = true;
    try {
      await _stopService();
    } finally {
      _updatingService = false;
    }
  }

  Future<void> _stopService() async {
    if (!_serviceRunning) return;
    // Best effort — on failure (recorded) it is still believed running and
    // retried next tick.
    await guard<void>('stop foreground service', () async {
      await FlutterForegroundTask.stopService();
      _serviceRunning = false; // M10: only on success
      _serviceText = null;
    }, source: _source);
  }
}

// --- task isolate (#52) ------------------------------------------------------

/// Entry point of the foreground service's task isolate. It runs no periodic
/// work (eventAction is `nothing`); it exists only because the plugin delivers
/// the notification's button presses to the TASK isolate, not the UI one. On
/// "Stop monitoring" it tells the main isolate (which stops BLE and records the
/// user stop) and stops the service itself — so the stop also works when the
/// UI isolate is already gone.
@pragma('vm:entry-point')
void monitoringTaskEntry() {
  FlutterForegroundTask.setTaskHandler(_MonitoringTaskHandler());
}

class _MonitoringTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == AlertNotificationService.stopButtonId) _userStop();
    if (id == AlertNotificationService.exitButtonId) _exit();
  }

  /// #54: Exit — the main isolate (if alive) runs the full shutdown; the
  /// service stops itself either way.
  void _exit() {
    FlutterForegroundTask.sendDataToMain(AlertNotificationService.exitCommand);
    FlutterForegroundTask.stopService();
  }

  /// Android 14+ lets the user swipe the persistent notification away; treat
  /// that as the same explicit stop rather than monitoring on invisibly.
  @override
  void onNotificationDismissed() => _userStop();

  void _userStop() {
    FlutterForegroundTask.sendDataToMain(AlertNotificationService.stopCommand);
    FlutterForegroundTask.stopService();
  }
}
