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
import 'bms_families.dart';
import 'demo_source.dart';
import 'diagnostics.dart';

/// M13: a short, user-facing explanation of a scan failure. Pure; the raw
/// error is kept in [BatteryManager.lastScanError] for Diagnostics.
String describeScanError(Object error) {
  final s = '$error'.toLowerCase();
  if (s.contains('permission') || s.contains('denied') ||
      s.contains('unauthori')) {
    return 'Bluetooth permission denied — allow Nearby devices / Location '
        'for this app';
  }
  if (s.contains('turned on') || s.contains('powered off') ||
      s.contains('poweredoff') || s.contains('adapter') ||
      s.contains('bluetooth is off') || s.contains('not available') ||
      s.contains('unavailable') || s.contains('no adapter') ||
      s.contains('radio')) {
    return 'Bluetooth is off — turn it on to scan for batteries';
  }
  return 'Scan failed: $error';
}

/// A persisted favourite (#34). Beyond the bare serial (#27) this carries enough
/// to show the pack as an OFFLINE placeholder with its last-known values after a
/// restart, and to re-bind the live connection to the SAME entry on rediscovery:
///  * [serial]      — the identity the fleet is keyed by.
///  * [profile]     — DeviceProfile.advPrefix ('JS' = Sphere, 'RV') so the row is
///                    rebuilt with the right profile before any scan.
///  * [remoteId]    — last-known BLE device id, for reconnect / identification.
///  * last-known summary — [soc] %, [packVoltage] V, [remainingAh], [fullAh] and
///    the [lastSeenMs] epoch — shown greyed on the offline entry and (fullAh /
///    remainingAh) still counted in the fleet capacity totals (#36) while the
///    pack is offline.
class FleetRecord {
  final String serial;
  final String profile; // DeviceProfile.advPrefix: 'JS' (Sphere) or 'RV'
  final String? remoteId;
  final int? soc;
  final double? packVoltage;
  final double? remainingAh;
  final double? fullAh;
  final int? lastSeenMs;

  const FleetRecord({
    required this.serial,
    this.profile = 'JS',
    this.remoteId,
    this.soc,
    this.packVoltage,
    this.remainingAh,
    this.fullAh,
    this.lastSeenMs,
  });

  Map<String, dynamic> toJson() => {
        'serial': serial,
        'profile': profile,
        if (remoteId != null) 'remoteId': remoteId,
        if (soc != null) 'soc': soc,
        if (packVoltage != null) 'packVoltage': packVoltage,
        if (remainingAh != null) 'remainingAh': remainingAh,
        if (fullAh != null) 'fullAh': fullAh,
        if (lastSeenMs != null) 'lastSeenMs': lastSeenMs,
      };

  factory FleetRecord.fromJson(Map<String, dynamic> j) => FleetRecord(
        serial: j['serial'] as String,
        profile: (j['profile'] as String?) ?? 'JS',
        remoteId: j['remoteId'] as String?,
        soc: (j['soc'] as num?)?.toInt(),
        packVoltage: (j['packVoltage'] as num?)?.toDouble(),
        remainingAh: (j['remainingAh'] as num?)?.toDouble(),
        fullAh: (j['fullAh'] as num?)?.toDouble(),
        lastSeenMs: (j['lastSeenMs'] as num?)?.toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is FleetRecord &&
      other.serial == serial &&
      other.profile == profile &&
      other.remoteId == remoteId &&
      other.soc == soc &&
      other.packVoltage == packVoltage &&
      other.remainingAh == remainingAh &&
      other.fullAh == fullAh &&
      other.lastSeenMs == lastSeenMs;

  @override
  int get hashCode => Object.hash(
      serial, profile, remoteId, soc, packVoltage, remainingAh, fullAh, lastSeenMs);
}

/// Durable storage for fleet membership. Since #34 it persists a [FleetRecord]
/// per in-fleet serial (serial + profile + remoteId + last-known summary), not
/// just the bare serial (#27). Abstracted so the app can back it with
/// shared_preferences while tests use an in-memory fake — the manager never
/// imports the plugin directly. [load] returns the persisted records keyed by
/// serial; [save] replaces the whole set.
abstract class FleetStore {
  Future<Map<String, FleetRecord>> load();
  Future<void> save(Map<String, FleetRecord> records);
}

/// Outcome of a fleet-wide write (M3): which members were written and which
/// failed (serial -> error). A failing member never stops the others.
class FleetWriteResult {
  final List<String> succeeded;
  final Map<String, Object> failed;
  const FleetWriteResult({this.succeeded = const [], this.failed = const {}});

  bool get allOk => failed.isEmpty;

  /// "JS-A: reason; JS-B: reason" for a warning dialog.
  String get failureSummary =>
      failed.entries.map((e) => '${e.key}: ${e.value}').join('\n');
}

class BatteryManager {
  static const _source = 'BatteryManager';

  final List<BatteryConnection> batteries = [];

  /// M13: the error the last scan attempt failed with (adapter off, permission
  /// denied, …), or null once a scan succeeds. The list's empty state shows
  /// [scanErrorText] instead of "Scanning for batteries…" forever.
  Object? lastScanError;

  /// User-facing text for [lastScanError], or null when scanning is fine.
  String? get scanErrorText =>
      lastScanError == null ? null : describeScanError(lastScanError!);

  /// DETECT-only (issue #15): other-family BMS devices recognised in range but
  /// NOT supported for decode. These are surfaced in the UI as muted "detected ·
  /// not yet supported" entries. They are deliberately kept OUT of every
  /// connect / handshake / decode / logging path — no [BatteryConnection] is
  /// created for them. DECODE per family is future work.
  final List<DetectedDevice> detectedOthers = [];
  final Map<String, DetectedDevice> _othersById = {}; // deviceId -> detected

  /// L12: the current scan window's generation number. Every sighting of a
  /// detected (other-family) device stamps it with this; after each completed
  /// scan window, devices not sighted for [detectedStaleScans] windows are
  /// pruned so a BMS that left range does not linger as a "detected" card.
  int scanGeneration = 0;

  /// L12: how many consecutive scan windows a detected device may go unseen
  /// before it is pruned.
  static const int detectedStaleScans = 3;

  /// True while live BLE scanning is active (vs. the synthetic demo fleet).
  bool get isLive => _live;
  bool _live = false;

  /// #52: [startLive] has run (the rows are live rows, not demo rows), so
  /// [resumeLive] can restart scanning WITHOUT disposing them.
  bool _liveStarted = false;

  /// #52: true between [pauseLive] and [resumeLive]/[startLive]. A connect that
  /// was already in flight when the pause landed drops its link the moment it
  /// completes, so a pause never leaves a pack grabbed.
  bool _released = false;

  /// #52: true while [pauseLive] has released the packs.
  bool get isPaused => _released;

  // Live-scan bookkeeping.
  final Duration scanWindow;
  final Duration rescanInterval;
  final Map<String, BatteryConnection> _byId = {}; // deviceId -> connection
  final Set<String> _connecting = {}; // deviceIds mid-connect (dedupe)
  Timer? _rescanTimer;
  StreamSubscription<List<BleScanHit>>? _scanSub;

  /// BLE transport shared with the connections it creates (flutter_blue_plus on
  /// mobile, universal_ble on Windows). Injectable for tests (M13); defaults
  /// to the platform transport.
  final BleTransport transport;

  /// Durable fleet-membership store (issue #27). Null in tests / when no backing
  /// store is provided, in which case membership is session-only as before.
  final FleetStore? fleetStore;

  /// How often live telemetry is written back into the persisted favourite
  /// records (#34). Throttled so storage is not thrashed by every frame.
  final Duration recordSaveInterval;

  /// Clock used for every timing decision in the manager (the snapshot/record
  /// throttle in particular, #47). Defaults to the real wall clock; tests inject
  /// a controllable fake so the throttle/changed logic is deterministic and does
  /// not hinge on a sub-millisecond wall-clock race. Runtime behaviour is
  /// unchanged — the default stays [DateTime.now].
  final DateTime Function() now;

  BatteryManager({
    this.scanWindow = const Duration(seconds: 8),
    this.rescanInterval = const Duration(seconds: 20),
    this.aggregateInterval = const Duration(seconds: 60),
    this.recordSaveInterval = const Duration(seconds: 60),
    this.fleetStore,
    this.now = DateTime.now,
    BleTransport? transport,
  }) : transport = transport ?? defaultBleTransport;

  // -------------------------------------------------------------------------
  // Demo fleet (unchanged behaviour, now gated behind the Live/Demo toggle).
  // -------------------------------------------------------------------------

  /// Seed the list with four synthetic packs in different states, so the
  /// list and the fleet total are populated without hardware.
  void startDemoFleet() {
    stopLive();
    disposeAll();
    _live = false;
    _liveStarted = false; // #52: rows are demo rows; resumeLive -> startLive
    _released = false;
    final seeds = <(DeviceProfile, String, int, DemoMode, int)>[
      (DeviceProfile.sphere, 'JS-2C14AA', 64, DemoMode.discharging, -54),
      (DeviceProfile.sphere, 'JS-9F031B', 9, DemoMode.charging, -67),
      (DeviceProfile.sphere, 'JS-5A77C0', 100, DemoMode.idle, -78),
      (DeviceProfile.rv, 'RV-1180E2', 47, DemoMode.idle, -61),
    ];
    for (final (profile, serial, soc, mode, rssi) in seeds) {
      // Manual membership (issue #10): demo packs start OUTSIDE the fleet too,
      // unless the user re-added this serial earlier in the session.
      final c = BatteryConnection(profile: profile)
        ..inFleet = fleetSerials.contains(serial);
      c.startDemo(startSoc: soc, mode: mode, serial: serial);
      c.state.rssi = rssi; // synthetic signal strength for the demo fleet
      BatteryLogger.instance.attach(c); // demo telemetry is logged too
      batteries.add(c);
    }
    startLifetimeTotals(); // #37: keep lifetime totals current, cheaply
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
    _liveStarted = true;
    _released = false;
    await BatteryLogger.instance.init();
    // #34: show remembered favourites immediately as offline placeholders —
    // before any scan — so they are always visible with their last-known values.
    // A discovered pack later BINDS to the same entry (see [resolveDiscovered]).
    materialiseRememberedFleet();
    await _scanOnce();
    _armRescan();
  }

  /// #52: after the first scan window, arm the periodic rescan — unless a
  /// [stopLive]/[pauseLive] landed DURING that window, in which case scanning
  /// must stay off (re-arming it would grab the packs the user just released).
  void _armRescan() {
    if (!_live) return;
    _rescanTimer?.cancel();
    _rescanTimer = Timer.periodic(rescanInterval, (_) => _scanOnce());
    startLifetimeTotals(); // #37: keep lifetime totals current, cheaply
  }

  /// #52: release every battery — stop scanning / reconnecting, disconnect each
  /// pack (an EXPECTED disconnect: no alarm/beep/notification), and stop the
  /// lifetime-totals timer — but KEEP the rows (they show as offline with their
  /// last values) so [resumeLive] picks up where it left off. This is what
  /// "Pause monitoring", the notification's "Stop monitoring" action, and
  /// backgrounding with background monitoring OFF all drive, so another BLE
  /// client (the PC tools) can take the packs.
  Future<void> pauseLive() async {
    _released = true;
    stopLive();
    _aggTimer?.cancel();
    _aggTimer = null;
    for (final b in List.of(batteries)) {
      await b.disconnect();
    }
  }

  /// #52: undo [pauseLive]: scan again and reconnect the (kept) rows. Falls
  /// back to a full [startLive] if live mode was never started (e.g. coming
  /// from demo). No-op while already live.
  Future<void> resumeLive() async {
    if (_live) return;
    if (!_liveStarted) return startLive();
    _released = false;
    _live = true;
    await _scanOnce();
    _armRescan();
  }

  /// Stop live scanning (leaves any created connections in place unless a
  /// caller also disposes them; [startDemoFleet]/[startLive] dispose first).
  void stopLive() {
    _live = false;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _scanSub?.cancel();
    _scanSub = null;
    // Best effort: stopScan() may throw synchronously OR reject (e.g. the WinRT
    // backend rejects if no adapter/plugin is present, as under `flutter
    // test`). guard() covers both and records the failure.
    unawaited(guard<void>('stop scan', () => transport.stopScan(),
        source: _source));
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
      lastScanError = null; // M13: scanning works
      // Let the scan window elapse, then stop so the next tick can rescan.
      await Future<void>.delayed(scanWindow);
      await transport.stopScan();
      await _scanSub?.cancel();
      _scanSub = null;
      // L12: a completed window ages the detected-device cards; only a scan
      // that actually ran counts (a failed scan sights nobody).
      pruneStaleDetected();
      scanGeneration++;
    } catch (e) {
      // Adapter off / busy / permission denied: recorded and surfaced (M13);
      // the next tick tries again.
      lastScanError = e;
      AppLog.instance.record(_source, 'scan failed: $e');
    }
  }

  void _handleScanResult(BleScanHit r) {
    final name = r.name;
    // Recognise the BMS family (issue #15). A scan advertisement carries service
    // UUIDs but not characteristics, so unsupported families are matched by name
    // (and, for JoySuny, also by its proprietary FCF0 service). Unknown/generic
    // gadgets return null and are ignored.
    final family = matchBmsFamily(name: name, serviceUuids: r.serviceUuids);
    if (family == null) return;

    // DETECT-only: an other-family BMS. Surface it as a muted entry, but do NOT
    // connect, handshake, decode, or start a logging stream. DECODE is future
    // work (each family has its own frame protocol).
    if (!family.supported) {
      final existing = _othersById[r.deviceId];
      if (existing != null) {
        existing.rssi = r.rssi; // refresh signal strength every scan
        existing.lastSeenScan = scanGeneration; // L12: still in range
        return;
      }
      final d = DetectedDevice(
        deviceId: r.deviceId,
        family: family,
        name: name,
        rssi: r.rssi,
        lastSeenScan: scanGeneration,
      );
      _othersById[r.deviceId] = d;
      detectedOthers.add(d);
      return;
    }

    // ---- Supported (JoySuny) path — unchanged behaviour. --------------------
    final isRv = name.startsWith('RV');

    final id = r.deviceId;
    final existing = _byId[id];
    if (existing != null) {
      existing.state.rssi = r.rssi; // refresh signal strength every scan
      // Reconnect a dropped battery that is advertising again (issue #49): the
      // rescan re-attempts it (subject to the connect backoff) whenever it is
      // seen disconnected while still advertising.
      if (existing.connState == ConnState.disconnected) {
        unawaited(_connect(existing, id, name));
      }
      return;
    }

    // Resolve to a row: BIND to a remembered offline entry with the same serial
    // (#34, no duplicate row) or create a new one. Membership (#10/#27) is
    // restored from the persisted records either way.
    final serial = name.isNotEmpty ? name : id;
    final profile = isRv ? DeviceProfile.rv : DeviceProfile.sphere;
    final conn = resolveDiscovered(
      serial: serial,
      deviceId: id,
      profile: profile,
      rssi: r.rssi,
    );
    BatteryLogger.instance.attach(conn); // record its telemetry to SQLite
    unawaited(_connect(conn, id, name));
  }

  // Reconnect backoff (issue #49). A connect that fails (weak signal, WinRT
  // 'Unreachable', timeout, …) arms a growing per-device delay before the next
  // attempt, so the rescan keeps RETRYING a dropped pack without hammering the
  // adapter. A successful connect clears the backoff so a later drop starts
  // fresh. Times use [now] so the backoff is deterministic under test.
  static const int _minBackoffMs = 3000;
  static const int _maxBackoffMs = 60000;
  final Map<String, int> _backoffMs = {}; // deviceId -> current backoff
  final Map<String, int> _nextAttemptMs = {}; // deviceId -> earliest next try

  /// Attempt to (re)connect [conn] on [deviceId]. Deduped by [_connecting] so a
  /// second scan tick never launches a parallel connect for the same device, and
  /// rate-limited by an exponential backoff after failures. CRITICAL: [_connecting]
  /// is cleared in a `finally` on EVERY path — success, exception or timeout —
  /// so a battery can never get stuck un-retryable (issue #49). Never throws.
  Future<void> _connect(
      BatteryConnection conn, String deviceId, String name) async {
    if (_connecting.contains(deviceId)) return;
    // Respect the backoff window for a device that recently failed to connect.
    final nowMs = now().millisecondsSinceEpoch;
    final nextOk = _nextAttemptMs[deviceId];
    if (nextOk != null && nowMs < nextOk) return;

    _connecting.add(deviceId);
    try {
      await conn.connectTo(deviceId, name: name);
      // Connected: clear any backoff so the next drop retries immediately.
      _backoffMs.remove(deviceId);
      _nextAttemptMs.remove(deviceId);
      // #52: a pause landed while this connect was in flight — let go again
      // so the user's "release the batteries" actually holds.
      if (_released) await conn.disconnect();
    } catch (e) {
      // Failed/aborted connect: the row is already marked disconnected by
      // connectTo, so the next rescan is eligible to retry — but not before the
      // backoff elapses. Grow the delay geometrically up to the cap.
      final prev = _backoffMs[deviceId] ?? 0;
      final next = prev == 0
          ? _minBackoffMs
          : (prev * 2 > _maxBackoffMs ? _maxBackoffMs : prev * 2);
      _backoffMs[deviceId] = next;
      _nextAttemptMs[deviceId] = now().millisecondsSinceEpoch + next;
      AppLog.instance.record(_source,
          'connect $name ($deviceId) failed, retry in ${next ~/ 1000} s: $e');
    } finally {
      // ALWAYS clear the dedupe entry, even on an exception/timeout above, so
      // the device is never left stuck in _connecting and un-retryable.
      _connecting.remove(deviceId);
    }
  }

  /// Test hook (M13): run one scan pass through the real error-recording path.
  Future<void> scanOnceForTest() => _scanOnce();

  /// L12: drop every detected (other-family) device that has not been sighted
  /// in the last [detectedStaleScans] scan windows, i.e. whose
  /// [DetectedDevice.lastSeenScan] is more than that many generations behind
  /// [scanGeneration]. Called after each completed scan window; exposed for
  /// tests. Supported (JoySuny) rows are never touched here.
  void pruneStaleDetected() {
    detectedOthers.removeWhere((d) {
      final stale = scanGeneration - d.lastSeenScan >= detectedStaleScans;
      if (stale) _othersById.remove(d.deviceId);
      return stale;
    });
  }

  /// Test hook (issue #49): drive one connect attempt through the real dedupe +
  /// backoff path. Exposed for tests; runtime code calls [_connect] directly.
  Future<void> connectForTest(
          BatteryConnection conn, String deviceId, String name) =>
      _connect(conn, deviceId, name);

  /// Device ids with a connect in flight (dedupe set). Exposed for tests.
  Set<String> get connectingIds => Set.unmodifiable(_connecting);

  /// Earliest epoch-ms the manager will retry [deviceId], or null if not backed
  /// off. Exposed for tests.
  int? nextAttemptMsFor(String deviceId) => _nextAttemptMs[deviceId];

  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // Manual fleet membership (issue #10). Membership is by serial and MANUAL:
  // the user adds/removes each battery. The serial set restores membership
  // across reconnects and rescans within a session, and — since issue #27 — is
  // PERSISTED durably via [fleetStore] so it survives an app kill/restart and is
  // re-applied to each pack as it is (re)discovered.
  // -------------------------------------------------------------------------

  /// Persisted favourites keyed by serial (#34). Replaces the bare serial set
  /// (#27); [fleetSerials] still exposes just the keys for the scan/demo paths.
  final Map<String, FleetRecord> _fleetRecords = {};

  /// The in-fleet serials (derived from the persisted records). Kept for the
  /// scan/demo membership-restore paths and the existing tests.
  Set<String> get fleetSerials => _fleetRecords.keys.toSet();

  /// The persisted favourite records (read-only view), keyed by serial.
  Map<String, FleetRecord> get fleetRecords => Map.unmodifiable(_fleetRecords);

  int _lastRecordSaveMs = 0;

  /// Restore persisted fleet membership (#27/#34). Loads the durable records and
  /// applies membership to any already-known batteries; later-discovered packs
  /// pick it up via [fleetSerials] in the scan/demo paths, and offline
  /// placeholders are created by [materialiseRememberedFleet]. No-op without a
  /// store. Does NOT itself add rows, so it stays cheap and hermetic.
  Future<void> loadFleetMembership() async {
    final store = fleetStore;
    if (store == null) return;
    final records = await store.load();
    _fleetRecords
      ..clear()
      ..addAll(records);
    for (final b in batteries) {
      final serial = b.state.serial;
      if (serial != null && serial.isNotEmpty) {
        b.inFleet = _fleetRecords.containsKey(serial);
      }
    }
  }

  /// Create an OFFLINE placeholder [BatteryConnection] for every persisted
  /// favourite (#34) not already present as a row, seeded with its last-known
  /// values and marked offline. Called by [startLive] right after the list is
  /// cleared, so favourites are always visible even before / independent of any
  /// scan, and whether or not the pack is ever discovered this session.
  void materialiseRememberedFleet() {
    for (final r in _fleetRecords.values) {
      final existing = _findBySerial(r.serial);
      if (existing != null) {
        existing.inFleet = true;
        continue;
      }
      batteries.add(_makeRemembered(r));
    }
  }

  BatteryConnection _makeRemembered(FleetRecord r) {
    final profile = r.profile == 'RV' ? DeviceProfile.rv : DeviceProfile.sphere;
    final c = BatteryConnection(profile: profile, transport: transport)
      ..inFleet = true
      ..isRemembered = true
      ..rememberedRemoteId = r.remoteId
      ..lastSeenMs = r.lastSeenMs
      ..connState = ConnState.disconnected; // offline until (re)discovered
    c.state
      ..serial = r.serial
      ..socPercent = r.soc
      ..packVoltage = r.packVoltage
      ..remainingAh = r.remainingAh
      ..fullAh = r.fullAh;
    return c;
  }

  BatteryConnection? _findBySerial(String serial) {
    for (final b in batteries) {
      if (b.state.serial == serial) return b;
    }
    return null;
  }

  /// A row with the given serial that is NOT currently bound to a live device id
  /// — i.e. a remembered offline placeholder (or a dropped row) that a fresh
  /// discovery can bind to instead of creating a duplicate. Exposed for tests.
  BatteryConnection? bindableBySerial(String serial) {
    for (final b in batteries) {
      if (b.state.serial == serial && !_byId.containsValue(b)) return b;
    }
    return null;
  }

  /// M12: a row with the given serial that IS bound to some device id but is
  /// currently `disconnected` — a pack whose BLE identifier changed (RPA
  /// rotation / identifier reset) re-advertises under a NEW id; without this it
  /// would get a second row with the same serial. Never a connected or
  /// connecting row (that would steal a live link).
  BatteryConnection? rebindableBySerial(String serial) {
    for (final b in batteries) {
      if (b.state.serial == serial &&
          _byId.containsValue(b) &&
          b.connState == ConnState.disconnected) {
        return b;
      }
    }
    return null;
  }

  /// Resolve the [BatteryConnection] for a freshly discovered supported pack:
  /// BIND to its remembered/offline entry when the serial matches (#34 — no
  /// duplicate row, switch it from offline to live), REBIND a disconnected
  /// row whose device id changed (M12 — remap `_byId` to the new id), or
  /// create a new row. Registers the device-id mapping and returns the
  /// connection; the caller then attaches logging and drives [_connect].
  /// Exposed for tests.
  BatteryConnection resolveDiscovered({
    required String serial,
    required String deviceId,
    required DeviceProfile profile,
    int? rssi,
  }) {
    final bindable = bindableBySerial(serial) ?? rebindableBySerial(serial);
    if (bindable != null) {
      if (rssi != null) bindable.state.rssi = rssi;
      // M12: forget the stale id (and its backoff) so the row is reachable
      // ONLY through the id it currently advertises.
      final oldId = deviceIdOf(bindable);
      if (oldId != null && oldId != deviceId) {
        _byId.remove(oldId);
        _connecting.remove(oldId);
        _backoffMs.remove(oldId);
        _nextAttemptMs.remove(oldId);
        AppLog.instance.record(
            _source, '$serial re-advertised as $deviceId (was $oldId)');
      }
      bindable.rememberedRemoteId = deviceId;
      _byId[deviceId] = bindable;
      return bindable;
    }
    // New battery: NOT in the fleet by default (#10) unless this serial is a
    // persisted favourite, in which case restore membership.
    final conn = BatteryConnection(profile: profile, transport: transport);
    if (rssi != null) conn.state.rssi = rssi;
    conn.state.serial = serial;
    conn.inFleet = _fleetRecords.containsKey(serial);
    conn.isRemembered = conn.inFleet;
    _byId[deviceId] = conn;
    batteries.add(conn);
    return conn;
  }

  /// Add ([member] true) or remove a battery from the fleet. Adding persists a
  /// [FleetRecord] from the live state; removing (#34) drops the remembered
  /// record and, if the row was only an offline placeholder, drops the row too.
  void setInFleet(BatteryConnection conn, bool member) {
    conn.inFleet = member;
    final serial = conn.state.serial;
    if (serial == null || serial.isEmpty) return;
    if (member) {
      _fleetRecords[serial] = _recordFrom(conn);
      conn.isRemembered = true;
    } else {
      _fleetRecords.remove(serial);
      // Un-star drops the remembered record; a pure offline placeholder (no live
      // link) also loses its row entirely so it stops showing.
      if (conn.isRemembered &&
          conn.connState != ConnState.connected &&
          !_byId.containsValue(conn)) {
        batteries.remove(conn);
        conn.dispose();
      }
      conn.isRemembered = false;
    }
    // Persist durably (#27/#34); fire-and-forget, never blocks the UI.
    fleetStore?.save(Map<String, FleetRecord>.from(_fleetRecords));
  }

  FleetRecord _recordFrom(BatteryConnection conn) {
    final s = conn.state;
    final connected = conn.connState == ConnState.connected;
    return FleetRecord(
      serial: s.serial ?? '',
      profile: conn.profile.advPrefix,
      remoteId: conn.rememberedRemoteId ?? deviceIdOf(conn),
      soc: s.socPercent,
      packVoltage: s.packVoltage,
      remainingAh: s.remainingAh,
      fullAh: s.fullAh,
      lastSeenMs: connected
          ? now().millisecondsSinceEpoch
          : conn.lastSeenMs,
    );
  }

  /// The BLE device id [conn] is currently bound to, or null (an offline
  /// placeholder / a demo pack).
  String? deviceIdOf(BatteryConnection conn) {
    for (final e in _byId.entries) {
      if (e.value == conn) return e.key;
    }
    return null;
  }

  /// Refresh persisted favourite records from LIVE telemetry (#34). Called
  /// frequently by the UI ticker but only writes to storage about once per
  /// [recordSaveInterval] (or when [force]), so it never thrashes the store.
  /// Offline members keep their previous record untouched.
  void persistFleetSnapshot({bool force = false}) {
    if (fleetStore == null || _fleetRecords.isEmpty) return;
    var changed = false;
    for (final b in fleetMembers) {
      if (b.connState != ConnState.connected) continue;
      final serial = b.state.serial;
      if (serial == null || serial.isEmpty) continue;
      b.lastSeenMs = now().millisecondsSinceEpoch;
      final next = _recordFrom(b);
      if (_fleetRecords[serial] != next) changed = true;
      _fleetRecords[serial] = next;
    }
    if (!changed) return;
    final nowMs = now().millisecondsSinceEpoch;
    if (!force && nowMs - _lastRecordSaveMs < recordSaveInterval.inMilliseconds) {
      return;
    }
    _lastRecordSaveMs = nowMs;
    fleetStore?.save(Map<String, FleetRecord>.from(_fleetRecords));
  }

  /// The batteries the user has added to the fleet (live AND offline members).
  List<BatteryConnection> get fleetMembers =>
      batteries.where((b) => b.inFleet).toList();

  /// Fleet members that are currently connected (live). Net current/power sum
  /// only these; offline members are excluded from live power (#34) but still
  /// count toward the capacity totals below (#36).
  List<BatteryConnection> get connectedFleetMembers =>
      fleetMembers.where((b) => b.connState == ConnState.connected).toList();

  /// Fleet members that are currently offline (a remembered placeholder or a
  /// dropped pack), shown with their last-known values, clearly marked offline.
  List<BatteryConnection> get offlineFleetMembers =>
      fleetMembers.where((b) => b.connState != ConnState.connected).toList();

  /// Total rated capacity across ALL fleet members (#36) — including offline
  /// members' last-known [fullAh], so the total stays stable when a pack drops.
  double get totalCapacityAh =>
      fleetMembers.fold(0.0, (a, b) => a + (b.state.fullAh ?? 0));

  /// Total remaining Ah across ALL fleet members (#36), offline members
  /// contributing their last-known remaining.
  double get totalRemainingAh =>
      fleetMembers.fold(0.0, (a, b) => a + (b.state.remainingAh ?? 0));

  /// Combined charge as remaining / full across the fleet.
  int? get combinedSocPercent {
    final full = totalCapacityAh;
    if (full <= 0) return null;
    return ((totalRemainingAh / full) * 100).round().clamp(0, 100);
  }

  // Net current/power sum ONLY connected members (#34): an offline member
  // contributes no live current/power.
  double get netCurrentA =>
      connectedFleetMembers.fold(0.0, (a, b) => a + b.signedCurrent);
  double get netPowerW =>
      connectedFleetMembers.fold(0.0, (a, b) => a + b.signedPower);

  // -------------------------------------------------------------------------
  // Fleet-control gating (issue #11). Fleet-level write actions are ENABLED
  // only when EVERY fleet member is currently connected. Individual battery
  // controls remain available regardless.
  // -------------------------------------------------------------------------

  int get fleetConnectedCount =>
      fleetMembers.where((b) => b.connState == ConnState.connected).length;

  /// True iff there is at least one member and all members are connected.
  bool get fleetAllConnected {
    final m = fleetMembers;
    return m.isNotEmpty && m.every((b) => b.connState == ConnState.connected);
  }

  /// Why fleet controls are disabled, or null when they are enabled.
  String? get fleetControlsDisabledReason {
    final m = fleetMembers;
    if (m.isEmpty) return 'No batteries in the fleet — add some with the star.';
    if (fleetAllConnected) return null;
    return '$fleetConnectedCount/${m.length} fleet batteries connected — '
        'connect all to use fleet controls';
  }

  /// C1: why the fleet OUTPUT buttons (real gate writes) are disabled, or null
  /// when every member is connected AND has a fresh gate base. Stricter than
  /// [fleetControlsDisabledReason]: a connected member whose BAL_STATUS has not
  /// arrived yet (or is stale) blocks the whole fleet write, because a frame
  /// built from its unknown gates could cut that pack's output.
  String? get fleetGateWriteDisabledReason =>
      fleetOutputWriteDisabledReason(on: false);

  /// Why a fleet-wide output write to [on] is refused, or null. #59: output
  /// ON is a SAFE write (it cannot cut anything) and only needs every member
  /// connected; output OFF additionally needs every member's fresh gate base.
  String? fleetOutputWriteDisabledReason({required bool on}) {
    final conn = fleetControlsDisabledReason;
    if (conn != null) return conn;
    for (final b in fleetMembers) {
      final r = b.disabledReasonFor(GateAction.output, on: on);
      if (r != null) return '${b.state.serial ?? 'a fleet battery'}: $r';
    }
    return null;
  }

  /// Apply an Output change to every fleet member. Issue #26: this now mirrors
  /// the vendor setMos — [GateAction.output] moves BOTH FET bytes together —
  /// rather than toggling the discharge MOS alone. Callers MUST confirm first and
  /// gate on [fleetGateWriteDisabledReason]; this fires real writes.
  ///
  /// SAFETY (audit C1): REFUSES with a [StateError] — before sending anything —
  /// unless EVERY member has [BatteryConnection.hasFreshGateState]. A member
  /// without a fresh BAL_STATUS would otherwise get a frame built from unknown
  /// gates (chargeMos = dischargeMos = 0 = output cut). No partial writes.
  ///
  /// M3: once the pre-check passes, every member is attempted even if an
  /// earlier one throws (link dropped mid-write, GATT failure, a base that
  /// went stale in between); the per-member outcome is returned rather than
  /// aborting on the first failure.
  Future<FleetWriteResult> fleetSetOutput(bool on) async {
    final reason = fleetOutputWriteDisabledReason(on: on);
    if (reason != null) {
      throw StateError('Refusing fleet output write: $reason');
    }
    final ok = <String>[];
    final failed = <String, Object>{};
    for (final b in fleetMembers) {
      final serial = b.state.serial ?? 'unknown';
      try {
        await b.sendGateControl(GateAction.output, on: on);
        ok.add(serial);
      } catch (e) {
        AppLog.instance.record(_source,
            'fleet write: $serial output ${on ? 'ON' : 'OFF'} failed: $e');
        failed[serial] = e;
      }
    }
    return FleetWriteResult(succeeded: ok, failed: failed);
  }

  // -------------------------------------------------------------------------
  // Lifetime totals (issue #37). ALWAYS ON — there is no toggle. The totals are
  // maintained incrementally and checkpointed in the `lifetime_totals` table:
  // each refresh folds ONLY the readings newer than the stored watermark into
  // the running per-battery totals, so it is cheap (O(new rows), never a full
  // rescan) and safe to run on startup and on a periodic tick.
  // -------------------------------------------------------------------------

  Timer? _aggTimer;

  /// How often the incremental lifetime-totals refresh runs.
  final Duration aggregateInterval;

  /// Latest persisted totals per serial, cached in memory for the UI.
  final Map<String, AggregateTotals> _aggregates = {};

  /// Latest lifetime totals for [serial], or null if not yet loaded.
  AggregateTotals? aggregateFor(String? serial) =>
      serial == null ? null : _aggregates[serial];

  /// Summed lifetime totals across the fleet (serials already loaded).
  AggregateTotals get fleetAggregate {
    var total = const AggregateTotals();
    for (final b in fleetMembers) {
      final t = _aggregates[b.state.serial];
      if (t != null) total = total + t;
    }
    return total;
  }

  /// Kick off the always-on lifetime-totals maintenance: one immediate refresh
  /// then a cheap periodic one. Called from the demo / live start paths.
  void startLifetimeTotals() {
    _aggTimer?.cancel();
    refreshLifetimeTotals();
    _aggTimer =
        Timer.periodic(aggregateInterval, (_) => refreshLifetimeTotals());
  }

  /// True while a [refreshLifetimeTotals] pass is running (M5): a periodic tick
  /// that lands during a slow pass is skipped rather than overlapped.
  bool _refreshingLifetime = false;

  /// Incrementally extend and cache each known battery's persisted lifetime
  /// totals. Read-only over `readings`; only the checkpoint table is written.
  ///
  /// M5: this runs from a [Timer] with nobody awaiting it, so it must NEVER
  /// throw — every DB failure is caught and logged, the pass is skipped while
  /// the logger is disabled/disposed, and overlapping ticks are coalesced.
  Future<void> refreshLifetimeTotals() async {
    if (_refreshingLifetime) return;
    final logger = BatteryLogger.instance;
    if (!logger.enabled) return;
    _refreshingLifetime = true;
    try {
      for (final b in List<BatteryConnection>.from(batteries)) {
        final serial = b.state.serial;
        if (serial == null || serial.isEmpty) continue;
        if (!logger.enabled) return; // disposed mid-pass
        try {
          final lt = await logger.updateLifetimeTotals(serial);
          _aggregates[serial] = lt.totals;
        } catch (e) {
          AppLog.instance
              .record(_source, 'lifetime refresh for $serial failed: $e');
        }
      }
    } finally {
      _refreshingLifetime = false;
    }
  }

  /// True iff any fleet member is currently in alarm. Issue #21: this drives
  /// the fault-red OVERRIDE of the fleet SOC colour, exactly like the per-battery
  /// bar uses [BatteryConnection.alarmActive] with [HealthPalette.socOrFault].
  bool get fleetAlarmActive => fleetMembers.any((b) => b.alarmActive);

  /// Net direction of the fleet.
  ChargeState get fleetState {
    final p = netPowerW;
    if (p > 0.5) return ChargeState.charging;
    if (p < -0.5) return ChargeState.discharging;
    return ChargeState.idle;
  }

  void disposeAll() {
    _aggTimer?.cancel();
    _aggTimer = null;
    for (final b in batteries) {
      b.dispose();
    }
    batteries.clear();
    _byId.clear();
    _connecting.clear();
    _backoffMs.clear();
    _nextAttemptMs.clear();
    _aggregates.clear();
    detectedOthers.clear();
    _othersById.clear();
  }
}
