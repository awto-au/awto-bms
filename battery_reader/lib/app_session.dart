/// The ONE app-level session (#68): the battery manager, persisted settings,
/// aliases, the notification service, the monitoring policy and the 300 ms
/// tick that drives alerts, the foreground service and the list repaint. It
/// used to be the private state of the phone list page; now the responsive
/// shell owns it and BOTH layouts (the phone list page and the desktop
/// two-pane shell) read and mutate the same object. Listeners are notified
/// only when something the list shows actually changed (L16 signature).
library;

import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import 'alert_notifications.dart';
import 'alias_store.dart';
import 'app_theme.dart';
import 'battery_connection.dart';
import 'battery_detail.dart';
import 'battery_log.dart';
import 'battery_manager.dart';
import 'battery_protocol.dart';
import 'diagnostics.dart';
import 'fleet_store.dart';
import 'fmt.dart';
import 'intervals.dart' show YAxisMode, gYAxisMode;
import 'live_indicator.dart';
import 'monitoring_policy.dart';
import 'nav.dart';
import 'notification_service.dart';
import 'ota_update.dart' show OtaLock;
import 'raw_log.dart';
import 'settings_store.dart';
import 'temp_unit.dart';
import 'write_actions.dart' show BusyWrites, showToast;

/// L16: everything the list screen RENDERS, as a flat value list — the per-
/// battery card fields, the detected-device cards, the fleet panel figures and
/// the fleet-control lock reason. The 300 ms ticker rebuilds the page only
/// when this differs from the last one it painted. Pure over the manager.
List<Object?> listPageSignature(
  BatteryManager m,
  AliasStore aliases, {
  required bool demoMode,
  int? nowMs,
}) {
  final sig = <Object?>[
    demoMode,
    m.scanErrorText,
    m.batteries.length,
    m.detectedOthers.length,
    m.isSampling, // #53
  ];
  for (final b in m.batteries) {
    final s = b.state;
    final offline = b.isOffline && !m.isSampling;
    // #61 / #65: only the LEVEL and whether there is data — the status line's
    // ticking age text repaints itself, not the page.
    final live = liveStatusOf(b, sampling: m.isSampling, nowMs: nowMs);
    sig.addAll([
      identityHashCode(b),
      b.profile.name,
      s.serial,
      aliases.aliasFor(s.serial),
      b.inFleet,
      b.alarmActive,
      b.alarmReasons.isEmpty ? null : b.alarmReasons.last,
      offline,
      offline ? relativeTime(b.lastSeenMs, nowMs: nowMs) : s.overTempLatched,
      live.level,
      live.hasData, // #65: the card's figures flip to "—" without data
      b.streamClass, // #62
      s.rssi,
      s.socPercent,
      b.signedCurrent,
      s.remainingAh,
      s.packVoltage,
      effState(s),
      s.chargeMos, // #58 Charge switch badge
      s.dischargeMos, // #58 Output switch badge
    ]);
  }
  for (final d in m.detectedOthers) {
    sig.addAll([d.deviceId, d.family.name, d.name]);
  }
  final agg = m.fleetAggregate;
  sig.addAll([
    m.fleetMembers.length,
    m.combinedSocPercent,
    m.fleetAlarmActive,
    m.fleetStreamingState, // #65: null = "No data"
    m.netPowerW,
    m.netCurrentA,
    m.totalCapacityAh,
    m.totalRemainingAh,
    m.offlineFleetMembers.length,
    agg.chargeAh,
    agg.dischargeAh,
    agg.efc,
    m.fleetGateWriteDisabledReason,
    m.fleetMosWriteDisabledReason(GateAction.dischargeMos, on: true),
    m.fleetChargeOnCount, // #58
    m.fleetOutputOnCount, // #58
    for (final b in m.fleetMembers) b.state.serial,
  ]);
  return sig;
}

class AppSession extends ChangeNotifier with WidgetsBindingObserver {
  // Issue #27: back the fleet with a durable store so membership survives an app
  // restart and is re-applied to each pack as it is (re)discovered.
  final BatteryManager manager;
  final SettingsStore settings;
  // #44: per-battery custom names (local aliases), keyed by serial. Held in one
  // shared store so the list, the detail page and offline favourites all read /
  // edit the same aliases.
  final AliasStore aliases;
  Timer? _ticker;

  /// L16: the signature the page was last painted from.
  List<Object?>? _painted;

  /// #45: system notifications + monitoring foreground service.
  late final AlertNotificationService notifications = AlertNotificationService(
    onOpenBattery: openBySerial,
    onStopRequested: _stopMonitoringFromNotification, // #52
    onExitRequested: _exitFromNotification, // #54
  );

  /// #45: system alert notifications enabled (persisted, default ON). Disabling
  /// only silences the SYSTEM notifications — the in-app beep + red banner and
  /// the monitoring foreground service are unaffected.
  bool alertNotifications = true;

  /// #52: the background-monitoring / user-stop decisions. A fresh session (app
  /// launch) starts with NO user stop, so reopening the app resumes monitoring.
  final MonitoringPolicy policy = MonitoringPolicy();

  /// #52: whether the live BLE loop is currently running (vs. released by
  /// [_reconcileBle]). Demo mode has no BLE and ignores it.
  bool _bleLive = false;

  /// #45: serials seen connected at least once this session, so a "disconnected"
  /// alert only fires for a genuine drop — never a launch-time offline
  /// placeholder that has never been live.
  final Set<String> _everConnected = {};

  /// Live vs. demo (#35). Defaults to LIVE so a real device reads real
  /// batteries; the Settings page toggles Demo for the synthetic fleet with no
  /// hardware. There is no longer a Live/Demo control on the main screen.
  bool demoMode = false;

  bool _exiting = false;
  bool _started = false;
  bool _disposed = false;

  /// #68: how the shell opens a battery (a tapped notification, a deep link):
  /// the phone pushes the detail route, the desktop selects it in the pane.
  /// Null = push the detail route on the root navigator (the phone default).
  void Function(BatteryConnection conn)? openBattery;

  /// A context for toasts and confirm dialogs when the root navigator's is not
  /// available (a page pumped on its own, as the widget tests do).
  BuildContext? Function()? contextProvider;

  AppSession({
    BatteryManager? manager,
    SettingsStore? settings,
    AliasStore? aliases,
  })  : manager =
            manager ?? BatteryManager(fleetStore: SharedPrefsFleetStore()),
        settings = settings ?? SettingsStore(),
        aliases = aliases ?? AliasStore();

  BuildContext? get _context {
    final c = gNavKey.currentContext;
    if (c != null && c.mounted) return c;
    final p = contextProvider?.call();
    return (p != null && p.mounted) ? p : null;
  }

  bool get started => _started;

  /// #41: is the Android foreground service (wake lock) running? Feeds the
  /// firmware-update "device will stay awake" gate.
  bool keepAwake() => notifications.serviceRunning;

  /// #55: control availability per battery, live at each refresh.
  List<String> batteryStatusLines() => [
        for (final b in manager.batteries)
          '${b.gateStatusSummary()} · '
              '${BatteryLogger.instance.alarmSummaryLine(b.state.serial ?? '')}'
      ];

  /// Register the lifecycle observer, restore the persisted choices, start
  /// live / demo and the 300 ms tick. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _restoreThenStart();
    _ticker = Timer.periodic(
        const Duration(milliseconds: 300), (_) => _tick());
  }

  /// Load persisted settings (#35) and fleet membership (#27/#34) BEFORE
  /// starting, so verbose logging + demo-mode choices are honoured and each pack
  /// is restored to the fleet the moment it is (re)discovered.
  Future<void> _restoreThenStart() async {
    final demo = await settings.loadDemoMode();
    RawLogger.instance.enabled = await settings.loadVerbose();
    gUseFahrenheit = await settings.loadUseFahrenheit(); // #43 temp unit
    alertNotifications = await settings.loadAlertNotifications(); // #45
    policy.backgroundMonitoring =
        await settings.loadBackgroundMonitoring(); // #52
    policy.sampleInterval = BackgroundSampleInterval.fromSeconds(
        await settings.loadSampleIntervalS()); // #53
    gYAxisMode =
        YAxisMode.fromFit(await settings.loadChartYAxisFit()); // #70
    await aliases.load(); // #44 per-battery custom names
    await manager.loadFleetMembership();
    // #45: bring the notification subsystem up and, if alerts are enabled, ask
    // for POST_NOTIFICATIONS (Android 13+). A denial is handled gracefully.
    await notifications.init();
    if (alertNotifications) await notifications.requestPermission();
    if (_disposed) return;
    demoMode = demo;
    if (demo) {
      manager.startDemoFleet();
    } else {
      _bleLive = true;
      manager.startLive();
    }
    notifyListeners();
    // #45: honour a cold-start launch-by-tap once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final serial = notifications.pendingLaunchSerial;
      if (serial != null) {
        notifications.pendingLaunchSerial = null;
        openBySerial(serial);
      }
    });
  }

  void _tick() {
    // Beep loudly the moment any battery raises a new alert (fault, unknown-byte
    // change, or disconnect). Edge-triggered via consumeBeep().
    var beep = false;
    for (final b in manager.batteries) {
      if (b.consumeBeep()) beep = true;
      // #62: the not-streaming watchdog — a connected link silent for 10 s
      // gets the AT+V classification probe (cheap when nothing is due).
      b.watchdogTick();
    }
    if (beep) alertBeep();
    // #45: raise/clear Android system notifications for the current conditions,
    // keeping BLE + alerts alive in the background via the foreground service.
    // #52: the service runs ONLY while the policy says so — an explicit user
    // stop or the Background-monitoring toggle OFF wins over this tick, which
    // can therefore never bring the service back.
    notifications.apply(_buildSnapshots(), enabled: alertNotifications);
    final monitored = _monitoredCount();
    notifications.updateForegroundService(
      shouldRun: policy.serviceShouldRun(monitored),
      monitoredCount: monitored,
    );
    // #34: throttled write-back of live telemetry into the persisted favourites.
    manager.persistFleetSnapshot();
    // L16: repaint only when something the page shows actually changed.
    if (_disposed) return;
    final sig = listPageSignature(manager, aliases, demoMode: demoMode);
    if (listEquals(sig, _painted)) return;
    _painted = sig;
    notifyListeners();
  }

  /// #45: alert-relevant snapshot of every known battery, wiring the EXISTING
  /// detection (genuine faults, unknown-byte MAJOR change, fleet disconnect) into
  /// the pure notification-decision logic — no detection is duplicated here.
  List<BatterySnapshot> _buildSnapshots() {
    final out = <BatterySnapshot>[];
    for (final b in manager.batteries) {
      final serial = b.state.serial;
      if (serial == null || serial.isEmpty) continue;
      final connected = b.connState == ConnState.connected;
      if (connected) _everConnected.add(serial);
      out.add(BatterySnapshot(
        serial: serial,
        displayName: displayName(aliases.aliasFor(serial), serial),
        fault: b.hasGenuineFault,
        faultReason: b.genuineFaultKinds.join(', '),
        unknownChange: b.unknownChangedMetrics.isNotEmpty,
        unknownReason: b.unknownChangedMetrics.join(', '),
        // A fleet member that has dropped from a live link this session — but
        // not one the user just disconnected / restarted / factory-reset (H3).
        disconnected: b.inFleet &&
            !connected &&
            _everConnected.contains(serial) &&
            !b.disconnectExpected,
      ));
    }
    return out;
  }

  /// #45: how many batteries we are actively monitoring — any connected pack or
  /// fleet member. The foreground service runs only while this is > 0.
  int _monitoredCount() {
    if (demoMode) return 0; // demo has no real BLE to keep alive
    // #53: while sampling, every pack with a known address is monitored
    // (released between samples, so not "connected").
    final sampling = manager.isSampling;
    return manager.batteries
        .where((b) =>
            b.connState == ConnState.connected ||
            b.inFleet ||
            (sampling &&
                (manager.deviceIdOf(b) ?? b.rememberedRemoteId) != null))
        .length;
  }

  /// #45: deep-link from a tapped notification to the battery. The shell's
  /// [openBattery] decides how (route on the phone, pane on desktop); with no
  /// shell hook the detail route is pushed on the root navigator, popping any
  /// open route first so the target is shown cleanly.
  void openBySerial(String serial) {
    if (_disposed) return; // a late notification tap after dispose
    BatteryConnection? conn;
    for (final b in manager.batteries) {
      if (b.state.serial == serial) {
        conn = b;
        break;
      }
    }
    if (conn == null) return;
    final hook = openBattery;
    if (hook != null) {
      hook(conn);
      return;
    }
    final nav = gNavKey.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(
      MaterialPageRoute(
        builder: (_) => BatteryDetailPage(
            conn: conn!,
            manager: manager,
            aliases: aliases,
            keepAwake: keepAwake),
      ),
    );
  }

  /// #45: toggle system alert notifications from Settings (persisted). Turning
  /// them on requests POST_NOTIFICATIONS; turning them off clears any showing
  /// alert notifications on the next tick.
  void setAlertNotifications(bool enabled) {
    alertNotifications = enabled;
    notifyListeners();
    settings.saveAlertNotifications(enabled);
    if (enabled) notifications.requestPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flush open intervals' end_ms to SQLite when the app leaves the foreground.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      BatteryLogger.instance.flushAll();
      RawLogger.instance.flush();
    }
    // #52: with background monitoring OFF, leaving the foreground (home /
    // recents / swipe) releases every battery; coming back resumes. `inactive`
    // (a dialog, the share sheet) is not a background transition.
    switch (state) {
      case AppLifecycleState.resumed:
        policy.setForeground(true);
        _reconcileBle();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        policy.setForeground(false);
        _reconcileBle();
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// #41: true (and records + toasts the refusal) while a firmware update is
  /// in progress. Pause, Exit, Background-monitoring changes, the Demo
  /// switch and the BLE reconcile (backgrounding / sampling) all go through
  /// this so nothing can drop the OTA link.
  bool _refuseDuringOta(String what) {
    final why = OtaLock.refuseReason;
    if (why == null) return false;
    AppLog.instance.record('BatteryListPage', '$what refused: $why');
    final ctx = _context;
    if (ctx != null) showToast(ctx, '$what is disabled: $why');
    return true;
  }

  /// #52: bring the live BLE loop in line with [MonitoringPolicy.bleShouldRun]:
  /// release the packs (disconnect, stop scanning / reconnecting, stop the
  /// lifetime-totals timer) when it must not run; scan + reconnect when it may.
  /// Demo mode has no BLE to release. Idempotent.
  void _reconcileBle() {
    if (demoMode) return;
    // #41: never release / re-shape the BLE loop mid-flash.
    final ota = OtaLock.refuseReason;
    if (ota != null) {
      AppLog.instance.record('BatteryListPage', 'BLE reconcile skipped: $ota');
      return;
    }
    // #53: backgrounded with a sample interval -> periodic sampling instead
    // of held links. Foreground (or Continuous) -> the continuous loop,
    // immediately.
    if (policy.shouldSample) {
      _bleLive = false;
      manager.enterSampling(Duration(seconds: policy.sampleInterval.seconds));
      return;
    }
    final want = policy.bleShouldRun;
    if (manager.isSampling) {
      _bleLive = want;
      manager.exitSampling(resume: want);
      if (!want) manager.pauseLive();
      return;
    }
    if (want == _bleLive) return;
    _bleLive = want;
    if (want) {
      manager.resumeLive();
    } else {
      manager.pauseLive();
    }
  }

  /// #53: Settings "Background sample interval" (persisted). Takes effect on
  /// the next background transition (in the foreground the app is always
  /// continuous), or right away if already sampling.
  void setSampleInterval(BackgroundSampleInterval v) {
    policy.sampleInterval = v;
    notifyListeners();
    settings.saveSampleIntervalS(v.seconds);
    _reconcileBle();
  }

  /// #52: Settings toggle "Background monitoring" (persisted). OFF stops the
  /// service now and prevents any start; the app then monitors only while in
  /// the foreground. ON clears a previous user stop and lets the tick start it.
  void setBackgroundMonitoring(bool enabled) {
    if (_refuseDuringOta('Background monitoring change')) return;
    policy.setBackgroundMonitoring(enabled);
    notifyListeners();
    settings.saveBackgroundMonitoring(enabled);
    if (!enabled) notifications.stopForegroundService();
    _reconcileBle();
  }

  /// #52: "Pause monitoring (release batteries)" / "Resume monitoring". Pause
  /// stops the foreground service AND the BLE loop (every pack disconnected, an
  /// expected disconnect — no alarm) so another BLE client can take them;
  /// nothing restarts it until the user resumes, turns Background monitoring
  /// on, or relaunches the app. Alerts stay enabled for when it resumes.
  void setMonitoringPaused(bool paused) {
    if (paused == policy.userStopped) return;
    if (_refuseDuringOta(paused ? 'Pause monitoring' : 'Resume monitoring')) {
      return;
    }
    if (paused) {
      policy.stopByUser();
    } else {
      policy.resume();
    }
    notifyListeners();
    if (paused) notifications.stopForegroundService();
    _reconcileBle();
    final ctx = _context;
    if (ctx != null) {
      showToast(
          ctx,
          paused
              ? 'Monitoring paused — batteries released'
              : 'Monitoring resumed');
    }
  }

  /// #52: the "Stop monitoring" action on the persistent notification (the
  /// service has already stopped itself in the task isolate). Same user-stop
  /// state as Pause: the tick will not bring the service back, and BLE lets go
  /// of every pack.
  void _stopMonitoringFromNotification() {
    if (_disposed) return;
    setMonitoringPaused(true);
  }

  /// #54: the "Exit" action on the persistent notification (the service has
  /// already stopped itself). No confirm — the user is not looking at the app.
  void _exitFromNotification() {
    if (_disposed) return;
    exitApp(confirmIfWriting: false);
  }

  /// #54: full shutdown, distinct from Pause (which keeps the app alive):
  /// stop the foreground service, release every battery, cancel the alert
  /// notifications, FLUSH the interval logger + raw log, then terminate. The
  /// user-stopped state is set first so the tick can never restart anything
  /// during the shutdown, and no-resurrection (#52) means nothing brings the
  /// process back. A brief confirm only if a BMS write is in flight.
  Future<void> exitApp({bool confirmIfWriting = true}) async {
    if (_exiting) return;
    // #41: Exit is DISABLED (no "exit anyway") while a firmware update runs —
    // killing the app mid-flash can brick the BMS.
    if (_refuseDuringOta('Exit')) return;
    final ctx = _context;
    if (confirmIfWriting && BusyWrites.inFlight > 0 && ctx != null) {
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (ctx) => AlertDialog(
          title: const Text('Write in progress'),
          content: const Text(
              'A command is still being sent to a battery. Exit anyway?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Exit'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (_exiting) return;
    _exiting = true;
    policy.exitApp();
    _ticker?.cancel();
    _bleLive = false;
    await runExitSequence(
      stopService: notifications.stopForegroundService,
      releaseBle: () async {
        if (!demoMode) await manager.pauseLive();
        manager.disposeAll(); // rows + the lifetime-totals timer
      },
      cancelNotifications: notifications.cancelAll,
      flushLogs: () async {
        BatteryLogger.instance.flushAll();
        await RawLogger.instance.flush();
      },
      terminate: () {
        if (!kIsWeb && Platform.isAndroid) {
          // Finish the activity (with stopWithTask + the service already
          // stopped nothing restarts), then end the process so no cached
          // engine / timer lingers.
          SystemNavigator.pop();
          Future<void>.delayed(
              const Duration(milliseconds: 300), () => exit(0));
        } else {
          exit(0); // desktop: closes the window
        }
      },
      onError: (step, e) => AppLog.instance.record('Exit', '$step failed: $e'),
    );
  }

  /// Switch between Demo and Live from the Settings page (#35). Drives the SAME
  /// startDemoFleet / startLive path the old app-bar toggle did, and persists the
  /// choice so it survives a restart.
  void setDemoMode(bool demo) {
    if (demo == demoMode) return;
    if (_refuseDuringOta('Demo / Live switch')) return;
    demoMode = demo;
    if (demo) {
      _bleLive = false;
      manager.startDemoFleet();
    } else {
      // #52: live only if the policy allows it right now (not paused).
      _bleLive = policy.bleShouldRun;
      if (_bleLive) manager.startLive();
    }
    notifyListeners();
    settings.saveDemoMode(demo);
  }

  /// Flip the temperature display unit (#43) and persist it. Display-only — no
  /// stored value or BMS command changes.
  void setTempUnit(bool useFahrenheit) {
    if (useFahrenheit == gUseFahrenheit) return;
    gUseFahrenheit = useFahrenheit;
    notifyListeners();
    settings.saveUseFahrenheit(useFahrenheit);
  }

  /// #70: the default chart Y-axis mode (FULL 0-based / FIT to the data) and
  /// persist it. Every chart card starts in this mode; the sparklines follow
  /// it always.
  void setYAxisMode(YAxisMode mode) {
    if (mode == gYAxisMode) return;
    gYAxisMode = mode;
    notifyListeners();
    settings.saveChartYAxisFit(mode.isFit);
  }

  /// Fleet membership toggle (issue #10 / #27) — from either layout.
  void toggleFleet(BatteryConnection b) {
    manager.setInFleet(b, !b.inFleet);
    notifyListeners();
  }

  /// Something a layout changed that the other one shows (an alias edit).
  void touch() => notifyListeners();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    BatteryLogger.instance.flushAll();
    RawLogger.instance.flush();
    _ticker?.cancel();
    notifications.stopForegroundService(); // #45
    manager.stopLive();
    manager.disposeAll();
    super.dispose();
  }
}
