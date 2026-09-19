/// Owns the set of batteries shown on the list screen and computes the
/// combined totals across the favourited ones for the fleet panel.
///
/// Two sources feed the list:
///  * a synthetic demo fleet ([startDemoFleet]) for use with no hardware, and
///  * a live BLE scanner ([startLive]) that discovers every JS*/RV* battery in
///    range, connects to each, logs its telemetry, and reconnects on drop —
///    mirroring the reference Python `read_batteries.py` discover/reconnect
///    loop. Both paths produce the same [BatteryConnection] objects, so the UI
///    and fleet maths are identical either way.
library;

import 'dart:async';

import 'battery_connection.dart';
import 'battery_log.dart';
import 'battery_protocol.dart';
import 'ble_transport.dart';
import 'demo_source.dart';

class BatteryManager {
  final List<BatteryConnection> batteries = [];

  /// True while live BLE scanning is active (vs. the synthetic demo fleet).
  bool get isLive => _live;
  bool _live = false;

  // Live-scan bookkeeping.
  final Duration scanWindow;
  final Duration rescanInterval;
  final Map<String, BatteryConnection> _byId = {}; // deviceId -> connection
  final Set<String> _connecting = {}; // deviceIds mid-connect (dedupe)
  Timer? _rescanTimer;
  StreamSubscription<List<BleScanHit>>? _scanSub;

  /// BLE transport shared with the connections it creates (flutter_blue_plus on
  /// mobile, universal_ble on Windows).
  final BleTransport transport = defaultBleTransport;

  BatteryManager({
    this.scanWindow = const Duration(seconds: 8),
    this.rescanInterval = const Duration(seconds: 20),
  });

  // -------------------------------------------------------------------------
  // Demo fleet (unchanged behaviour, now gated behind the Live/Demo toggle).
  // -------------------------------------------------------------------------

  /// Seed the list with four synthetic packs in different states, so the
  /// list and the fleet total are populated without hardware.
  void startDemoFleet() {
    stopLive();
    disposeAll();
    _live = false;
    final seeds = <(DeviceProfile, String, int, DemoMode, int)>[
      (DeviceProfile.sphere, 'JS-2C14AA', 64, DemoMode.discharging, -54),
      (DeviceProfile.sphere, 'JS-9F031B', 9, DemoMode.charging, -67),
      (DeviceProfile.sphere, 'JS-5A77C0', 100, DemoMode.idle, -78),
      (DeviceProfile.rv, 'RV-1180E2', 47, DemoMode.idle, -61),
    ];
    for (final (profile, serial, soc, mode, rssi) in seeds) {
      final c = BatteryConnection(profile: profile)..favourite = true;
      c.startDemo(startSoc: soc, mode: mode, serial: serial);
      c.state.rssi = rssi; // synthetic signal strength for the demo fleet
      BatteryLogger.instance.attach(c); // demo telemetry is logged too
      batteries.add(c);
    }
  }

  // -------------------------------------------------------------------------
  // Live BLE scanning.
  // -------------------------------------------------------------------------

  /// Start scanning for real batteries: an immediate scan, then a periodic
  /// re-scan that discovers newly-appeared packs and reconnects dropped ones.
  Future<void> startLive() async {
    stopLive();
    disposeAll();
    _live = true;
    await BatteryLogger.instance.init();
    await _scanOnce();
    _rescanTimer =
        Timer.periodic(rescanInterval, (_) => _scanOnce());
  }

  /// Stop live scanning (leaves any created connections in place unless a
  /// caller also disposes them; [startDemoFleet]/[startLive] dispose first).
  void stopLive() {
    _live = false;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _scanSub?.cancel();
    _scanSub = null;
    try {
      transport.stopScan();
    } catch (_) {/* best effort */}
  }

  Future<void> _scanOnce() async {
    if (!_live) return;
    try {
      await _scanSub?.cancel();
      _scanSub = transport.scanResults.listen((results) {
        for (final r in results) {
          _handleScanResult(r);
        }
      });
      await transport.startScan(timeout: scanWindow);
      // Let the scan window elapse, then stop so the next tick can rescan.
      await Future<void>.delayed(scanWindow);
      await transport.stopScan();
      await _scanSub?.cancel();
      _scanSub = null;
    } catch (_) {
      // Adapter busy / permission denied: try again on the next tick.
    }
  }

  void _handleScanResult(BleScanHit r) {
    final name = r.name;
    final hasService = r.advertisesBatteryService;
    final isRv = name.startsWith('RV');
    final matches = name.startsWith('JS') ||
        name.startsWith('Sphere_') ||
        isRv ||
        name.startsWith('RV_') ||
        hasService;
    if (!matches) return;

    final id = r.deviceId;
    final existing = _byId[id];
    if (existing != null) {
      existing.state.rssi = r.rssi; // refresh signal strength every scan
      // Reconnect a dropped battery that is advertising again.
      if (existing.connState == ConnState.disconnected) {
        _connect(existing, id, name);
      }
      return;
    }

    // New battery: pick a profile from the advertised-name prefix.
    final profile = isRv ? DeviceProfile.rv : DeviceProfile.sphere;
    final conn = BatteryConnection(profile: profile)..favourite = true;
    conn.state.rssi = r.rssi;
    conn.state.serial = name.isNotEmpty ? name : id;
    _byId[id] = conn;
    batteries.add(conn);
    BatteryLogger.instance.attach(conn); // record its telemetry to SQLite
    _connect(conn, id, name);
  }

  void _connect(BatteryConnection conn, String deviceId, String name) {
    if (_connecting.contains(deviceId)) return;
    _connecting.add(deviceId);
    conn
        .connectTo(deviceId, name: name)
        .whenComplete(() => _connecting.remove(deviceId))
        .catchError(
      (_) {
        // Leave it marked disconnected; the next rescan retries.
        return '';
      },
    );
  }

  // -------------------------------------------------------------------------

  List<BatteryConnection> get favourites =>
      batteries.where((b) => b.favourite).toList();

  double get totalCapacityAh =>
      favourites.fold(0.0, (a, b) => a + (b.state.fullAh ?? 0));

  double get totalRemainingAh =>
      favourites.fold(0.0, (a, b) => a + (b.state.remainingAh ?? 0));

  /// Combined charge as remaining / full across favourites.
  int? get combinedSocPercent {
    final full = totalCapacityAh;
    if (full <= 0) return null;
    return ((totalRemainingAh / full) * 100).round().clamp(0, 100);
  }

  double get netCurrentA => favourites.fold(0.0, (a, b) => a + b.signedCurrent);
  double get netPowerW => favourites.fold(0.0, (a, b) => a + b.signedPower);

  /// Net direction of the favourited set.
  ChargeState get fleetState {
    final p = netPowerW;
    if (p > 0.5) return ChargeState.charging;
    if (p < -0.5) return ChargeState.discharging;
    return ChargeState.idle;
  }

  void disposeAll() {
    for (final b in batteries) {
      b.dispose();
    }
    batteries.clear();
    _byId.clear();
    _connecting.clear();
  }
}
