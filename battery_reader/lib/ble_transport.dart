/// Cross-platform BLE transport abstraction.
///
/// `flutter_blue_plus` (FBP) has no Windows support, which is the only reason a
/// separate Python reader ever existed. This interface abstracts exactly what
/// [BatteryConnection]/[BatteryManager] need from a BLE stack — scan, connect,
/// discover the FCF0 service and its FCF1 (write) / FCF2 (notify)
/// characteristics, subscribe for notifications, write, disconnect, and observe
/// the connection state — so the same protocol/logging code runs on every OS.
///
/// Two implementations are provided:
///  * [FbpTransport]           — flutter_blue_plus, used on iOS + Android.
///  * [UniversalBleTransport]  — universal_ble (WinRT), used on Windows.
///
/// [defaultBleTransport] picks the right one at runtime. Both feed [BatteryParser]
/// identical bytes and use identical UUIDs/handshake — the only thing that
/// differs is the vendor BLE plugin underneath.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:universal_ble/universal_ble.dart' as ub;

import 'battery_protocol.dart';

/// A transport-neutral scan hit: advertised name, device id string and RSSI.
class BleScanHit {
  /// Vendor device identifier as a string (FBP `remoteId.str` / universal_ble
  /// `deviceId`). Round-trips back into [BleTransport.connect].
  final String deviceId;

  /// Advertised name (may be empty).
  final String name;

  /// Signal strength in dBm (negative).
  final int rssi;

  /// Advertised service UUIDs, normalised to lowercase 128-bit form.
  final List<String> serviceUuids;

  const BleScanHit({
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.serviceUuids = const [],
  });

  /// True if the FCF0 battery service is advertised.
  bool get advertisesBatteryService =>
      serviceUuids.any((u) => u.toLowerCase() == BleUuids.service);
}

enum BleLinkState { connected, disconnected }

/// A live link to one peripheral. Owns the discovered FCF1/FCF2 characteristics
/// and the notify subscription; hides the vendor characteristic objects.
abstract class BleLink {
  String get deviceId;

  /// Emits [BleLinkState.disconnected] when the link drops.
  Stream<BleLinkState> get state;

  /// Discover the FCF0 service, locate FCF1 (write) + FCF2 (notify), enable
  /// notifications and route every inbound packet to [onData].
  /// Throws [StateError] if the service or characteristics are missing.
  Future<void> discoverAndSubscribe(void Function(List<int> data) onData);

  /// Write [bytes] to FCF1 (without response when the characteristic supports
  /// it, matching the original flutter_blue_plus behaviour).
  Future<void> write(List<int> bytes);

  Future<void> disconnect();
}

/// The central adapter: scan for peripherals and connect to one by id.
abstract class BleTransport {
  /// Broadcast stream of scan hits (batched into lists, as FBP delivers them).
  Stream<List<BleScanHit>> get scanResults;

  /// Start scanning. [timeout] auto-stops the scan (parity with FBP).
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)});

  Future<void> stopScan();

  /// Connect to [deviceId] and return the live link once connected.
  Future<BleLink> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    int mtu = 512,
  });
}

/// Process-wide transport, selected once for the current platform: universal_ble
/// on Windows desktop, flutter_blue_plus everywhere else. Shared by
/// [BatteryConnection] and [BatteryManager] so there is a single BLE central.
final BleTransport defaultBleTransport = _createBleTransport();

BleTransport _createBleTransport() {
  if (!kIsWeb && Platform.isWindows) return UniversalBleTransport();
  return FbpTransport();
}

// ===========================================================================
// flutter_blue_plus implementation (iOS + Android) — unchanged behaviour.
// ===========================================================================

class FbpTransport implements BleTransport {
  @override
  Stream<List<BleScanHit>> get scanResults =>
      fbp.FlutterBluePlus.onScanResults.map((results) => [
            for (final r in results)
              BleScanHit(
                deviceId: r.device.remoteId.str,
                name: r.advertisementData.advName.isNotEmpty
                    ? r.advertisementData.advName
                    : r.device.platformName,
                rssi: r.rssi,
                serviceUuids: [
                  for (final u in r.advertisementData.serviceUuids) u.str128,
                ],
              ),
          ]);

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) =>
      fbp.FlutterBluePlus.startScan(timeout: timeout);

  @override
  Future<void> stopScan() => fbp.FlutterBluePlus.stopScan();

  @override
  Future<BleLink> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    int mtu = 512,
  }) async {
    final device = fbp.BluetoothDevice.fromId(deviceId);
    // NOTE: License.nonprofit is free for personal/nonprofit/educational use.
    // A commercial/for-profit app requires the paid License.commercial.
    await device.connect(
      license: fbp.License.nonprofit,
      timeout: timeout,
      mtu: mtu,
    );
    return _FbpLink(device);
  }
}

class _FbpLink implements BleLink {
  _FbpLink(this._device);

  final fbp.BluetoothDevice _device;
  fbp.BluetoothCharacteristic? _write;
  fbp.BluetoothCharacteristic? _notify;
  StreamSubscription<List<int>>? _notifySub;

  @override
  String get deviceId => _device.remoteId.str;

  @override
  Stream<BleLinkState> get state => _device.connectionState.map((s) =>
      s == fbp.BluetoothConnectionState.disconnected
          ? BleLinkState.disconnected
          : BleLinkState.connected);

  @override
  Future<void> discoverAndSubscribe(void Function(List<int> data) onData) async {
    final services = await _device.discoverServices();
    fbp.BluetoothService? svc;
    for (final s in services) {
      if (s.uuid.str128 == BleUuids.service) svc = s;
    }
    svc ??= throw StateError('FCF0 service not found');

    for (final c in svc.characteristics) {
      final u = c.uuid.str128;
      if (u == BleUuids.writeChar) _write = c;
      if (u == BleUuids.notifyChar) _notify = c;
    }
    if (_write == null || _notify == null) {
      throw StateError('FCF1/FCF2 characteristics not found');
    }

    await _notify!.setNotifyValue(true);
    _notifySub = _notify!.onValueReceived.listen(onData);
  }

  @override
  Future<void> write(List<int> bytes) async {
    final c = _write;
    if (c == null) return;
    await c.write(bytes, withoutResponse: c.properties.writeWithoutResponse);
  }

  @override
  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    try {
      await _device.disconnect();
    } catch (_) {/* best effort */}
  }
}

// ===========================================================================
// universal_ble implementation (Windows / WinRT) — same behaviour, same UUIDs.
// ===========================================================================

class UniversalBleTransport implements BleTransport {
  final _scanController = StreamController<List<BleScanHit>>.broadcast();
  bool _wired = false;

  void _wire() {
    if (_wired) return;
    _wired = true;
    ub.UniversalBle.onScanResult = (device) {
      _scanController.add([
        BleScanHit(
          deviceId: device.deviceId,
          name: device.name ?? '',
          rssi: device.rssi ?? -127,
          serviceUuids: [
            for (final u in device.services) _normalizeUuid(u),
          ],
        ),
      ]);
    };
  }

  static String _normalizeUuid(String u) {
    try {
      return ub.BleUuidParser.string(u).toLowerCase();
    } catch (_) {
      return u.toLowerCase();
    }
  }

  @override
  Stream<List<BleScanHit>> get scanResults {
    _wire();
    return _scanController.stream;
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _wire();
    await ub.UniversalBle.startScan();
    // FBP auto-stops after its timeout; universal_ble does not, so mirror it.
    Timer(timeout, () {
      ub.UniversalBle.stopScan().catchError((_) {});
    });
  }

  @override
  Future<void> stopScan() => ub.UniversalBle.stopScan();

  @override
  Future<BleLink> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    int mtu = 512,
  }) async {
    await ub.UniversalBle.connect(deviceId, connectionTimeout: timeout);
    // Best-effort MTU bump (matches the FBP mtu: 512 request); ignore failures.
    try {
      await ub.UniversalBle.requestMtu(deviceId, mtu);
    } catch (_) {/* platform may not support it */}
    return _UniversalBleLink(deviceId);
  }
}

class _UniversalBleLink implements BleLink {
  _UniversalBleLink(this.deviceId);

  @override
  final String deviceId;

  StreamSubscription<Uint8List>? _valueSub;

  @override
  Stream<BleLinkState> get state => ub.UniversalBle.connectionStream(deviceId).map(
      (connected) =>
          connected ? BleLinkState.connected : BleLinkState.disconnected);

  @override
  Future<void> discoverAndSubscribe(void Function(List<int> data) onData) async {
    final services = await ub.UniversalBle.discoverServices(deviceId);
    ub.BleService? svc;
    for (final s in services) {
      if (s.uuid.toLowerCase() == BleUuids.service) svc = s;
    }
    svc ??= throw StateError('FCF0 service not found');

    String? writeUuid;
    String? notifyUuid;
    for (final c in svc.characteristics) {
      final u = c.uuid.toLowerCase();
      if (u == BleUuids.writeChar) writeUuid = c.uuid;
      if (u == BleUuids.notifyChar) notifyUuid = c.uuid;
    }
    if (writeUuid == null || notifyUuid == null) {
      throw StateError('FCF1/FCF2 characteristics not found');
    }

    _valueSub = ub.UniversalBle
        .characteristicValueStream(deviceId, notifyUuid)
        .listen(onData);
    await ub.UniversalBle.setNotifiable(
      deviceId,
      BleUuids.service,
      notifyUuid,
      ub.BleInputProperty.notification,
    );
  }

  @override
  Future<void> write(List<int> bytes) async {
    await ub.UniversalBle.writeValue(
      deviceId,
      BleUuids.service,
      BleUuids.writeChar,
      Uint8List.fromList(bytes),
      // The BMS accepts write-without-response on FCF1; mirror the FBP path.
      ub.BleOutputProperty.withoutResponse,
    );
  }

  @override
  Future<void> disconnect() async {
    await _valueSub?.cancel();
    _valueSub = null;
    try {
      await ub.UniversalBle.disconnect(deviceId);
    } catch (_) {/* best effort */}
  }
}
