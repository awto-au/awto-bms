import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback, SystemSound, SystemSoundType;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'alert_notifications.dart';
import 'alias_store.dart';
import 'battery_charts.dart';
import 'battery_connection.dart';
import 'battery_log.dart';
import 'battery_manager.dart';
import 'battery_protocol.dart';
import 'bms_families.dart';
import 'diagnostics.dart';
import 'diagnostics_page.dart';
import 'fleet_store.dart';
import 'fmt.dart';
import 'health_palette.dart';
import 'intervals.dart' show LookbackWindow, computeRange;
import 'metrics.dart';
import 'notification_service.dart';
import 'raw_log.dart';
import 'settings_store.dart';
import 'sparkline.dart';
import 'temp_unit.dart';
import 'widgets.dart';
import 'write_actions.dart';

export 'fmt.dart'; // shared formatters (fSignedA, pluralBatteries, …)
export 'temp_unit.dart'; // #43: fmtTemp/fChipTemp/etc importable via main.dart
export 'write_actions.dart' show writeFailureReason, runWrite, BusyWrites;

Future<void> main() async {
  // Defensive hygiene (issue #49): run the whole app inside a guarded zone with
  // a FlutterError handler, so a stray BLE/transport/async error is logged and
  // SWALLOWED rather than tearing down the Flutter engine or closing the desktop
  // window. The reconnect loop keeps running through any transient BLE failure.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Framework errors (build/layout/async caught by Flutter) — log, don't crash.
    FlutterError.onError = (details) {
      FlutterError.dumpErrorToConsole(details);
    };
    // Async errors that reach the engine outside a Flutter callback — mark handled
    // so the process stays alive (return true = we dealt with it).
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      // ignore: avoid_print
      print('[UNCAUGHT] $error');
      return true;
    };
    // sqflite ships no desktop implementation, so on Windows/Linux/macOS swap in
    // the FFI factory (WinRT-safe, uses the bundled SQLite) before the interval
    // store opens. Mobile keeps the default sqflite factory untouched. The DB
    // filename and schema are identical either way (see battery_log.dart).
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    // Open the on-device time-series store up front (idempotent; disables itself
    // silently if SQLite is unavailable).
    await BatteryLogger.instance.init();
    // Open the verbose single-file raw log (issue #19). Append-only; resolves a
    // per-platform path and disables itself silently if none is writable.
    await RawLogger.instance.init();
    runApp(const BatteryReaderApp());
  }, (error, stack) {
    // Last resort: anything that escapes to the zone is logged and swallowed.
    // ignore: avoid_print
    print('[ZONE-UNCAUGHT] $error');
  });
}

// Shared palette. Direction tokens (green charging / red discharging / neutral
// idle) are sourced from the ONE app-wide [HealthPalette] (issue #13) so the
// whole app speaks a single colour language. SOC-graded colours come from
// [HealthPalette.colorForSoc]; [kRed] stays the distinct alarm/fault red.
const kGreen = HealthPalette.healthy;
const kRed = HealthPalette.faultRed;
const kIdle = HealthPalette.idle;
const kTrack = Color(0xFF222A35); // dark SOC-bar track (HealthPalette.track resolves per theme)

/// Resolve an effective charge state, filling `unknown` from the flags.
ChargeState effState(BatteryState s) {
  final cs = s.chargeState;
  if (cs != ChargeState.unknown) return cs;
  if (s.chargerConnected == true) return ChargeState.charging;
  if ((s.packCurrent ?? 0) > 0 && s.loadConnected == true) {
    return ChargeState.discharging;
  }
  return ChargeState.idle;
}

/// Loud audible + haptic alert for a fault / unknown-byte change / disconnect.
void alertBeep() {
  // System alert sound (falls back to a click where 'alert' is unsupported) plus
  // a strong haptic buzz, so an error is impossible to miss.
  SystemSound.play(SystemSoundType.alert);
  HapticFeedback.heavyImpact();
}

// Signal-strength icon graded by RSSI (dBm). Higher (closer to 0) is stronger.
IconData rssiIcon(int? v) {
  if (v == null) return Icons.signal_cellular_off;
  if (v >= -60) return Icons.network_cell;
  if (v >= -75) return Icons.signal_cellular_alt;
  if (v >= -88) return Icons.signal_cellular_alt_2_bar;
  return Icons.signal_cellular_alt_1_bar;
}

Color rssiColor(int? v) {
  if (v == null) return Colors.white38;
  if (v >= -65) return kGreen;
  if (v >= -80) return Colors.amber;
  return kRed;
}

/// Small signal-strength chip: an icon graded by RSSI plus the dBm value.
class SignalChip extends StatelessWidget {
  final int? rssi;
  const SignalChip(this.rssi, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = rssiColor(rssi);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(rssiIcon(rssi), size: 16, color: c),
        const SizedBox(width: 3),
        Text(fRssi(rssi), style: TextStyle(fontSize: 12, color: c)),
      ],
    );
  }
}

/// Root navigator key (#45): lets a tapped system notification deep-link into a
/// battery from outside a widget's own context (e.g. on resume/cold-start).
final GlobalKey<NavigatorState> gNavKey = GlobalKey<NavigatorState>();

class BatteryReaderApp extends StatelessWidget {
  const BatteryReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Battery Reader',
      navigatorKey: gNavKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        // Issue #30(b): pin an explicit, opaque scaffold background so no
        // default/placeholder window background (the "zebra" striping) can show
        // through — the app is a solid theme colour edge to edge.
        scaffoldBackgroundColor: scheme.surface,
        useMaterial3: true,
      ),
      home: const BatteryListPage(),
    );
  }
}

// ===========================================================================
// List screen: top half = per-battery bars, bottom half = fleet total.
// ===========================================================================

class BatteryListPage extends StatefulWidget {
  const BatteryListPage({super.key});
  @override
  State<BatteryListPage> createState() => _BatteryListPageState();
}

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
  ];
  for (final b in m.batteries) {
    final s = b.state;
    final offline = b.isOffline;
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
      s.rssi,
      s.socPercent,
      b.signedCurrent,
      s.remainingAh,
      s.packVoltage,
      effState(s),
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
    m.fleetState,
    m.netPowerW,
    m.netCurrentA,
    m.totalCapacityAh,
    m.totalRemainingAh,
    m.offlineFleetMembers.length,
    agg.chargeAh,
    agg.dischargeAh,
    agg.efc,
    m.fleetGateWriteDisabledReason,
    for (final b in m.fleetMembers) b.state.serial,
  ]);
  return sig;
}

class _BatteryListPageState extends State<BatteryListPage>
    with WidgetsBindingObserver {
  // Issue #27: back the fleet with a durable store so membership survives an app
  // restart and is re-applied to each pack as it is (re)discovered.
  final _manager = BatteryManager(fleetStore: SharedPrefsFleetStore());
  final _settings = SettingsStore();
  // #44: per-battery custom names (local aliases), keyed by serial. Held in one
  // shared store so the list, the detail page and offline favourites all read /
  // edit the same aliases.
  final _aliases = AliasStore();
  Timer? _ticker;

  /// L16: the signature the page was last painted from.
  List<Object?>? _painted;

  /// #45: system notifications + monitoring foreground service.
  late final AlertNotificationService _notifications =
      AlertNotificationService(onOpenBattery: _openBySerial);

  /// #45: system alert notifications enabled (persisted, default ON). Disabling
  /// only silences the SYSTEM notifications — the in-app beep + red banner and
  /// the monitoring foreground service are unaffected.
  bool _alertNotifications = true;

  /// #45: serials seen connected at least once this session, so a "disconnected"
  /// alert only fires for a genuine drop — never a launch-time offline
  /// placeholder that has never been live.
  final Set<String> _everConnected = {};

  /// Live vs. demo (#35). Defaults to LIVE so a real device reads real
  /// batteries; the Settings page toggles Demo for the synthetic fleet with no
  /// hardware. There is no longer a Live/Demo control on the main screen.
  bool _demoMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreThenStart();
    _ticker = Timer.periodic(
        const Duration(milliseconds: 300), (_) => _tick());
  }

  /// Load persisted settings (#35) and fleet membership (#27/#34) BEFORE
  /// starting, so verbose logging + demo-mode choices are honoured and each pack
  /// is restored to the fleet the moment it is (re)discovered.
  Future<void> _restoreThenStart() async {
    final demo = await _settings.loadDemoMode();
    RawLogger.instance.enabled = await _settings.loadVerbose();
    gUseFahrenheit = await _settings.loadUseFahrenheit(); // #43 temp unit
    _alertNotifications = await _settings.loadAlertNotifications(); // #45
    await _aliases.load(); // #44 per-battery custom names
    await _manager.loadFleetMembership();
    // #45: bring the notification subsystem up and, if alerts are enabled, ask
    // for POST_NOTIFICATIONS (Android 13+). A denial is handled gracefully.
    await _notifications.init();
    if (_alertNotifications) await _notifications.requestPermission();
    if (!mounted) return;
    setState(() => _demoMode = demo);
    if (demo) {
      _manager.startDemoFleet();
    } else {
      _manager.startLive();
    }
    // #45: honour a cold-start launch-by-tap once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final serial = _notifications.pendingLaunchSerial;
      if (serial != null) {
        _notifications.pendingLaunchSerial = null;
        _openBySerial(serial);
      }
    });
  }

  void _tick() {
    // Beep loudly the moment any battery raises a new alert (fault, unknown-byte
    // change, or disconnect). Edge-triggered via consumeBeep().
    var beep = false;
    for (final b in _manager.batteries) {
      if (b.consumeBeep()) beep = true;
    }
    if (beep) alertBeep();
    // #45: raise/clear Android system notifications for the current conditions,
    // keeping BLE + alerts alive in the background via the foreground service.
    _notifications.apply(_buildSnapshots(), enabled: _alertNotifications);
    _notifications.updateForegroundService(_monitoredCount());
    // #34: throttled write-back of live telemetry into the persisted favourites.
    _manager.persistFleetSnapshot();
    // L16: repaint only when something the page shows actually changed.
    if (!mounted) return;
    final sig = listPageSignature(_manager, _aliases, demoMode: _demoMode);
    if (listEquals(sig, _painted)) return;
    _painted = sig;
    setState(() {});
  }

  /// #45: alert-relevant snapshot of every known battery, wiring the EXISTING
  /// detection (genuine faults, unknown-byte MAJOR change, fleet disconnect) into
  /// the pure notification-decision logic — no detection is duplicated here.
  List<BatterySnapshot> _buildSnapshots() {
    final out = <BatterySnapshot>[];
    for (final b in _manager.batteries) {
      final serial = b.state.serial;
      if (serial == null || serial.isEmpty) continue;
      final connected = b.connState == ConnState.connected;
      if (connected) _everConnected.add(serial);
      out.add(BatterySnapshot(
        serial: serial,
        displayName: displayName(_aliases.aliasFor(serial), serial),
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
    if (_demoMode) return 0; // demo has no real BLE to keep alive
    return _manager.batteries
        .where((b) => b.connState == ConnState.connected || b.inFleet)
        .length;
  }

  /// #45: deep-link from a tapped notification to the battery's detail page. Pops
  /// any open route to root first so the target is shown cleanly.
  void _openBySerial(String serial) {
    BatteryConnection? conn;
    for (final b in _manager.batteries) {
      if (b.state.serial == serial) {
        conn = b;
        break;
      }
    }
    if (conn == null) return;
    final nav = gNavKey.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(
      MaterialPageRoute(
        builder: (_) => BatteryDetailPage(
            conn: conn!, manager: _manager, aliases: _aliases),
      ),
    );
  }

  /// #45: toggle system alert notifications from Settings (persisted). Turning
  /// them on requests POST_NOTIFICATIONS; turning them off clears any showing
  /// alert notifications on the next tick.
  void _setAlertNotifications(bool enabled) {
    setState(() => _alertNotifications = enabled);
    _settings.saveAlertNotifications(enabled);
    if (enabled) _notifications.requestPermission();
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
  }

  /// Switch between Demo and Live from the Settings page (#35). Drives the SAME
  /// startDemoFleet / startLive path the old app-bar toggle did, and persists the
  /// choice so it survives a restart.
  void _setDemoMode(bool demo) {
    if (demo == _demoMode) return;
    setState(() {
      _demoMode = demo;
      if (demo) {
        _manager.startDemoFleet();
      } else {
        _manager.startLive();
      }
    });
    _settings.saveDemoMode(demo);
  }

  /// Flip the temperature display unit (#43) and persist it. Display-only — no
  /// stored value or BMS command changes.
  void _setTempUnit(bool useFahrenheit) {
    if (useFahrenheit == gUseFahrenheit) return;
    setState(() => gUseFahrenheit = useFahrenheit);
    _settings.saveUseFahrenheit(useFahrenheit);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          settings: _settings,
          demoMode: _demoMode,
          onDemoModeChanged: _setDemoMode,
          useFahrenheit: gUseFahrenheit,
          onTempUnitChanged: _setTempUnit,
          alertNotifications: _alertNotifications,
          onAlertNotificationsChanged: _setAlertNotifications,
          scanError: _demoMode ? null : _manager.scanErrorText,
        ),
      ),
    );
  }

  /// #44: edit (or clear) a pack's local custom name. Opens a text-field dialog
  /// pre-filled with the current alias; an empty result reverts to the serial.
  Future<void> _editAlias(String serial) async {
    await editBatteryAlias(context, _aliases, serial);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BatteryLogger.instance.flushAll();
    RawLogger.instance.flush();
    _ticker?.cancel();
    _notifications.stopForegroundService(); // #45
    _manager.stopLive();
    _manager.disposeAll();
    super.dispose();
  }

  void _openDetail(BatteryConnection conn) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            BatteryDetailPage(conn: conn, manager: _manager, aliases: _aliases),
      ),
    );
  }

  // Info sheet for a DETECT-only, other-family BMS (issue #15). This is the only
  // interaction offered for such a device: there is deliberately NO connect /
  // handshake / decode path. DECODE per family is future work.
  void _openDetectedInfo(DetectedDevice d) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _DetectedInfoSheet(device: d),
    );
  }

  @override
  Widget build(BuildContext context) {
    final batteries = _manager.batteries;
    final others = _manager.detectedOthers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batteries'),
        actions: [
          // #35: demo mode and raw logging live in Settings now — no Live/Demo
          // control on the main screen.
          if (_demoMode)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Center(
                child: Text('DEMO',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.amber)),
              ),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      // Issue #30(a): SafeArea keeps the body (and the fleet panel at the bottom)
      // clear of the Android system navigation bar.
      body: PageShell(
        child: Column(
          children: [
            // Top half: the list of batteries.
            Expanded(
              child: (batteries.isEmpty && others.isEmpty)
                  // M13: a failed scan (adapter off / permission denied)
                  // is shown here instead of "Scanning…" forever.
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _demoMode
                              ? 'No batteries'
                              : (_manager.scanErrorText ??
                                  'Scanning for batteries…'),
                          textAlign: TextAlign.center,
                          style: _manager.scanErrorText != null &&
                                  !_demoMode
                              ? const TextStyle(color: kRed)
                              : null,
                        ),
                      ))
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      children: [
                        for (final b in batteries)
                          _SummaryCard(
                            conn: b,
                            alias: _aliases.aliasFor(b.state.serial),
                            onTap: () => _openDetail(b),
                            onToggleFleet: () => setState(
                                () => _manager.setInFleet(b, !b.inFleet)),
                            onEditAlias: b.state.serial == null
                                ? null
                                : () => _editAlias(b.state.serial!),
                          ),
                        // DETECT-only (issue #15): other-family BMS devices,
                        // recognised but not decoded. Muted, non-fleet, tap for
                        // an info sheet — never connected.
                        for (final d in others)
                          _DetectedCard(
                            device: d,
                            onTap: () => _openDetectedInfo(d),
                          ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            // Bottom half: combined total across favourited batteries.
            Expanded(child: _FleetTotal(manager: _manager)),
          ],
        ),
      ),
    );
  }
}

/// One row in the list: serial, a compact SOC bar with figures, a fleet
/// (add/remove) star, tappable to open the detail page.
class _SummaryCard extends StatelessWidget {
  final BatteryConnection conn;
  final VoidCallback onTap;
  final VoidCallback onToggleFleet;
  /// #44: local custom name (null = show the bare serial).
  final String? alias;
  /// #44: opens the rename dialog; null when the pack has no serial yet.
  final VoidCallback? onEditAlias;
  const _SummaryCard({
    required this.conn,
    required this.onTap,
    required this.onToggleFleet,
    this.alias,
    this.onEditAlias,
  });

  @override
  Widget build(BuildContext context) {
    final s = conn.state;
    final dir = ChargeStateStyle.of(effState(s));
    final soc = s.socPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    final alarm = conn.alarmActive;
    // #34: an offline favourite placeholder — show its last-known values dimmed
    // and labelled "offline · last seen …", never as a live/alarm card.
    final offline = conn.isOffline;
    final track = HealthPalette.track(Theme.of(context).brightness);
    // Issue #13: SOC-graded fill / identity accent; a fault overrides to red.
    final health = HealthPalette.socOrFault((soc ?? 0).toDouble(), fault: alarm);
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];

    return Card(
      clipBehavior: Clip.antiAlias,
      color: alarm ? const Color(0xFF3A1414) : null,
      shape: alarm
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: kRed, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Identity accent (issue #13): a SOC-graded left edge on the card.
              Container(width: 5, color: health),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            // #44: long-press the name to rename the pack.
                            child: GestureDetector(
                              onLongPress: onEditAlias,
                              child: Text(
                                '${conn.profile.name}   •   ${displayName(alias, s.serial)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          // #44: explicit rename affordance beside the name.
                          if (onEditAlias != null)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Rename',
                              icon: const Icon(Icons.edit,
                                  size: 16, color: Colors.white38),
                              onPressed: onEditAlias,
                            ),
                          // RSSI/signal chip on the per-battery list card
                          // (restored). Offline placeholders have no live signal.
                          if (!offline)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: SignalChip(s.rssi),
                            ),
                          if (alarm)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.error, color: kRed, size: 20),
                            ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: conn.inFleet
                                ? 'Remove from fleet'
                                : 'Add to fleet',
                            icon: Icon(
                              conn.inFleet ? Icons.star : Icons.star_border,
                              color:
                                  conn.inFleet ? Colors.amber : Colors.white38,
                            ),
                            onPressed: onToggleFleet,
                          ),
                        ],
                      ),
                      if (alarm && conn.alarmReasons.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2, bottom: 2),
                          child: Text(
                            conn.alarmReasons.last,
                            style: const TextStyle(
                                color: kRed,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      // #50: latched over-temperature protection — a WARNING
                      // (amber), not a live fault. Cleared by a BMS restart.
                      if (!offline && s.overTempLatched)
                        const Padding(
                          padding: EdgeInsets.only(top: 2, bottom: 2),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber,
                                  size: 14, color: Colors.amber),
                              SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  'Over-temp protection latched — charging may '
                                  'be inhibited. Restart BMS to clear.',
                                  style: TextStyle(
                                      color: Colors.amber,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (offline)
                        Padding(
                          padding: const EdgeInsets.only(top: 2, bottom: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.cloud_off,
                                  size: 13, color: Colors.white38),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  'Offline · last seen ${relativeTime(conn.lastSeenMs)}',
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 2),
                      // Prominent (issue #16): SOC %, signed current, remaining
                      // Ah. Voltage is demoted to the small line below. Offline
                      // placeholders show last-known values dimmed (#34).
                      Opacity(
                       opacity: offline ? 0.45 : 1.0,
                       child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      SocBar(
                        frac: frac,
                        fill: health,
                        track: track,
                        height: 46,
                        radius: 12,
                        overlayPadding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        overlay: Row(
                          children: [
                            // SOC, current and remaining Ah on ONE line
                            // (#28 fix): "93%  ·  -12.3 A out  ·  87 Ah".
                            Text(
                              fPct(soc),
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: HealthPalette.onHealth,
                                shadows: shadow,
                              ),
                            ),
                            const Spacer(),
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  '${fSignedA(conn.signedCurrent)}  ·  ${fAh(s.remainingAh)}',
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: HealthPalette.onHealth,
                                    shadows: shadow,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Issue #28: the real numeric values, readable at a glance
                      // with units — pack voltage and signed current sit on their
                      // own line (SOC % is the big number in the bar above). The
                      // status dot/word keeps the charge direction.
                      StatusLine(
                        color: dir.color,
                        label: dir.label,
                        dotSize: 8,
                        gap: 6,
                        fontSize: 12,
                        trailing: [
                          Text(fV(s.packVoltage),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                          const Text('  ·  ',
                              style: TextStyle(color: Colors.white38)),
                          Text(fSignedA(conn.signedCurrent),
                              style: TextStyle(
                                  color: dir.color,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                        ],
                       ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// DETECT-only list entry (issue #15) for an other-family BMS recognised in
/// range but NOT supported for decode. Visually MUTED and clearly distinct from
/// a real (JoySuny) battery card: no SOC bar, no fleet star, no telemetry — just
/// the family, the advertised name, RSSI and a "detected · not yet supported"
/// badge. Tapping opens an info sheet. It is never connected or decoded.
class _DetectedCard extends StatelessWidget {
  final DetectedDevice device;
  final VoidCallback onTap;
  const _DetectedCard({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const muted = Colors.white38;
    return Card(
      // Muted, semi-transparent surface so it visibly recedes behind real packs.
      color: Colors.white.withValues(alpha: 0.03),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              const Icon(Icons.help_outline, color: muted, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Issue #29: no RSSI/dBm on the main-screen card (still shown
                    // in the tapped info sheet's diagnostics).
                    Text(
                      device.family.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.name.isNotEmpty ? device.name : device.deviceId,
                      style: const TextStyle(color: muted, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    // The badge that sets this entry apart from a supported pack.
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'detected · not yet supported',
                        style: TextStyle(
                          color: muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Info sheet for a DETECT-only device: family, advertised name, the UUIDs we
/// recognise it by, and a plain statement that decoding this family isn't
/// implemented yet. No actions — this family is never connected or decoded.
class _DetectedInfoSheet extends StatelessWidget {
  final DetectedDevice device;
  const _DetectedInfoSheet({required this.device});

  @override
  Widget build(BuildContext context) {
    final f = device.family;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, color: Colors.white54),
              const SizedBox(width: 10),
              Expanded(
                child: Text(f.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              SignalChip(device.rssi),
            ],
          ),
          const SizedBox(height: 12),
          KvRow.info('Advertised name',
              device.name.isNotEmpty ? device.name : '(none)'),
          KvRow.info('Device id', device.deviceId),
          if (f.serviceUuid != null)
            KvRow.info('Service', _short(f.serviceUuid!)),
          if (f.notifyChars.isNotEmpty)
            KvRow.info('Notify', f.notifyChars.map(_short).join(', ')),
          if (f.writeChars.isNotEmpty)
            KvRow.info('Write', f.writeChars.map(_short).join(', ')),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Decoding this battery family isn\'t implemented yet. The app '
              'recognises it in range but only fully supports JoySuny packs '
              '(Sphere / RV). Support for this family is future work.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  // Show the recognisable 16-bit part of a stock UUID for readability.
  static String _short(String uuid) {
    final m = RegExp(r'^0000([0-9a-fA-F]{4})-0000-1000-8000-00805f9b34fb$')
        .firstMatch(uuid);
    return m != null ? '0x${m.group(1)!.toUpperCase()}' : uuid;
  }
}

// ===========================================================================
// Settings page (#35): demo mode, verbose raw logging + send-to-developer and
// the temperature unit. Reached via the app-bar gear. (#37 removed the
// lifetime-totals toggle — those totals are now always maintained cheaply.)
// ===========================================================================

/// #44: rename dialog for a pack's local custom name. Pre-fills the current
/// alias; Save writes through the shared [AliasStore] (an empty field clears the
/// alias back to the bare serial). Purely local — nothing sent to the BMS.
Future<void> editBatteryAlias(
    BuildContext context, AliasStore aliases, String serial) async {
  final controller =
      TextEditingController(text: aliases.aliasFor(serial) ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename battery'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(serial,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Custom name',
              hintText: 'e.g. Left battery',
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          const SizedBox(height: 4),
          const Text('Leave empty to clear back to the serial.',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result != null) await aliases.setAlias(serial, result);
}

class SettingsPage extends StatefulWidget {
  final SettingsStore settings;
  final bool demoMode;
  final ValueChanged<bool> onDemoModeChanged;
  /// #43: temperature-unit toggle (°F when true, else °C).
  final bool useFahrenheit;
  final ValueChanged<bool> onTempUnitChanged;
  /// #45: system alert notifications toggle (persisted, default ON).
  final bool alertNotifications;
  final ValueChanged<bool> onAlertNotificationsChanged;
  /// M13: the manager's current scan error (for the Diagnostics page).
  final String? scanError;
  const SettingsPage({
    super.key,
    required this.settings,
    required this.demoMode,
    required this.onDemoModeChanged,
    required this.useFahrenheit,
    required this.onTempUnitChanged,
    required this.alertNotifications,
    required this.onAlertNotificationsChanged,
    this.scanError,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late bool _demo = widget.demoMode;
  late bool _fahrenheit = widget.useFahrenheit;
  late bool _alerts = widget.alertNotifications; // #45
  bool _sharing = false;

  Future<void> _sendToDeveloper() async {
    final path = RawLogger.instance.path;
    if (path == null) return;
    setState(() => _sharing = true);
    try {
      await RawLogger.instance.flush(); // buffered lines to disk first
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          text: 'Battery Reader raw log',
        ),
      );
    } catch (e) {
      if (mounted) showToast(context, 'Could not share: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _copyPath() async {
    final path = RawLogger.instance.path;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) showToast(context, 'Path copied to clipboard');
  }

  void _openDiagnostics() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiagnosticsPage(scanError: widget.scanError),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logger = RawLogger.instance;
    final path = logger.path;
    final store = BatteryLogger.instance;
    final appLog = AppLog.instance;
    final diagSummary = diagnosticsSummary(
      dbDegraded: store.dbDegraded,
      lastDbError: store.lastDbError,
      entryCount: appLog.length,
      totalRecorded: appLog.totalRecorded,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: PageShell(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // #46: everyday settings first; the Demo-mode section is LAST.
            _sectionHeader(context, 'Raw logging'),
            SwitchListTile(
              secondary: const Icon(Icons.description_outlined),
              title: const Text('Verbose raw logging'),
              subtitle: const Text(
                  'Capture every raw BLE notification, decoded frame, sent '
                  'command and dropped byte. Turn off if the file grows large.'),
              value: logger.enabled,
              onChanged: (v) {
                setState(() => logger.enabled = v);
                widget.settings.saveVerbose(v);
              },
            ),
            ListTile(
              leading: _sharing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share),
              title: const Text('Send to developer'),
              subtitle: const Text('Share the raw-log file'),
              enabled: path != null && !_sharing,
              onTap: (path == null || _sharing) ? null : _sendToDeveloper,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // M9: current size + the rotation cap, so the user can
                  // see how big the file is before sharing it.
                  Text(
                      'Log file · ${RawLogger.fmtSize(logger.sizeBytes)}'
                      ' (rotates at ${RawLogger.fmtSize(logger.maxBytes)}'
                      ' to ${RawLogger.rotatedFileName})',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          path ?? '(not available on this platform)',
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ),
                      if (path != null)
                        IconButton(
                          tooltip: 'Copy path',
                          icon: const Icon(Icons.copy, size: 16),
                          onPressed: _copyPath,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(),
            // Pass C1: Diagnostics — the recorded best-effort failures,
            // the interval-store health (M7) and the raw-log size (M9).
            _sectionHeader(context, 'Diagnostics'),
            if (store.dbDegraded)
              ListTile(
                leading: const Icon(Icons.error_outline, color: kRed),
                title: const Text('Logging is failing',
                    style: TextStyle(color: kRed)),
                subtitle: Text(
                    '${store.lastDbError ?? 'unknown error'} — the '
                    'history store is retrying automatically; live '
                    'values and the last hour of charts still work.'),
                onTap: _openDiagnostics,
              ),
            ListTile(
              leading: Icon(
                store.dbDegraded
                    ? Icons.report_problem_outlined
                    : Icons.bug_report_outlined,
                color: store.dbDegraded ? kRed : null,
              ),
              title: const Text('Diagnostics'),
              subtitle: Text(diagSummary),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openDiagnostics,
            ),
            const Divider(),
            // #45: system alert notifications (Faults + Alerts channels).
            _sectionHeader(context, 'Notifications'),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Alert notifications'),
              subtitle: const Text(
                  'Show faults and alerts as system notifications, including '
                  'when the app is in the background. Off keeps the in-app '
                  'beep and red banner only.'),
              value: _alerts,
              onChanged: (v) {
                setState(() => _alerts = v);
                widget.onAlertNotificationsChanged(v);
              },
            ),
            const Divider(),
            // #43: temperature display unit (°C / °F). Display-only.
            _sectionHeader(context, 'Temperature'),
            SwitchListTile(
              secondary: const Icon(Icons.thermostat),
              title: const Text('Show temperatures in °F'),
              subtitle: const Text(
                  'Off = °C (default). Display-only — stored values stay in '
                  '°C and nothing is sent to the BMS.'),
              value: _fahrenheit,
              onChanged: (v) {
                setState(() => _fahrenheit = v);
                widget.onTempUnitChanged(v);
              },
            ),
            const Divider(),
            // #46: Demo mode is the LAST section on the page.
            _sectionHeader(context, 'Mode'),
            SwitchListTile(
              secondary: const Icon(Icons.science_outlined),
              title: const Text('Demo mode'),
              subtitle: const Text(
                  'Synthetic fleet with no hardware. Off = Live (scan BLE).'),
              value: _demo,
              onChanged: (v) {
                setState(() => _demo = v);
                widget.onDemoModeChanged(v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700)),
      );
}

/// Bottom panel: one combined gauge + totals across favourited batteries.
class _FleetTotal extends StatelessWidget {
  final BatteryManager manager;
  const _FleetTotal({required this.manager});

  @override
  Widget build(BuildContext context) {
    final favs = manager.fleetMembers;
    final soc = manager.combinedSocPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    // Issue #21: the fleet bar MIRRORS the batteries. Its fill uses the SAME
    // SOC-graded palette and the SAME thresholds as every per-battery bar —
    // HealthPalette.socOrFault on the combined fleet SOC, with the identical
    // fault-red override (any member in alarm). No separate fleet colour set.
    final alarm = manager.fleetAlarmActive;
    final color =
        HealthPalette.socOrFault((soc ?? 0).toDouble(), fault: alarm);
    // Direction word ("Charging"/"Idle · no load"/"Discharging") still comes
    // from the net-power state; only the COLOUR is now SOC-graded.
    final label = ChargeStateStyle.of(manager.fleetState).label;
    final net = manager.netPowerW;
    final netText = net == 0
        ? '0 W'
        : '${net.abs().toStringAsFixed(0)} W ${net > 0 ? 'in' : 'out'}';
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];

    // The fleet-total panel lives in a fixed-height Expanded slot (half the home
    // screen). Its row count grows (capacity totals, offline members, aggregates,
    // fleet controls), so it must SCROLL rather than overflow the slot — this was
    // the "BOTTOM OVERFLOWED BY N PIXELS" bar (mis-filed as the #30 "zebra"
    // background). SingleChildScrollView gives it a viewport at any phone height.
    return SingleChildScrollView(
      child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.dashboard_customize_outlined, size: 18),
              const SizedBox(width: 8),
              Text('Fleet total · ${pluralBatteries(favs.length)}',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          SocBar(
            frac: frac,
            fill: color,
            track: kTrack,
            height: 84,
            radius: 16,
            overlayPadding: const EdgeInsets.symmetric(horizontal: 18),
            overlay: Row(
              children: [
                Text(
                  soc == null ? '—' : '$soc%',
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: shadow,
                  ),
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(netText,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            shadows: shadow)),
                    Text('${manager.netCurrentA.abs().toStringAsFixed(1)} A',
                        style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white,
                            shadows: shadow)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          KvRow('Status', label),
          // #36: total battery capacity = sum of every fleet member's fullAh
          // (offline members keep contributing their last-known fullAh, so the
          // total stays stable when a pack drops off), and total remaining Ah.
          KvRow('Total capacity', fAh(manager.totalCapacityAh)),
          KvRow('Total remaining', fAh(manager.totalRemainingAh)),
          // #34: offline members are shown in membership with last-known values
          // but excluded from the live net current/power on the gauge above.
          if (manager.offlineFleetMembers.isNotEmpty)
            KvRow('Offline members',
                '${manager.offlineFleetMembers.length} of ${favs.length} (excluded from live power)'),
          // Issue #31: net current is already shown once on the gauge above, so
          // the redundant "Net current" row is gone.
          // Issue #29: the fleet signal (dBm) row is removed from this panel.
          // #37: LIFETIME totals are always maintained (incrementally, cheaply)
          // and always shown — no toggle. Grouped under their own sub-header so
          // they are not confused with the live "Fleet total" gauge above.
          const Divider(height: 20),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('Lifetime totals',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white70)),
          ),
          ...() {
            final agg = manager.fleetAggregate;
            return [
              KvRow('Lifetime charged', fAh(agg.chargeAh)),
              KvRow('Lifetime discharged', fAh(agg.dischargeAh)),
              KvRow('Equivalent full cycles', fCycles(agg.efc)),
            ];
          }(),
          const Divider(height: 20),
          _FleetControls(manager: manager),
        ],
      ),
      ),
    );
  }
}

/// Fleet-level write controls (issue #11). Enabled ONLY when every fleet member
/// is currently connected; otherwise disabled with the reason shown. All actions
/// go through the same confirmation + safety rules as the per-battery controls
/// ([runWriteAction] with [fleetOutputAction]), and destructive ones list every
/// affected serial.
class _FleetControls extends StatefulWidget {
  final BatteryManager manager;
  const _FleetControls({required this.manager});

  @override
  State<_FleetControls> createState() => _FleetControlsState();
}

class _FleetControlsState extends State<_FleetControls> {
  /// M4: a fleet write in flight (tap -> confirm -> every member written).
  /// Both buttons are disabled meanwhile so a double-tap cannot overlap two
  /// fleet-wide writes (both share the one fleet busy key).
  final _busy = BusyWrites();

  BatteryManager get manager => widget.manager;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // C1: fleet OUTPUT buttons are real gate writes — also disabled while any
    // member lacks a fresh BAL_STATUS (the reason names the member).
    final reason = _busy.any
        ? 'Fleet write in progress…'
        : manager.fleetGateWriteDisabledReason;
    final enabled = reason == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.hub_outlined, size: 18),
            const SizedBox(width: 8),
            Text('Fleet controls',
                style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        if (!enabled)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const Icon(Icons.lock_outline, size: 15, color: Colors.amber),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(reason,
                      style: const TextStyle(
                          color: Colors.amber, fontSize: 12)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.power_settings_new, size: 18),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kRed,
                  side: const BorderSide(color: kRed),
                ),
                onPressed: !enabled
                    ? null
                    : () => runWriteAction(
                          context,
                          fleetOutputAction(manager, on: false),
                          busy: _busy,
                          onChanged: _changed,
                        ),
                label: const Text('All output OFF'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.power, size: 18),
                onPressed: !enabled
                    ? null
                    : () => runWriteAction(
                          context,
                          fleetOutputAction(manager, on: true),
                          busy: _busy,
                          onChanged: _changed,
                        ),
                label: const Text('All output ON'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ===========================================================================
// Detail screen: the full single-battery view.
// ===========================================================================

class BatteryDetailPage extends StatefulWidget {
  final BatteryConnection conn;
  final BatteryManager manager;
  /// #44: shared per-battery custom names, read for the app-bar title and
  /// written by the rename dialog.
  final AliasStore aliases;
  const BatteryDetailPage({
    super.key,
    required this.conn,
    required this.manager,
    required this.aliases,
  });
  @override
  State<BatteryDetailPage> createState() => _BatteryDetailPageState();
}

class _BatteryDetailPageState extends State<BatteryDetailPage> {
  StreamSubscription<BatteryEvent>? _sub;

  /// L16: telemetry arrives ~8 events/s; rebuilds are coalesced to at most one
  /// per [rebuildEvery] (~4 Hz). The alert beep is never delayed.
  static const rebuildEvery = Duration(milliseconds: 250);
  Timer? _rebuild;

  // --- inline sparklines (issue #14) ---------------------------------------
  // The metrics summarised as per-row sparklines come from the metric
  // catalogue ([sparkMetrics]). One shared window selector drives them all.

  LookbackWindow _sparkWindow = LookbackWindow.h24; // default = last 24 hours
  Map<String, List<ReadingInterval>> _spark = const {};
  int _sparkFrom = 0;
  int _sparkTo = 0;
  Timer? _sparkTimer;

  /// M6: why the last sparkline load failed (DB error), or null. Shown as a
  /// small note in the Trends card instead of a silently blank set of rows.
  String? _sparkError;

  /// M6: a sparkline load in flight — the 3 s timer never overlaps a slow one.
  bool _sparkLoading = false;

  /// M4: in-flight write flags shared by the Controls section and the latched
  /// over-temp card (both can send Restart BMS).
  final _busy = BusyWrites();

  @override
  void initState() {
    super.initState();
    _sub = widget.conn.events.listen((_) {
      if (widget.conn.consumeBeep()) alertBeep();
      _scheduleRebuild();
    });
    _loadSpark();
    // Keep the sparkline tails moving without a heavy DB re-scan every event.
    _sparkTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _loadSpark());
  }

  /// L16: coalesce per-event repaints into one every [rebuildEvery].
  void _scheduleRebuild() {
    if (_rebuild != null) return;
    _rebuild = Timer(rebuildEvery, () {
      _rebuild = null;
      if (mounted) setState(() {});
    });
  }

  /// Load the sparkline series. M6: a DB error is caught and shown, never
  /// left as an unhandled async error from the periodic timer; the in-flight
  /// flag is always reset in `finally`.
  Future<void> _loadSpark() async {
    final serial = widget.conn.state.serial;
    if (serial == null || serial.isEmpty) return;
    if (_sparkLoading) return;
    _sparkLoading = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final span = _sparkWindow.spanMs;
      final since = span == null ? 0 : now - span;
      final series = await BatteryLogger.instance
          .multiSeries(serial, sparkMetricKeys, sinceMs: since);
      if (!mounted) return;
      final range = computeRange(series.values, span, now);
      setState(() {
        _spark = series;
        _sparkFrom = range.fromMs;
        _sparkTo = range.toMs;
        _sparkError = null;
      });
    } catch (e) {
      AppLog.instance
          .record('Sparklines', 'history load for $serial failed: $e');
      if (mounted) setState(() => _sparkError = '$e');
    } finally {
      _sparkLoading = false;
    }
  }

  void _setSparkWindow(LookbackWindow w) {
    setState(() => _sparkWindow = w);
    _loadSpark();
  }

  @override
  void dispose() {
    _sub?.cancel(); // note: does not dispose the connection (owned by manager)
    _sparkTimer?.cancel();
    _rebuild?.cancel();
    super.dispose();
  }

  /// #44: rename this pack from the detail page (pencil in the app bar).
  Future<void> _editAlias() async {
    final serial = widget.conn.state.serial;
    if (serial == null || serial.isEmpty) return;
    await editBatteryAlias(context, widget.aliases, serial);
    if (mounted) setState(() {});
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The key/value rows of one detail section, straight from the catalogue.
  List<Widget> _rows(DetailSection section) => [
        for (final m in detailMetrics(section))
          KvRow(m.labelOnDetail, m.detailValue(widget.conn)),
      ];

  @override
  Widget build(BuildContext context) {
    final s = widget.conn.state;
    final alarm = widget.conn.alarmActive;
    final alias = widget.aliases.aliasFor(s.serial);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: alarm ? kRed : null,
        foregroundColor: alarm ? Colors.white : null,
        title: Text(
          s.serial == null ? 'Battery' : displayName(alias, s.serial),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // #44: rename (local custom name) from the detail page.
          if (s.serial != null)
            IconButton(
              tooltip: 'Rename',
              icon: const Icon(Icons.edit),
              onPressed: _editAlias,
            ),
          // Manual fleet membership (issue #10): toggle from the detail page too.
          IconButton(
            tooltip: widget.conn.inFleet ? 'Remove from fleet' : 'Add to fleet',
            icon: Icon(
              widget.conn.inFleet ? Icons.star : Icons.star_border,
              color: widget.conn.inFleet ? Colors.amber : null,
            ),
            onPressed: () => setState(() => widget.manager
                .setInFleet(widget.conn, !widget.conn.inFleet)),
          ),
          if (s.serial != null)
            IconButton(
              tooltip: 'Charts / history',
              icon: const Icon(Icons.show_chart),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BatteryChartsPage(serial: s.serial!),
                ),
              ),
            ),
        ],
      ),
      // Issue #30(a): keep the scrolling detail clear of the system nav bar.
      body: PageShell(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (alarm)
              _AlarmBanner(
                reasons: widget.conn.alarmReasons,
                onAcknowledge: () => setState(widget.conn.acknowledgeAlarms),
              ),
            // #50: latched over-temperature protection warning, with the
            // restart control (same confirmation) right there to clear it.
            if (s.overTempLatched)
              _LatchedOverTempCard(
                conn: widget.conn,
                busy: _busy,
                onChanged: _changed,
              ),
            _BatteryGauge(
              conn: widget.conn,
              alias: alias,
              socSeries: _spark[Metric.soc] ?? const [],
              fromMs: _sparkFrom,
              toMs: _sparkTo,
            ),
            const SizedBox(height: 12),
            _TrendsSection(
              window: _sparkWindow,
              onWindow: _setSparkWindow,
              series: _spark,
              fromMs: _sparkFrom,
              toMs: _sparkTo,
              conn: widget.conn,
              error: _sparkError,
            ),
            _Section('Pack', _rows(DetailSection.pack)),
            _Section('Capacity', _rows(DetailSection.capacity)),
            _Section('Cells', [
              if (s.cellsMv.isEmpty)
                const Text('—', style: TextStyle(color: Colors.white70))
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final mv in s.cellsMv)
                        Text('${(mv / 1000).toStringAsFixed(3)} V',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              const Divider(height: 20),
              ..._rows(DetailSection.cells),
            ]),
            _Section('Temperature', _rows(DetailSection.temperature)),
            _Section('Gates & status', _rows(DetailSection.gates)),
            _Warnings('Current alarms', s.currentWarnings),
            _Warnings('Voltage alarms', s.voltageWarnings),
            _Warnings('Temperature alarms', s.temperatureWarnings),
            _ControlsSection(
              conn: widget.conn,
              busy: _busy,
              onChanged: _changed,
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

/// Detail-page header: a fully LINEAR state-of-charge presentation (no rings or
/// gauges — the user considers those bogus). The three PROMINENT values (issue
/// #16) are the big SOC % (SOC-graded colour, issue #13; a fault overrides to
/// red), the signed Current and the remaining capacity Ah. Beneath the numbers
/// a HORIZONTAL SOC bar and the SOC LINE graph over time (the shared sparkline)
/// show charge level and its recent history. Voltage/power/status stay as small
/// secondary details underneath.
class _BatteryGauge extends StatelessWidget {
  final BatteryConnection conn;
  final String? alias; // #44 local custom name
  final List<ReadingInterval> socSeries;
  final int fromMs;
  final int toMs;
  const _BatteryGauge({
    required this.conn,
    required this.socSeries,
    required this.fromMs,
    required this.toMs,
    this.alias,
  });

  @override
  Widget build(BuildContext context) {
    final state = conn.state;
    final profile = conn.profile;
    final dir = ChargeStateStyle.of(effState(state));
    final soc = state.socPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    final cap = state.fullAh;
    final alarm = conn.alarmActive;
    // Issue #13: SOC colour is graded; an active fault overrides to red.
    final health = HealthPalette.socOrFault((soc ?? 0).toDouble(), fault: alarm);
    final track = HealthPalette.track(Theme.of(context).brightness);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${profile.name}   •   ${displayName(alias, state.serial)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, letterSpacing: 0.2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(cap == null ? '— Ah' : '${cap.toStringAsFixed(0)} Ah',
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 16),
            // The three prominent values, side by side: big SOC % (health
            // colour) + Current + remaining Ah.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      soc == null ? '—' : '$soc',
                      style: TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                        color: health,
                      ),
                    ),
                    const Text('% SOC',
                        style: TextStyle(fontSize: 12, color: Colors.white54)),
                  ],
                ),
                const SizedBox(width: 24),
                // The other two prominent values: current + remaining Ah.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Current',
                          style: TextStyle(fontSize: 12, color: Colors.white54)),
                      Text(
                        fSignedA(conn.signedCurrent),
                        style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: dir.color),
                      ),
                      const SizedBox(height: 10),
                      const Text('Remaining',
                          style: TextStyle(fontSize: 12, color: Colors.white54)),
                      Text(
                        fAh(state.remainingAh),
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Horizontal SOC bar (linear fill on a track), coloured like the %.
            SocBar(
              frac: frac,
              fill: health,
              track: track,
              height: 14,
              radius: 8,
            ),
            const SizedBox(height: 12),
            // SOC LINE graph over time (reuse the shared sparkline).
            Row(
              children: [
                const Text('SOC over time',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
                const Spacer(),
                Text(soc == null ? '—' : '$soc%',
                    style: TextStyle(
                        fontSize: 12,
                        color: health,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Sparkline(
              intervals: socSeries,
              fromMs: fromMs,
              toMs: toMs,
              color: health,
              height: 44,
            ),
            const SizedBox(height: 12),
            // Secondary details (demoted): voltage, power and status.
            StatusLine(
              color: dir.color,
              label: dir.label,
              dotSize: 10,
              gap: 8,
              trailing: [
                Text('${fV(state.packVoltage)}  ·  ${fW(state.power)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The per-row sparklines section (issue #14). One shared period selector drives
/// every row; each row shows its metric's recent history as an alpha-blended
/// held/step sparkline with the ACTUAL current value large beside it. Which
/// rows, in which order and colour, comes from the metric catalogue.
class _TrendsSection extends StatelessWidget {
  final LookbackWindow window;
  final ValueChanged<LookbackWindow> onWindow;
  final Map<String, List<ReadingInterval>> series;
  final int fromMs;
  final int toMs;
  final BatteryConnection conn;

  /// M6: the last history-load error, or null.
  final String? error;

  const _TrendsSection({
    required this.window,
    required this.onWindow,
    required this.series,
    required this.fromMs,
    required this.toMs,
    required this.conn,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.timeline, size: 18),
                const SizedBox(width: 8),
                Text('Trends', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                const Text('window',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<LookbackWindow>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  for (final w in LookbackWindow.values)
                    ButtonSegment(value: w, label: Text(w.label)),
                ],
                selected: {window},
                showSelectedIcon: false,
                onSelectionChanged: (sel) => onWindow(sel.first),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 15, color: kRed),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text("Couldn't load history — $error",
                          style: const TextStyle(color: kRed, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2),
                    ),
                  ],
                ),
              ),
            const Divider(height: 20),
            for (final m in sparkMetrics)
              _SparkRow(
                label: m.label,
                value: m.format(conn),
                intervals: series[m.key] ?? const [],
                fromMs: fromMs,
                toMs: toMs,
                color: m.sparkColorFor(conn),
                centreZero: m.centreZero,
              ),
          ],
        ),
      ),
    );
  }
}

/// One trend row: label, an inline sparkline (expanded), and the actual current
/// value large/clear with units on the right.
class _SparkRow extends StatelessWidget {
  final String label;
  final String value;
  final List<ReadingInterval> intervals;
  final int fromMs;
  final int toMs;
  final Color color;
  final bool centreZero;

  const _SparkRow({
    required this.label,
    required this.value,
    required this.intervals,
    required this.fromMs,
    required this.toMs,
    required this.color,
    this.centreZero = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          Expanded(
            child: Sparkline(
              intervals: intervals,
              fromMs: fromMs,
              toMs: toMs,
              color: color,
              centreZero: centreZero,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 96,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> rows;
  const _Section(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            ...rows,
          ],
        ),
      ),
    );
  }
}

/// Per-battery write controls (issues #12, #17). Every button builds a
/// CMD_GATE_CONTROL frame that flips ONLY its target gate (other gates keep
/// their live values) and sends it on FCF1 — always behind a confirmation that
/// names the battery + exact action. Destructive actions require a second
/// "Are you sure?". Individual controls stay available regardless of fleet
/// state. Includes the heat-up (heater) gate, sleep mode (#42) and the rated-
/// capacity write (#38, CMD_BATTERY); each write is confirmed and read back.
/// Sleep-ON, output-off and factory reset double-confirm and name the serial.
/// Every control is a [WriteAction] descriptor run by [runWriteAction].
class _ControlsSection extends StatelessWidget {
  final BatteryConnection conn;
  final VoidCallback onChanged;

  /// M4: in-flight write flags (shared with the latched over-temp card).
  final BusyWrites busy;
  const _ControlsSection({
    required this.conn,
    required this.onChanged,
    required this.busy,
  });

  String get _serial => serialOf(conn);

  Future<void> _run(BuildContext context, WriteAction action) =>
      runWriteAction(context, action, busy: busy, onChanged: onChanged);

  /// Issue #26: the single Output control that mirrors the vendor setMos (both
  /// FETs move together). Turning output OFF is destructive (double-confirm,
  /// names the serial); turning it ON is a single confirm. Read-back + warning
  /// (issue #24) are part of [outputAction].
  Widget _outputRow(BuildContext context, {required bool enabled}) {
    final isOn = conn.isOutputOn;
    final target = !isOn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Expanded(child: Text('Output (both FETs)')),
          Text(isOn ? 'On' : 'Off',
              style: TextStyle(
                  color: isOn ? kGreen : kIdle, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            style: (!target)
                ? FilledButton.styleFrom(foregroundColor: kRed)
                : null,
            onPressed: !enabled
                ? null
                : () => _run(context, outputAction(conn, target: target)),
            child: Text(target ? 'Turn output ON' : 'Turn output OFF'),
          ),
        ],
      ),
    );
  }

  /// #38 capacity write. Shows the current rated capacity and lets the user enter
  /// a new value (Ah). Validated (finite, 1–1000), confirmed (it changes the SOC
  /// / estimator basis), sent, then read back against the type-4 ack / updated
  /// fullAh; warns if not confirmed within ~4 s. The busy key is held from the
  /// value-entry dialog onward, so the action runs inside that same hold.
  Widget _capacityRow(BuildContext context, {required bool enabled}) {
    final current = conn.ratedCapacityAh;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Expanded(child: Text('Rated capacity')),
          Text(current == null ? '—' : fAh(current),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            onPressed: !enabled
                ? null
                : () => busy.run(WriteKeys.capacity, onChanged, () async {
                      final entered = await askCapacity(context, conn);
                      if (entered == null || !context.mounted) return;
                      await runWriteAction(
                          context, capacityAction(conn, entered),
                          busy: null, onChanged: onChanged);
                    }),
            child: const Text('Change…'),
          ),
        ],
      ),
    );
  }

  /// #42 sleep mode. Sleep-ON double-confirms and warns that it may drop the BLE
  /// link / stop telemetry; wake is a single confirm (see [sleepAction]).
  Widget _sleepRow(BuildContext context, {required bool enabled}) {
    final isOn = conn.isSleepModeOn;
    final target = !isOn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Expanded(child: Text('Sleep mode')),
          Text(isOn ? 'Asleep' : 'Awake',
              style: TextStyle(
                  color: isOn ? kRed : kGreen, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            style:
                target ? FilledButton.styleFrom(foregroundColor: kRed) : null,
            onPressed: !enabled
                ? null
                : () => _run(context, sleepAction(conn, target: target)),
            child: Text(target ? 'Sleep' : 'Wake'),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(
    BuildContext context, {
    required String label,
    required String busyKey,
    required bool isOn,
    required GateAction action,
    required bool dangerousWhenOff,
    required bool enabled,
    String? offWarning,
    String? enableNote,
  }) {
    final target = !isOn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(isOn ? 'On' : 'Off',
              style: TextStyle(
                  color: isOn ? kGreen : kIdle,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            style: (!target)
                ? FilledButton.styleFrom(foregroundColor: kRed)
                : null,
            onPressed: !enabled
                ? null
                : () => _run(
                      context,
                      gateToggleAction(
                        conn,
                        label: label,
                        busyKey: busyKey,
                        isOn: isOn,
                        action: action,
                        dangerousWhenOff: dangerousWhenOff,
                        offWarning: offWarning,
                        enableNote: enableNote,
                      ),
                    ),
            child: Text(target ? 'Turn on' : 'Turn off'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // M2: sleep + capacity are NOT gate writes but still need a link — while
    // disconnected they are disabled with the reason, never "Sent:" into the
    // void followed by a "not confirmed" warning that could never be met.
    final writeReason = conn.writesDisabledReason;
    final connected = writeReason == null;
    // C1: EVERY gate-control button (output, passive balancing, heater,
    // restart, factory) is disabled unless the gate base is fresh — connected,
    // all six gates reported, BAL_STATUS younger than 5 s. The reason is shown.
    final gateReason = conn.gateControlsDisabledReason;
    // M4: while any write on this battery is in flight (tap -> confirm ->
    // read-back), every write button is disabled.
    final inFlight = busy.any;
    final gateOk = gateReason == null && !inFlight;
    final writeOk = connected && !inFlight;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.build_circle_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Controls (writes to the battery)',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            if (inFlight)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Write in progress (${busy.current}) — waiting for '
                        '$_serial to confirm…',
                        style: const TextStyle(
                            color: Colors.amber, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )
            else if (!connected)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Not connected — controls are disabled until it reconnects.',
                  style: TextStyle(color: Colors.amber, fontSize: 12),
                ),
              )
            else if (gateReason != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 15, color: Colors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Gate controls locked — $gateReason. They unlock as '
                        'soon as a fresh status frame arrives.',
                        style: const TextStyle(
                            color: Colors.amber, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            // Issue #26: ONE Output control that writes both FET bytes together,
            // exactly like the vendor setMos. (Per-FET toggles are gone — flipping
            // a single FET did not take effect on hardware.)
            _outputRow(context, enabled: gateOk),
            _toggleRow(
              context,
              label: 'Passive balancing',
              busyKey: WriteKeys.passive,
              isOn: conn.isPassiveBalancingOn,
              action: GateAction.passiveBalance,
              dangerousWhenOff: false,
              enabled: gateOk,
            ),
            // #42 heat-up: flips ONLY the heat gate (payload[4]); every other gate
            // keeps its cached value. Confirm on enable — it draws power / heats
            // the pack.
            _toggleRow(
              context,
              label: 'Heater',
              busyKey: WriteKeys.heater,
              isOn: conn.isHeatOn,
              action: GateAction.heatGate,
              dangerousWhenOff: false,
              enabled: gateOk,
              enableNote: 'The self-heating element draws power from the pack '
                  'and warms the cells.',
            ),
            const Divider(height: 24),
            // #42 sleep mode. Sleep-ON may drop the BLE link (double-confirmed).
            _sleepRow(context, enabled: writeOk),
            const Divider(height: 24),
            // #38 rated-capacity write (CMD_BATTERY). Changes the SOC / estimator
            // basis; confirmed + read back against the type-4 ack.
            _capacityRow(context, enabled: writeOk),
            const Divider(height: 24),
            // Restart BMS. The two former buttons ("Restart BMS" and the
            // experimental "Restart (clear-alarm test)") sent the IDENTICAL
            // restart gate and are now merged into this one (shared with the
            // #50 latched over-temp warning card via [restartAction]).
            OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: kRed,
                side: const BorderSide(color: kRed),
              ),
              onPressed: !gateOk
                  ? null
                  : () => _run(context, restartAction(conn)),
              label: const Text('Restart BMS'),
            ),
            const Divider(height: 24),
            // Factory reset — double confirm with a stern warning.
            OutlinedButton.icon(
              icon: const Icon(Icons.warning_amber, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: kRed,
                side: const BorderSide(color: kRed, width: 2),
              ),
              onPressed: !gateOk
                  ? null
                  : () => _run(context, factoryAction(conn)),
              label: const Text('Factory reset'),
            ),
          ],
        ),
      ),
    );
  }
}

/// #50: amber WARNING card shown while the latched over-temperature protection
/// (CMD_WARN_TEMP_ALARM byte[2]) is set. Not a live fault — the pack is not hot
/// now — but charging may be inhibited until the BMS is restarted. Carries the
/// same restart control (and confirmation) as the Controls section.
class _LatchedOverTempCard extends StatelessWidget {
  final BatteryConnection conn;
  final VoidCallback onChanged;

  /// M4: shared in-flight flags (the restart key is common with Controls).
  final BusyWrites busy;
  const _LatchedOverTempCard({
    required this.conn,
    required this.onChanged,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final gateReason = busy.any
        ? 'a write is in progress (${busy.current})'
        : conn.gateControlsDisabledReason;
    return Card(
      color: const Color(0xFF3D2E0A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Colors.amber, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber, color: Colors.amber),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('WARNING — over-temperature protection latched',
                          style: TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                      SizedBox(height: 4),
                      Text(
                        'Over-temperature protection latched — charging may '
                        'be inhibited. Set by a past over-temp event. Restart '
                        'the BMS to clear.',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.amber, foregroundColor: Colors.black),
              icon: const Icon(Icons.restart_alt, size: 18),
              onPressed: gateReason != null
                  ? null
                  : () => runWriteAction(context, restartAction(conn),
                      busy: busy, onChanged: onChanged),
              label: const Text('Restart BMS to clear'),
            ),
            if (gateReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Restart locked — $gateReason.',
                    style:
                        const TextStyle(color: Colors.amber, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Loud red banner at the top of the detail view while a battery is in alarm.
/// "Acknowledge" (M1) clears the sticky unknown-byte-change / link-error state;
/// a still-live genuine fault stays red.
class _AlarmBanner extends StatelessWidget {
  final List<String> reasons;
  final VoidCallback? onAcknowledge;
  const _AlarmBanner({required this.reasons, this.onAcknowledge});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kRed,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('ALERT',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                      const SizedBox(height: 4),
                      for (final r in reasons.reversed.take(5))
                        Text('• $r',
                            style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
            if (onAcknowledge != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  icon: const Icon(Icons.check, size: 18),
                  onPressed: onAcknowledge,
                  label: const Text('Acknowledge'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Warnings extends StatelessWidget {
  final String title;
  final List<String> items;
  const _Warnings(this.title, this.items);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      color: Colors.red.shade900,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            for (final w in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.warning_amber, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(w)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
