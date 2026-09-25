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
import 'diagnostics.dart';

const _source = 'BleTransport';

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

/// #75: the service + characteristics a link binds to. JoySuny (FCF0 /
/// FCF2 notify / FCF1 write) is the default; the other BMS families pass
/// their own from `BmsCodec`. [notify] and [write] may be the same
/// characteristic (JK and ANT use FFE1 for both).
class GattTarget {
  final String service;
  final String notify;
  final String write;
  const GattTarget(
      {required this.service, required this.notify, required this.write});

  static const joySuny = GattTarget(
      service: BleUuids.service,
      notify: BleUuids.notifyChar,
      write: BleUuids.writeChar);

  @override
  String toString() => 'service $service (notify $notify, write $write)';
}

/// A live link to one peripheral. Owns the discovered FCF1/FCF2 characteristics
/// and the notify subscription; hides the vendor characteristic objects.
abstract class BleLink {
  String get deviceId;

  /// Emits [BleLinkState.disconnected] when the link drops.
  Stream<BleLinkState> get state;

  /// Discover the [target] service (FCF0 by default), locate its write +
  /// notify characteristics, enable notifications and route every inbound
  /// packet to [onData].
  /// Throws [StateError] if the service or characteristics are missing.
  Future<void> discoverAndSubscribe(void Function(List<int> data) onData,
      {GattTarget target = GattTarget.joySuny});

  /// Write [bytes] to the bound write characteristic (FCF1 by default;
  /// without response when the characteristic supports it, matching the
  /// original flutter_blue_plus behaviour).
  Future<void> write(List<int> bytes);

  /// #41: the negotiated ATT MTU as the platform reports it, or null when
  /// unknown. The OTA chunker derives its payload size from this exactly as
  /// the vendor does (`min(mtu, 200)`, 20 when unknown — see ota_update.dart).
  int? get mtu;

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

  /// #41: flutter_blue_plus caches the negotiated MTU (0 = unknown).
  @override
  int? get mtu => _device.mtuNow > 0 ? _device.mtuNow : null;

  @override
  Stream<BleLinkState> get state => _device.connectionState.map((s) =>
      s == fbp.BluetoothConnectionState.disconnected
          ? BleLinkState.disconnected
          : BleLinkState.connected);

  @override
  Future<void> discoverAndSubscribe(void Function(List<int> data) onData,
      {GattTarget target = GattTarget.joySuny}) async {
    final services = await _device.discoverServices();
    fbp.BluetoothService? svc;
    for (final s in services) {
      if (s.uuid.str128 == target.service) svc = s;
    }
    svc ??= throw StateError('service ${target.service} not found');

    for (final c in svc.characteristics) {
      final u = c.uuid.str128;
      if (u == target.write) _write = c;
      if (u == target.notify) _notify = c;
    }
    if (_write == null || _notify == null) {
      throw StateError('characteristics not found: $target');
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
    // Best effort (already gone / adapter off): recorded, never thrown.
    await guard<void>('fbp disconnect $deviceId', _device.disconnect,
        source: _source);
  }
}

// ===========================================================================
// universal_ble implementation (Windows / WinRT) — same behaviour, same UUIDs.
// ===========================================================================

/// L13: the back-off before discovery attempt [attempt] (0-based) of
/// [attempts] is retried — 200 ms, 400 ms, 600 ms, 800 ms between five
/// attempts (~2 s worst case) — or null after the FINAL attempt, so a failed
/// discovery throws immediately instead of sleeping first. Pure.
Duration? discoveryRetryDelay(int attempt, {int attempts = 5}) =>
    attempt + 1 >= attempts
        ? null
        : Duration(milliseconds: 200 * (attempt + 1));

class UniversalBleTransport implements BleTransport {
  final _scanController = StreamController<List<BleScanHit>>.broadcast();
  bool _wired = false;

  /// L13: generation of the current scan. The auto-stop timer armed by
  /// [startScan] captures the generation it was armed for and is a no-op if a
  /// newer scan has started (or [stopScan] ran) since — a stale timer from an
  /// earlier scan can no longer stop a later one.
  int _scanGen = 0;
  Timer? _autoStop;

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

  static String _normalizeUuid(String u) =>
      guardSync<String>('normalise uuid $u',
          () => ub.BleUuidParser.string(u).toLowerCase(),
          fallback: u.toLowerCase(), source: _source) ??
      u.toLowerCase();

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
    final gen = ++_scanGen;
    _autoStop?.cancel();
    await ub.UniversalBle.startScan();
    // FBP auto-stops after its timeout; universal_ble does not, so mirror it —
    // but only for THIS scan (L13): if a later startScan/stopScan has bumped
    // the generation, the timer does nothing.
    _autoStop = Timer(timeout, () {
      if (gen != _scanGen) return;
      unawaited(guard<void>('auto-stop scan', ub.UniversalBle.stopScan,
          source: _source));
    });
  }

  @override
  Future<void> stopScan() {
    _scanGen++; // L13: retire any pending auto-stop for the scan just ended
    _autoStop?.cancel();
    _autoStop = null;
    return ub.UniversalBle.stopScan();
  }

  @override
  Future<BleLink> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 20),
    int mtu = 512,
  }) async {
    await ub.UniversalBle.connect(deviceId, connectionTimeout: timeout);
    // Best-effort MTU bump (matches the FBP mtu: 512 request); the platform
    // may not support it — recorded, never fatal.
    final negotiated = await guard<int>('request mtu $mtu on $deviceId',
        () => ub.UniversalBle.requestMtu(deviceId, mtu),
        source: _source);
    return _UniversalBleLink(deviceId, negotiated);
  }
}

class _UniversalBleLink implements BleLink {
  _UniversalBleLink(this.deviceId, this.mtu);

  @override
  final String deviceId;

  /// #41: what requestMtu returned (null when the platform refused).
  @override
  final int? mtu;

  StreamSubscription<Uint8List>? _valueSub;

  /// #75: the service / write characteristic bound by [discoverAndSubscribe]
  /// (JoySuny FCF0 / FCF1 until then, the original behaviour).
  String _serviceUuid = BleUuids.service;
  String _writeUuid = BleUuids.writeChar;

  @override
  Stream<BleLinkState> get state => ub.UniversalBle.connectionStream(deviceId).map(
      (connected) =>
          connected ? BleLinkState.connected : BleLinkState.disconnected);

  @override
  Future<void> discoverAndSubscribe(void Function(List<int> data) onData,
      {GattTarget target = GattTarget.joySuny}) async {
    // WinRT frequently reports services as empty or throws 'Failed to get
    // services: Unreachable' in the first moments after a connect — especially
    // at weak signal (issue #49). Retry a few times with a short, growing
    // backoff before treating discovery as a failed connect; connectTo then
    // falls through to the normal disconnect + reconnect path.
    List<ub.BleService> services = const [];
    Object? lastErr;
    const attempts = 5;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        services = await ub.UniversalBle.discoverServices(deviceId);
        if (services.isNotEmpty) {
          lastErr = null;
          break;
        }
      } catch (e) {
        lastErr = e;
      }
      // 200ms, 400ms, 600ms, 800ms between the five attempts (~2s worst case);
      // L13: no sleep after the final failed attempt — throw straight away.
      final delay = discoveryRetryDelay(attempt, attempts: attempts);
      if (delay == null) break;
      await Future<void>.delayed(delay);
    }
    if (services.isEmpty) {
      throw StateError(
          'Failed to get services${lastErr != null ? ': $lastErr' : ''}');
    }

    ub.BleService? svc;
    for (final s in services) {
      if (s.uuid.toLowerCase() == target.service) svc = s;
    }
    svc ??= throw StateError('service ${target.service} not found');

    String? writeUuid;
    String? notifyUuid;
    for (final c in svc.characteristics) {
      final u = c.uuid.toLowerCase();
      if (u == target.write) writeUuid = c.uuid;
      if (u == target.notify) notifyUuid = c.uuid;
    }
    if (writeUuid == null || notifyUuid == null) {
      throw StateError('characteristics not found: $target');
    }
    _serviceUuid = svc.uuid;
    _writeUuid = writeUuid;

    _valueSub = ub.UniversalBle
        .characteristicValueStream(deviceId, notifyUuid)
        // Stream errors are recorded, not propagated: a transport hiccup on
        // the notify channel is a drop to recover from, not a fatal unhandled
        // async error (issue #49).
        .listen(onData,
            onError: (Object e) => AppLog.instance
                .record(_source, 'notify stream $deviceId: $e'));
    await ub.UniversalBle.setNotifiable(
      deviceId,
      svc.uuid,
      notifyUuid,
      ub.BleInputProperty.notification,
    );
  }

  @override
  Future<void> write(List<int> bytes) async {
    await ub.UniversalBle.writeValue(
      deviceId,
      _serviceUuid,
      _writeUuid,
      Uint8List.fromList(bytes),
      // The BMS accepts write-without-response on FCF1; mirror the FBP path.
      ub.BleOutputProperty.withoutResponse,
    );
  }

  @override
  Future<void> disconnect() async {
    await _valueSub?.cancel();
    _valueSub = null;
    // Best effort (already gone / adapter off): recorded, never thrown.
    await guard<void>('universal_ble disconnect $deviceId',
        () => ub.UniversalBle.disconnect(deviceId),
        source: _source);
  }
}
