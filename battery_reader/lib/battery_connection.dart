/// BLE transport using flutter_blue_plus (iOS + Android).
/// Scans, connects, subscribes to FCF2, runs the handshake, and feeds incoming
/// bytes to [BatteryParser]. A demo mode replays synthetic frames with no BLE.
library;

import 'dart:async';

import 'battery_protocol.dart';
import 'ble_transport.dart';
import 'demo_source.dart';

enum ConnState { idle, scanning, connecting, connected, disconnected }

class BatteryConnection {
  final DeviceProfile profile;

  /// Full handshake sends a gate-control frame that can flip battery gates.
  /// Off by default; enable only if a BMS refuses to stream without it.
  final bool sendLowTempGate;

  /// BLE transport (flutter_blue_plus on mobile, universal_ble on Windows).
  /// Injectable for tests; defaults to the platform-selected [defaultBleTransport].
  final BleTransport transport;

  BatteryConnection({
    this.profile = DeviceProfile.sphere,
    this.sendLowTempGate = false,
    BleTransport? transport,
  })  : transport = transport ?? defaultBleTransport,
        commands = BatteryCommands(profile),
        state = BatteryState() {
    parser = BatteryParser(
      state: state,
      onEvent: (e) {
        _events.add(e);
        _logDecoded(e);
      },
    );
  }

  final BatteryCommands commands;
  final BatteryState state;
  late final BatteryParser parser;

  final _events = StreamController<BatteryEvent>.broadcast();
  final _conn = StreamController<ConnState>.broadcast();

  Stream<BatteryEvent> get events => _events.stream;
  Stream<ConnState> get connection => _conn.stream;

  /// Latest connection state (kept in sync with [connection] for pollers such
  /// as the live-scan manager, which decides when to reconnect).
  ConnState connState = ConnState.idle;

  void _setConn(ConnState s) {
    connState = s;
    _conn.add(s);
  }

  BleLink? _link;
  StreamSubscription<List<BleScanHit>>? _scanSub;
  StreamSubscription<BleLinkState>? _stateSub;

  /// Scan for a battery advertising the profile prefix and connect to the
  /// first match. Returns the connected device's name.
  Future<String> scanAndConnect({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _setConn(ConnState.scanning);
    final completer = Completer<BleScanHit>();

    _scanSub = transport.scanResults.listen((results) {
      for (final r in results) {
        final name = r.name;
        final matches = name.startsWith(profile.advPrefix) ||
            name.startsWith('Sphere_') ||
            name.startsWith('RV_') ||
            r.advertisesBatteryService;
        if (matches) {
          // Capture signal strength from the advertisement so the UI can show
          // it. Keep refreshing while scanning; RSSI is negative dBm.
          state.rssi = r.rssi;
        }
        if (matches && !completer.isCompleted) {
          // ignore: avoid_print
          print('[SCAN] match: "$name" ${r.deviceId} rssi=${r.rssi}dBm');
          completer.complete(r);
        }
      }
    });

    await transport.startScan(timeout: timeout);
    try {
      final hit = await completer.future.timeout(timeout);
      await transport.stopScan();
      await _scanSub?.cancel();
      return await connectTo(hit.deviceId, name: hit.name);
    } on TimeoutException {
      await transport.stopScan();
      await _scanSub?.cancel();
      throw TimeoutException('No matching battery found');
    }
  }

  Future<String> connectTo(String deviceId, {String? name}) async {
    _setConn(ConnState.connecting);
    // Reconnect-safe: drop any stale subscriptions/buffer from a prior link.
    await _stateSub?.cancel();
    await _link?.disconnect();
    parser.reset();

    final link = await transport.connect(deviceId);
    _link = link;

    _stateSub = link.state.listen((s) {
      if (s == BleLinkState.disconnected) {
        _setConn(ConnState.disconnected);
      }
    });

    await link.discoverAndSubscribe((data) {
      // ignore: avoid_print
      print('[RX] ${hex(data)}');
      parser.addBytes(data);
    });

    final resolvedName = name ?? '';
    state.serial = resolvedName.isNotEmpty ? resolvedName : deviceId;
    _setConn(ConnState.connected);
    await _handshake();
    return resolvedName;
  }

  Future<void> _handshake() async {
    await _send(BatteryCommands.begin);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _send(BatteryCommands.getEst);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _send(BatteryCommands.getVersion);
    if (sendLowTempGate) {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await _send(BatteryCommands.lowTempGateFrame);
    }
  }

  Future<void> _send(List<int> bytes) async {
    final link = _link;
    if (link == null) return;
    // ignore: avoid_print
    print('[TX] ${hex(bytes)}');
    await link.write(bytes);
  }

  /// Manually re-request version / estimated time.
  Future<void> refresh() async {
    await _send(BatteryCommands.getEst);
    await _send(BatteryCommands.getVersion);
  }

  /// UI-level flag: is this battery included in the fleet total?
  bool favourite = false;

  /// Test mode: no BLE. A [DemoBattery] feeds synthetic frames through the
  /// same parser/state/event path as a real connection.
  DemoBattery? _demo;

  Future<String> startDemo({
    int startSoc = 50,
    DemoMode mode = DemoMode.charging,
    String? serial,
  }) async {
    _setConn(ConnState.connecting);
    parser.reset();
    state.serial = serial ?? '${profile.advPrefix}-DEMO01';
    _demo = DemoBattery(parser.addBytes, startSoc: startSoc, mode: mode);
    _demo!.start();
    _setConn(ConnState.connected);
    return state.serial!;
  }

  // --- derived helpers for summaries / fleet totals ------------------------

  /// Current signed by direction: + charging (in), - discharging (out).
  double get signedCurrent {
    final i = state.packCurrent ?? 0;
    return switch (state.chargeState) {
      ChargeState.charging => i,
      ChargeState.discharging => -i,
      _ => 0,
    };
  }

  /// Power signed by direction: + in, - out.
  double get signedPower {
    final p = state.power ?? 0;
    return switch (state.chargeState) {
      ChargeState.charging => p,
      ChargeState.discharging => -p,
      _ => 0,
    };
  }

  Future<void> disconnect() async {
    _demo?.stop();
    _demo = null;
    await _stateSub?.cancel();
    try {
      await _link?.disconnect();
    } catch (_) {/* best effort */}
    _link = null;
    _setConn(ConnState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _scanSub?.cancel();
    await _events.close();
    await _conn.close();
  }

  // Verbose per-event logging so decoded frames appear in the run console.
  static String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

  void _logDecoded(BatteryEvent e) {
    final s = state;
    final msg = switch (e) {
      VoltageEvent() => 'Voltage      cells=${s.cellsMv} mV',
      TempEvent() => 'Temperature  t1=${s.temp1}C t2=${s.temp2}C',
      AllDataEvent() => 'AllData      V=${s.packVoltage} I=${s.packCurrent}A '
          'P=${s.power}W sum=${s.cellSum} max=${s.cellMax} min=${s.cellMin} '
          'diff=${s.cellDiff} avg=${s.cellAvg} chip=${s.chipTemperature}C '
          'cyc=${s.cycleCount} load=${s.loadConnected} chg=${s.chargerConnected}',
      MosEvent() => 'Mos          on=${s.mosOn}',
      BalancerEvent() => 'Balancer     state=${s.chargeState.name} '
          'chgMos=${s.chargeMos} disMos=${s.dischargeMos} '
          'passiveBal=${s.passiveBalancing} tempGate=${s.tempControlGate} '
          'smokeGate=${s.smokeGate} heatGate=${s.heatGate}',
      SocEvent() => 'Soc          ${s.socPercent}% '
          'remaining=${s.remainingAh}Ah full=${s.fullAh}Ah',
      EstTimeEvent() => 'EstTime      toFull=${s.timeToFullSec}s '
          'toEmpty=${s.timeToEmptySec}s',
      VersionEvent() => 'Version      ${s.firmwareVersion}',
      SleepEvent() => 'Sleep        mode=${s.sleepModeOn == true ? 'on' : 'off'}',
      SettingRespondEvent() => 'Setting      capacity-write ack',
      GateSetEvent() => 'GateSet      ${s.gateAck}',
      WarningEvent(:final category) =>
        'Warning[$category] ${_warnListFor(category)}',
    };
    // ignore: avoid_print
    print('[EVT] $msg');
  }

  List<String> _warnListFor(String category) => switch (category) {
        'current' => state.currentWarnings,
        'voltage' => state.voltageWarnings,
        'temperature' => state.temperatureWarnings,
        _ => const [],
      };
}
