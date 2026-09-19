/// BLE transport using flutter_blue_plus (iOS + Android).
/// Scans, connects, subscribes to FCF2, runs the handshake, and feeds incoming
/// bytes to [BatteryParser]. A demo mode replays synthetic frames with no BLE.
library;

import 'dart:async';

import 'battery_protocol.dart';
import 'ble_transport.dart';
import 'demo_source.dart';
import 'diagnostics.dart';
import 'fmt.dart' show hexOf;
import 'raw_log.dart';

enum ConnState { idle, scanning, connecting, connected, disconnected }

/// Something attached to a connection that must be released with it (M11):
/// the logger's stream subscriptions. Returned by `BatteryLogger.attach`,
/// stored as [BatteryConnection.loggerAttachment] and cancelled by
/// [BatteryConnection.dispose], so nothing accumulates across demo/live
/// toggles or an un-star.
abstract class ConnectionAttachment {
  Future<void> cancel();
}

class BatteryConnection {
  static const _source = 'BatteryConnection';

  /// M11: the logger's attachment for this connection, if any. Cancelled (and
  /// cleared) by [dispose].
  ConnectionAttachment? loggerAttachment;
  final DeviceProfile profile;

  /// Full handshake sends a gate-control frame that can flip battery gates.
  /// Off by default; enable only if a BMS refuses to stream without it.
  final bool sendLowTempGate;

  /// BLE transport (flutter_blue_plus on mobile, universal_ble on Windows).
  /// Injectable for tests; defaults to the platform-selected [defaultBleTransport].
  final BleTransport transport;

  /// Clock for every freshness / expectation decision (gate-status age, the
  /// expected-disconnect window). Defaults to the wall clock; tests inject a
  /// controllable fake so the 5 s freshness rule is deterministic.
  final DateTime Function() now;

  /// L15: hard upper bound on one [connectTo] attempt (connect + service
  /// discovery + subscribe + handshake). Without it a WinRT/FBP connect could
  /// hang ~100 s while holding the manager's `_connecting` dedupe slot. A
  /// timeout is treated as a NORMAL failed connect (row marked disconnected,
  /// retried by the rescan). Injectable so tests can shorten it.
  final Duration connectTimeout;

  static const Duration defaultConnectTimeout = Duration(seconds: 45);

  BatteryConnection({
    this.profile = DeviceProfile.sphere,
    this.sendLowTempGate = false,
    BleTransport? transport,
    this.now = DateTime.now,
    this.connectTimeout = defaultConnectTimeout,
  })  : transport = transport ?? defaultBleTransport,
        commands = BatteryCommands(profile),
        state = BatteryState() {
    parser = BatteryParser(
      state: state,
      onEvent: (e) {
        // C1: a decoded BAL_STATUS is the ONLY thing that makes the gate base
        // fresh enough to build a gate-control write from.
        if (e is BalancerEvent) lastGateStatusMs = now().millisecondsSinceEpoch;
        _integrateThroughput(DateTime.now().millisecondsSinceEpoch);
        _detectAlerts();
        // L11: a frame that lands after dispose() must not throw on the closed
        // controller (a demo/link callback can still be in flight).
        if (!_events.isClosed) _events.add(e);
        _logDecoded(e);
      },
      // Issue #20: each stray byte the resync path drops is written to the raw
      // log as an UNRECOGNISED line, with its running per-battery count.
      onUnrecognisedByte: (b) => RawLogger.instance.logUnrecognised(
        state.serial ?? '',
        b,
        runningCount: state.unrecognisedBytes,
      ),
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

  /// H3: a disconnect the USER caused — [disconnect], a Restart-BMS or a
  /// factory-reset write (the pack reboots and the link drops). Such a drop must
  /// not alarm/beep/notify. Set with [markExpectedDisconnect]; cleared on the
  /// next successful connect, and ignored once [expectedDisconnectWindowMs] has
  /// passed so a much later, genuine drop still alarms.
  bool expectedDisconnect = false;
  int _expectedDisconnectSetMs = 0;
  static const int expectedDisconnectWindowMs = 60 * 1000;

  /// True while a disconnect is expected (flag set within the window).
  bool get disconnectExpected =>
      expectedDisconnect &&
      now().millisecondsSinceEpoch - _expectedDisconnectSetMs <
          expectedDisconnectWindowMs;

  void markExpectedDisconnect() {
    expectedDisconnect = true;
    _expectedDisconnectSetMs = now().millisecondsSinceEpoch;
  }

  /// M1(c): after a user-initiated Restart/factory the pack's unknown status
  /// bytes may legitimately change (the restart is exactly what clears latched
  /// state), so the unknown-byte baseline is re-taken on the next connect
  /// instead of alarming on the difference.
  bool _rebaselineOnReconnect = false;

  void _setConn(ConnState s) {
    // L11: a late link-state callback (or a disconnect() after dispose()) must
    // not throw on the closed controller.
    if (_conn.isClosed) return;
    final prev = connState;
    connState = s;
    // H3: alert ONLY on a TRUE connected -> disconnected transition — a live
    // pack that dropped. A failed (re)connect attempt goes connecting ->
    // disconnected and must never alarm/beep: the manager keeps retrying at
    // weak signal (#49) and every retry used to raise the alarm again. A drop
    // the user caused (disconnect / Restart BMS / factory reset) is expected
    // and does not alarm either.
    if (s == ConnState.disconnected) {
      if (prev == ConnState.connected && !disconnectExpected) {
        _linkError = true;
        _raiseAlert('Disconnected / BLE error');
      }
    } else if (s == ConnState.connected) {
      expectedDisconnect = false;
      _linkError = false;
      if (_rebaselineOnReconnect) {
        _rebaselineOnReconnect = false;
        _unknownBaseline.clear();
      }
      _recomputeAlarm();
    }
    _conn.add(s);
  }

  // --- gate-state freshness (audit C1, SAFETY-CRITICAL) ---------------------

  /// Epoch-ms of the last decoded BAL_STATUS (balancer) frame on this link, or
  /// null if none has been decoded yet. Reset on every (re)connect.
  int? lastGateStatusMs;

  /// A gate-control write is only allowed while the gate base is fresh.
  static const int gateFreshnessMs = 5000;

  /// C1: true iff we are connected, EVERY one of the six persistent gates has
  /// been reported (chargeMos, dischargeMos, tempControlGate, smokeGate,
  /// heatGate, passiveBalancing), AND the last BAL_STATUS is younger than
  /// [gateFreshnessMs]. Anything else and a gate write would be built from a
  /// stale/unknown base — which could cut output or disable protection.
  bool get hasFreshGateState => gateControlsDisabledReason == null;

  /// Why gate writes are refused right now, or null when they are allowed.
  String? get gateControlsDisabledReason {
    if (connState != ConnState.connected) return 'Not connected';
    final s = state;
    final last = lastGateStatusMs;
    if (last == null ||
        s.chargeMos == null ||
        s.dischargeMos == null ||
        s.tempControlGate == null ||
        s.smokeGate == null ||
        s.heatGate == null ||
        s.passiveBalancing == null) {
      return 'Waiting for gate status from the battery';
    }
    final ageMs = now().millisecondsSinceEpoch - last;
    if (ageMs >= gateFreshnessMs) {
      return 'Gate status is stale (no status for ${(ageMs / 1000).round()} s)';
    }
    return null;
  }

  // --- alerting (task 3 + task 8) ------------------------------------------

  /// Sticky "this battery is in an alarm state" flag — drives the red UI. True
  /// while a genuine fault, an unknown-byte change, or a link error is present.
  bool alarmActive = false;

  /// Human-readable reasons behind [alarmActive], newest kinds last.
  final List<String> alarmReasons = [];

  bool _linkError = false;

  /// Baseline (first-seen) value of every unknown byte; a later change from the
  /// baseline is a MAJOR alert.
  final Map<String, int> _unknownBaseline = {};

  /// Unknown-byte metrics that have changed from their first-seen baseline.
  final Set<String> unknownChangedMetrics = {};

  /// Edge-triggered "please beep" flag consumed by the UI ticker.
  bool _pendingBeep = false;

  /// Read-and-clear the pending-beep edge (called by the UI once per tick).
  bool consumeBeep() {
    final b = _pendingBeep;
    _pendingBeep = false;
    return b;
  }

  void _raiseAlert(String reason) {
    if (alarmReasons.length > 12) alarmReasons.removeAt(0);
    alarmReasons.add(reason);
    _pendingBeep = true;
    _recomputeAlarm();
  }

  bool get _hasGenuineFault =>
      state.faultCurrent || state.faultVoltage || state.faultTemperature;

  /// #45: is a GENUINE fault (real current / voltage / temperature — not the
  /// bogus MOS-overtemp bits) active right now? Exposes the same condition that
  /// drives the fault-red UI, for the system-notification decision.
  bool get hasGenuineFault => _hasGenuineFault;

  /// #45: the active genuine fault kinds (e.g. ['current', 'temperature']).
  List<String> get genuineFaultKinds => _faultList();

  void _recomputeAlarm() {
    alarmActive =
        _hasGenuineFault || unknownChangedMetrics.isNotEmpty || _linkError;
  }

  /// M1(c): the user has seen the alarm. Clears the sticky unknown-byte-change
  /// set and the link-error flag (and their reasons) so the red state drops —
  /// unless a GENUINE fault is still live, which cannot be acknowledged away.
  void acknowledgeAlarms() {
    unknownChangedMetrics.clear();
    _linkError = false;
    alarmReasons.clear();
    if (_hasGenuineFault) alarmReasons.add('Fault: ${_faultList().join(', ')}');
    _recomputeAlarm();
  }

  /// Compare every captured unknown byte against its first-seen baseline. The
  /// first value seen is the baseline (no alert); any later change fires a
  /// MAJOR alert (beep + red). Also re-checks genuine faults every cycle.
  void _detectAlerts() {
    var faultEdge = false;
    // Fault edges (rising) beep once; alarmActive tracks the level.
    if (_hasGenuineFault && !_prevFault) faultEdge = true;
    _prevFault = _hasGenuineFault;

    state.unknownBytes.forEach((name, value) {
      final base = _unknownBaseline[name];
      if (base == null) {
        _unknownBaseline[name] = value; // first seen = baseline, no alert
      } else if (base != value) {
        _unknownBaseline[name] = value; // re-baseline so each change alerts once
        unknownChangedMetrics.add(name);
        _raiseAlert('Unknown byte $name changed $base -> $value');
      }
    });

    if (faultEdge) {
      _raiseAlert('Fault: ${_faultList().join(', ')}');
    } else {
      _recomputeAlarm();
    }
  }

  bool _prevFault = false;

  List<String> _faultList() => [
        if (state.faultCurrent) 'current',
        if (state.faultVoltage) 'voltage',
        if (state.faultTemperature) 'temperature',
      ];

  // --- equivalent full cycles (EFC, task 6) --------------------------------

  /// Cumulative Ah throughput (charge + discharge), integrated live from the
  /// signed pack current: Ah = |I| dt. Divided by rated capacity to give EFC.
  double cumulativeThroughputAh = 0.0;
  int? _lastEfcMs;

  /// EFC = cumulative |I| dt Ah throughput / rated capacity (fullAh). Null until
  /// a rated capacity is known.
  double? get equivalentFullCycles {
    final full = state.fullAh;
    if (full == null || full <= 0) return null;
    return cumulativeThroughputAh / full;
  }

  /// Integrate |signedCurrent| over the time since the last event. Long gaps
  /// (disconnects) are skipped so offline windows do not accrue throughput.
  void _integrateThroughput(int nowMs) {
    final last = _lastEfcMs;
    _lastEfcMs = nowMs;
    if (last == null) return;
    final dtH = (nowMs - last) / 3600000.0;
    if (dtH <= 0 || dtH > 10 / 3600.0) return; // ignore <=0 and >10 s gaps
    cumulativeThroughputAh += signedCurrent.abs() * dtH;
  }

  BleLink? _link;
  StreamSubscription<BleLinkState>? _stateSub;

  /// Connect to [deviceId], discover + subscribe, run the handshake. The whole
  /// sequence is bounded by [connectTimeout] (L15); a timeout is just another
  /// failed connect. Throws on any failure after marking the row disconnected.
  Future<String> connectTo(String deviceId, {String? name}) async {
    _setConn(ConnState.connecting);
    // Reconnect-safe: drop any stale subscriptions/buffer from a prior link.
    // Re-running connectTo rebinds THIS same BatteryConnection/row to the new
    // link — it resets the parser, cancels the old state subscription and (via
    // discoverAndSubscribe) re-subscribes notifications and re-runs the
    // handshake, so no duplicate row or stale parser survives a reconnect (#49).
    await _stateSub?.cancel();
    // Best effort — the old link may already be gone (recorded, never thrown).
    await _dropLink(_link, 'disconnect stale link before reconnect');
    parser.reset();
    // C1: the gate base from the previous link is untrusted until THIS link
    // decodes a BAL_STATUS.
    lastGateStatusMs = null;

    // Every failure below — connect refused, service discovery 'Unreachable',
    // characteristics missing, subscribe rejected, or the whole sequence
    // exceeding [connectTimeout] (L15) — is a NORMAL recoverable drop at weak
    // signal. Mark the row disconnected (so the manager's rescan retries) and
    // never let the error tear anything down; rethrow only so the manager's
    // connect handler can log/back off. Applies to BOTH transports.
    final gen = ++_connectGen;
    try {
      return await _connectSequence(deviceId, name, gen).timeout(
        connectTimeout,
        onTimeout: () => throw TimeoutException(
            'connect to $deviceId exceeded ${connectTimeout.inSeconds} s'),
      );
    } catch (e) {
      // Invalidate a sequence that is still running past the timeout so it can
      // never flip this row to connected (or leak a link) later on.
      if (_connectGen == gen) _connectGen++;
      // Tear down the half-open link and mark disconnected so the row is
      // eligible for reconnect on the next rescan. Do NOT leave connState at
      // `connecting` — that would make the pack un-retryable (issue #49).
      await _stateSub?.cancel();
      _stateSub = null;
      await _dropLink(_link, 'tear down half-open link after failed connect');
      _link = null;
      _setConn(ConnState.disconnected);
      rethrow;
    }
  }

  /// Best-effort link disconnect: a failure (the link is already gone, the
  /// adapter is off) is recorded in Diagnostics and otherwise ignored.
  Future<void> _dropLink(BleLink? link, String why) async {
    if (link == null) return;
    await guard<void>('$why (${link.deviceId})', link.disconnect,
        source: _source);
  }

  /// Generation counter for connect attempts (L15): a sequence that outlives
  /// its timeout (or is overtaken by a newer attempt) sees a different value
  /// and abandons itself instead of binding a stray link to this row.
  int _connectGen = 0;

  /// The unbounded connect + discover + subscribe + handshake sequence;
  /// [connectTo] wraps it in the timeout and the teardown-on-failure.
  Future<String> _connectSequence(String deviceId, String? name, int gen) async {
    final link = await transport.connect(deviceId);
    if (gen != _connectGen) {
      // Timed out / superseded while the transport was connecting: drop the
      // late link rather than adopting it.
      await _dropLink(link, 'drop superseded late link');
      throw StateError('connect attempt to $deviceId was superseded');
    }
    _link = link;

    _stateSub = link.state.listen(
      (s) {
        if (s == BleLinkState.disconnected) {
          _setConn(ConnState.disconnected);
        }
      },
      // A transport-level error on the state stream is just a drop, not a
      // fatal error to propagate to the engine — recorded, then handled.
      onError: (Object e) {
        AppLog.instance.record(_source, 'link state $deviceId: $e');
        _setConn(ConnState.disconnected);
      },
    );

    await link.discoverAndSubscribe((data) {
      // ignore: avoid_print
      print('[RX] ${hex(data)}');
      // Issue #19: capture the RAW notification bytes verbatim, BEFORE framing,
      // so nothing is ever lost (stray 0x30 resync byte / unrecognised bytes).
      RawLogger.instance.logRaw(state.serial ?? deviceId, data);
      parser.addBytes(data);
    });
    if (gen != _connectGen) {
      throw StateError('connect attempt to $deviceId was superseded');
    }

    final resolvedName = name ?? '';
    state.serial = resolvedName.isNotEmpty ? resolvedName : deviceId;
    _setConn(ConnState.connected);
    await _handshake();
    return resolvedName;
  }

  Future<void> _handshake() async {
    await _send(BatteryCommands.begin, label: 'handshake begin');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _send(BatteryCommands.getEst, label: 'request time estimate');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _send(BatteryCommands.getVersion, label: 'request firmware version');
    if (sendLowTempGate) {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await _send(BatteryCommands.lowTempGateFrame, label: 'low-temp gate frame');
    }
  }

  /// Write one command frame on FCF1 (or hand it to the demo battery, which
  /// simulates the BMS acks). M2: throws a [StateError] when there is no link —
  /// it used to silently no-op, so the UI showed "Sent: …" and then a
  /// "not confirmed" warning that could never be satisfied.
  Future<void> _send(List<int> bytes, {String label = 'command'}) async {
    // ignore: avoid_print
    print('[TX] ${hex(bytes)}');
    final demo = _demo;
    if (demo != null) {
      RawLogger.instance.logTx(state.serial ?? '', '$label (demo)', bytes);
      demo.handleWrite(bytes);
      return;
    }
    final link = _link;
    if (link == null || connState != ConnState.connected) {
      throw StateError('Not connected — $label was not sent');
    }
    // Issue #19: also record every command we send to the raw log (TX line).
    RawLogger.instance.logTx(state.serial ?? '', label, bytes);
    await link.write(bytes);
  }

  /// M2: why the NON-gate writes (sleep, capacity) are refused right now, or
  /// null when they are allowed. Gate writes use the stricter
  /// [gateControlsDisabledReason]. Demo mode counts as connected (acks are
  /// simulated).
  String? get writesDisabledReason =>
      connState != ConnState.connected ? 'Not connected' : null;

  /// Manual fleet membership (issue #10): is this battery included in the fleet
  /// total and fleet-level controls? A newly discovered battery is NOT a member
  /// by default; the user adds it with the star/checkbox. The manager mirrors
  /// this into [BatteryManager.fleetSerials] so membership survives reconnects.
  bool inFleet = false;

  /// #34: this row represents a persisted favourite. True for an offline
  /// placeholder created from a [FleetRecord], and for a live favourite. Used
  /// (with [connState]) to decide whether the row is an OFFLINE placeholder.
  bool isRemembered = false;

  /// #34: last time this pack was seen live (epoch ms). Persisted in the
  /// favourite record and shown as "offline · last seen …" on the placeholder.
  int? lastSeenMs;

  /// #34: last-known BLE device id for a favourite, persisted for reconnect /
  /// identification. Set when a live device binds to this row.
  String? rememberedRemoteId;

  /// #34: true when this is a remembered favourite that is not currently
  /// connected — i.e. an offline placeholder showing last-known values.
  bool get isOffline => isRemembered && connState != ConnState.connected;

  // --- write controls: gate-control frames (SAFETY-CRITICAL) ---------------
  // These build and send a real CMD_GATE_CONTROL frame on the FCF1 write
  // characteristic. Callers MUST confirm first — nothing here self-confirms.
  // While disconnected [_send] THROWS (M2); in demo mode the virtual battery
  // acks the write.

  bool get isPassiveBalancingOn => state.passiveBalancing ?? false;

  /// #42 heat-up: the self-heating (heater) gate is on iff BAL_STATUS reports a
  /// non-zero heat byte. Driven through [sendGateControl] with [GateAction.heatGate].
  bool get isHeatOn => (state.heatGate ?? 0) != 0;

  /// #42 sleep: the BMS is in sleep mode iff the last SLEEP_SET_SUCCESS said so.
  bool get isSleepModeOn => state.sleepModeOn ?? false;

  /// #38: the pack's current rated / full capacity in Ah (from SOC frames), the
  /// basis the UI shows before a capacity write and validates the read-back against.
  double? get ratedCapacityAh => state.fullAh;

  /// The single "Output" state the UI shows (issue #26): the vendor drives both
  /// FETs together, so output is ON iff BOTH the charge and discharge MOS report
  /// on. If either FET is off, output is treated as off.
  bool get isOutputOn => (state.chargeMos ?? false) && (state.dischargeMos ?? false);

  /// Read-back for a control write (issue #24). After sending an Output command,
  /// watch the streamed BAL_STATUS frames and complete `true` as soon as the pack
  /// reports both FETs at [expectedOn], or `false` if it has not within [timeout]
  /// (e.g. you sent "output OFF" but chgMos/disMos are still 1). Lets the UI warn
  /// the user that the command did not take effect on the hardware.
  Future<bool> confirmOutputState(
    bool expectedOn, {
    Duration timeout = const Duration(seconds: 4),
  }) {
    // Only a fresh BAL_STATUS frame confirms the change: wait for the next one
    // (or any event that arrives with the state already reflecting the target).
    bool matches() =>
        (state.chargeMos == expectedOn) && (state.dischargeMos == expectedOn);
    return _confirmVia(matches, timeout);
  }

  /// Build a gate-control frame from the LIVE gate state and send it on FCF1.
  /// Only the [action] byte changes; every other gate keeps its current value
  /// (read from the last BAL_STATUS frame). Restart/factory ignore [on].
  ///
  /// SAFETY (audit C1): REFUSES with a [StateError] unless [hasFreshGateState]
  /// — connected, all six gates known, and a BAL_STATUS decoded within the last
  /// [gateFreshnessMs]. It never falls back to a zero-filled base: a frame
  /// built from unknown gates writes chargeMos = dischargeMos = 0 (cutting the
  /// pack's output) or tempControlGate = 0 (disabling low-temp protection).
  Future<void> sendGateControl(GateAction action, {bool on = true}) async {
    final reason = gateControlsDisabledReason;
    final base = GateSnapshot.fromState(state);
    if (reason != null || base == null) {
      throw StateError('Refusing gate write ${action.name}: '
          '${reason ?? 'gate state unknown'} — a write built from a stale or '
          'unknown gate base could cut output or disable protection.');
    }
    final frame = buildGateControlFrame(base: base, action: action, on: on);
    if (action == GateAction.restart || action == GateAction.factory) {
      // H3 / M1(c): the pack reboots — the resulting link drop is expected (no
      // alarm), and the unknown-byte baseline is re-taken on reconnect (and
      // immediately, in case the link survives) because a restart legitimately
      // changes latched status bytes.
      markExpectedDisconnect();
      _rebaselineOnReconnect = true;
      _unknownBaseline.clear();
    }
    await _send(frame, label: 'gate control ${action.name} ${on ? 'on' : 'off'}');
  }

  // --- #42 sleep control (SAFETY-CRITICAL) ---------------------------------
  // Sleep-ON (AA CC 00 01 DD EE) may drop the BLE link and stop telemetry;
  // wake (AA CC 01 01 DD EE) resumes it. Callers MUST confirm first — nothing
  // here self-confirms. The BMS acks with SLEEP_SET_SUCCESS (AC CA ..), decoded
  // into [BatteryState.sleepModeOn] and used as the read-back.

  /// Send the sleep-mode command: [on] true sleeps the BMS, false wakes it.
  Future<void> setSleepMode(bool on) async {
    final frame =
        on ? BatteryCommands.openSleep : BatteryCommands.closeSleep;
    await _send(frame, label: 'sleep mode ${on ? 'on' : 'off'}');
  }

  /// Read-back for a sleep write: complete `true` once SLEEP_SET_SUCCESS reports
  /// [expectedOn], else `false` after [timeout]. Note that sleeping the pack may
  /// drop the link before any ack arrives, so a timeout on sleep-ON is expected.
  Future<bool> confirmSleepState(
    bool expectedOn, {
    Duration timeout = const Duration(seconds: 4),
  }) {
    bool matches() => state.sleepModeOn == expectedOn;
    return _confirmVia(matches, timeout);
  }

  // --- #38 capacity write (SAFETY-CRITICAL) --------------------------------
  // CMD_BATTERY (C5 60 .. D6 2A) writes the pack's rated capacity in mAh. This
  // changes the SOC / remaining-time estimator basis. Callers MUST confirm.

  /// Write a new rated capacity (Ah) via CMD_BATTERY. Clears the previous
  /// capacity-write ack first so [confirmCapacityWrite] only sees a FRESH ack.
  /// Throws [ArgumentError] for an out-of-range value (guarded in the builder).
  Future<void> writeCapacity(double capacityAh) async {
    final frame = buildCapacityWriteFrame(capacityAh); // validates range
    state.capacityWriteAck = null; // so the read-back detects a fresh ack
    await _send(frame,
        label: 'capacity write ${capacityAh.toStringAsFixed(1)} Ah');
  }

  /// Read-back for a capacity write (issue #38): complete `true` once the BMS
  /// sends the type-4 SETTING_RESPOND ack, OR reports [expectedAh] as its rated
  /// capacity; `false` if neither happens within [timeout].
  Future<bool> confirmCapacityWrite(
    double expectedAh, {
    Duration timeout = const Duration(seconds: 4),
  }) {
    bool matches() =>
        state.capacityWriteAck == true ||
        (state.fullAh != null && (state.fullAh! - expectedAh).abs() < 0.5);
    return _confirmVia(matches, timeout);
  }

  /// Shared read-back: complete `true` as soon as [matches] holds on any streamed
  /// event, or with the current [matches] value after [timeout].
  Future<bool> _confirmVia(bool Function() matches, Duration timeout) {
    final completer = Completer<bool>();
    late StreamSubscription<BatteryEvent> sub;
    Timer? timer;
    void finish(bool ok) {
      if (completer.isCompleted) return;
      timer?.cancel();
      sub.cancel();
      completer.complete(ok);
    }

    sub = events.listen((_) {
      if (matches()) finish(true);
    });
    timer = Timer(timeout, () => finish(matches()));
    return completer.future;
  }

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
    markExpectedDisconnect(); // H3: user-initiated — never an alarm
    _demo?.stop();
    _demo = null;
    await _stateSub?.cancel();
    await _dropLink(_link, 'disconnect');
    _link = null;
    _setConn(ConnState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    // M11: release the logger's subscriptions for this row.
    final att = loggerAttachment;
    loggerAttachment = null;
    await att?.cancel();
    await _events.close();
    await _conn.close();
  }

  // Verbose per-event logging so decoded frames appear in the run console.
  static String hex(List<int> b) => hexOf(b);

  void _logDecoded(BatteryEvent e) {
    final s = state;
    // Plain-English label (from the event) plus the decoded detail.
    final detail = switch (e) {
      VoltageEvent() => 'cells=${s.cellsMv} mV',
      TempEvent() =>
        't0=${s.temp0}C t1=${s.temp1}C t2=${s.temp2}C t3=${s.temp3}C',
      AllDataEvent() => 'V=${s.packVoltage} I=${s.packCurrent}A '
          'P=${s.power}W sum=${s.cellSum} max=${s.cellMax} min=${s.cellMin} '
          'diff=${s.cellDiff} avg=${s.cellAvg} chip=${s.chipTemperature}C '
          'cyc=${s.cycleCount} efc=${equivalentFullCycles?.toStringAsFixed(3)} '
          'load=${s.loadConnected} chg=${s.chargerConnected}',
      MosEvent() => 'on=${s.mosOn}',
      BalancerEvent() => 'state=${s.chargeState.name} '
          'chgMos=${s.chargeMos} disMos=${s.dischargeMos} '
          'passiveBal=${s.passiveBalancing} tempGate=${s.tempControlGate} '
          'smokeGate=${s.smokeGate} heatGate=${s.heatGate}',
      SocEvent() => '${s.socPercent}% '
          'remaining=${s.remainingAh}Ah full=${s.fullAh}Ah',
      EstTimeEvent() =>
        'toFull=${s.timeToFullSec}s toEmpty=${s.timeToEmptySec}s',
      VersionEvent() => '${s.firmwareVersion}',
      SleepEvent() => 'mode=${s.sleepModeOn == true ? 'on' : 'off'}',
      SettingRespondEvent(:final type, :final typeName) =>
        'ack type=$type ($typeName)',
      GateSetEvent() => '${s.gateAck}',
      OtherEvent() => 'unknown bytes=${_otherBytes()}',
      WarningEvent(:final category) => category == 'temperature'
          ? '${_warnListFor(category)} overTempLatched=${s.overTempLatched}'
          : '${_warnListFor(category)}',
    };
    // ignore: avoid_print
    print('[EVT] ${e.label.padRight(16)} $detail');
    // Issue #19: mirror the decoded frame into the single raw log — plain-English
    // label, the frame's raw bytes and the short decode summary.
    RawLogger.instance.logEvent(
      state.serial ?? '',
      e.label,
      detail,
      frame: parser.lastFrameBytes,
    );
  }

  String _otherBytes() =>
      [for (var i = 0; i < 9; i++) state.unknownBytes['unknownOtherB$i']]
          .join(' ');

  List<String> _warnListFor(String category) => switch (category) {
        'current' => state.currentWarnings,
        'voltage' => state.voltageWarnings,
        'temperature' => state.temperatureWarnings,
        _ => const [],
      };
}
