/// Shared hermetic test doubles (review pass C2). Before this pass every test
/// file that needed a BLE transport or a fleet store carried its own copy;
/// these are the union of those fakes, so a behaviour any one test relied on
/// is still available to all:
///
///  * [FakeTransport] / [FakeLink] — a switchable BLE stack: connect can fail
///    ([FakeTransport.failConnect]) or hang on a gate ([connectGate]), service
///    discovery can fail ([failDiscover]), writes can fail ([failWrite]) and
///    every written frame is recorded ([writes] / [gateWrites]); the link can
///    be dropped from the transport side ([FakeLink.dropLink]).
///  * [NoopTransport] — never connects; [scanError] makes startScan throw.
///  * [FakeFleetStore] — in-memory [FleetStore].
library;

import 'dart:async';

import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/ble_transport.dart';

class FakeTransport implements BleTransport {
  bool failConnect = false;
  bool failDiscover = false;
  bool failWrite = false;
  int connectCalls = 0;

  /// If set, connect() awaits it before returning.
  Completer<void>? connectGate;
  FakeLink? lastLink;
  final List<List<int>> writes = [];

  /// Only the CMD_GATE_CONTROL frames (C3 1E … D4 3B) written so far.
  List<List<int>> get gateWrites => [
        for (final w in writes)
          if (w.length == 12 && w[0] == 0xC3 && w[1] == 0x1E) w
      ];

  final _scan = StreamController<List<BleScanHit>>.broadcast();

  @override
  Stream<List<BleScanHit>> get scanResults => _scan.stream;

  /// #52: push scan hits to whoever is listening (the manager's scan window).
  void emitScan(List<BleScanHit> hits) => _scan.add(hits);

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<BleLink> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    int mtu = 512,
  }) async {
    connectCalls++;
    if (connectGate != null) await connectGate!.future;
    if (failConnect) throw StateError('connect failed: Unreachable');
    final link = FakeLink(deviceId, this);
    lastLink = link;
    return link;
  }
}

class FakeLink implements BleLink {
  FakeLink(this.deviceId, this.transport);

  @override
  final String deviceId;
  final FakeTransport transport;
  final _state = StreamController<BleLinkState>.broadcast();

  /// Set once [disconnect] has been called on this link.
  bool disconnected = false;

  @override
  Stream<BleLinkState> get state => _state.stream;

  /// Simulate a drop signalled by the transport.
  void dropLink() => _state.add(BleLinkState.disconnected);

  @override
  Future<void> discoverAndSubscribe(void Function(List<int> data) onData) async {
    if (transport.failDiscover) {
      throw StateError('Failed to get services: Unreachable');
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (transport.failWrite) throw StateError('GATT write failed');
    transport.writes.add(List.of(bytes));
  }

  @override
  Future<void> disconnect() async => disconnected = true;
}

/// A transport that never connects; [scanError] makes startScan throw (M13).
class NoopTransport implements BleTransport {
  Object? scanError;
  final _scan = StreamController<List<BleScanHit>>.broadcast();

  @override
  Stream<List<BleScanHit>> get scanResults => _scan.stream;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    if (scanError != null) throw scanError!;
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<BleLink> connect(String deviceId,
          {Duration timeout = const Duration(seconds: 20), int mtu = 512}) =>
      throw StateError('no BLE in tests');
}

/// In-memory [FleetStore] fake (#27/#34): stands in for shared_preferences so
/// the persistence round-trip is hermetic and needs no plugin.
class FakeFleetStore implements FleetStore {
  Map<String, FleetRecord> saved = {};
  int saveCount = 0;

  @override
  Future<Map<String, FleetRecord>> load() async =>
      Map<String, FleetRecord>.from(saved);

  @override
  Future<void> save(Map<String, FleetRecord> records) async {
    saveCount++;
    saved = Map<String, FleetRecord>.from(records);
  }
}
