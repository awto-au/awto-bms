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
import 'ota_update.dart';
import 'raw_log.dart';

enum ConnState { idle, scanning, connecting, connected, disconnected }

/// #62: what the AT+V probe found about a connected but silent link.
///
/// Live finding (2026-09-20): the BLE bridge is a separate module. A pack
/// whose BMS MCU is not running still connects, answers AT+V with ONLY the
/// bridge's single 0x30 status byte (no AC 9A version frame) and ignores
/// every framed command — nothing over Bluetooth wakes it.
///
/// #63: that 0x30 is INTERMITTENT, so the same pack is often classified
/// [noResponse] instead of [dormant]. Both mean "BMS not running" to the
/// user ([BatteryConnection.bmsNotRunning]) and get the same guidance; the
/// finer verdict is a detail line ([BatteryConnection.probeDetail]) and the
/// Diagnostics `stream …` tag.
enum StreamClass {
  /// No probe yet on this link.
  unknown,

  /// Telemetry frames are flowing.
  streaming,

  /// AT+V answered with only the bridge's 0x30 and no version frame: the
  /// bridge is alive, the BMS MCU is not running.
  dormant,

  /// AT+V answered with a version frame but no telemetry followed: the BMS is
  /// awake and merely not streaming (CMD_BEGIN is re-sent).
  awakeNotStreaming,

  /// Nothing came back within the probe window (not even the 0x30). Treated
  /// like [dormant] for all user-facing guidance (#63).
  noResponse,
}

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
    this.probeWindow = defaultProbeWindow,
  })  : transport = transport ?? defaultBleTransport,
        commands = BatteryCommands(profile),
        state = BatteryState() {
    parser = BatteryParser(
      state: state,
      onEvent: (e) {
        // C1: a decoded BAL_STATUS is the ONLY thing that makes the gate base
        // fresh enough to build a gate-control write from.
        lastFrameMs = now().millisecondsSinceEpoch; // #59 streaming watchdog
        // #61 / #62 / #53: frame bookkeeping for the live indicator, the
        // dormant-BMS probe and the one-cycle background sample.
        frameCount++;
        totalFrameCount++;
        if (e is VersionEvent) {
          lastVersionFrameMs = lastFrameMs;
        } else if (isTelemetryEvent(e)) {
          // Only the STREAM counts as "streaming": a version frame or an
          // ack answers a command and must not clear the silence.
          lastTelemetryMs = lastFrameMs;
          lastFrameEverMs = lastFrameMs;
          _cycleSeen.add(e.runtimeType);
          streamClass = StreamClass.streaming;
        }
        if (e is BalancerEvent) {
          lastGateStatusMs = lastFrameMs;
          _noteGateAvailability();
        }
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
      // #60: the known AT+V status byte — logged as such, never counted.
      // #62: also counted, so the probe can tell "bridge answered with only
      // its 0x30" (dormant) from "nothing at all".
      onAtStatusByte: (b) {
        atStatusCount++;
        lastAtStatusMs = now().millisecondsSinceEpoch;
        RawLogger.instance.logAtStatus(state.serial ?? '', b);
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
    // #55: the state field is ALWAYS updated — a row must never report a
    // connection state it is not in. (The L11 "closed controller" guard used
    // to return before this line, so a row (re)connected after dispose()
    // streamed telemetry while still reporting `disconnected`, i.e. controls
    // "unavailable: Not connected" on a live pack.) Only the stream add is
    // skipped once the controller is closed.
    final prev = connState;
    connState = s;
    _noteGateAvailability();
    if (_conn.isClosed) return;
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
      _connectedAtMs = now().millisecondsSinceEpoch; // #59
      lastFrameMs = null;
      lastTelemetryMs = null;
      // #61 / #62 / #53: per-link counters and the probe result start over.
      frameCount = 0;
      streamClass = StreamClass.unknown;
      lastProbeMs = null;
      _cycleSeen.clear();
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
  /// null if none has been decoded yet. Reset on every (re)connect. Set from
  /// the parser's event hook the moment the frame is DECODED — independent of
  /// any UI rebuild timing (#55).
  int? lastGateStatusMs;

  /// A persistent gate toggle (charge / output switch, passive balancing,
  /// heater, …) is only
  /// allowed while the gate base is younger than this. #55: was 5 s, which
  /// re-locked the controls on every short stall of a weak link (JS-2C14B8 at
  /// −90 dBm stalled ≥ 5 s nine times and re-handshook 82 times in one
  /// session). BAL_STATUS streams about once a second, so 15 s still
  /// guarantees a recent base.
  static const int gateFreshnessMs = 15000;

  /// C1: true iff we are connected, EVERY one of the six persistent gates has
  /// been reported (chargeMos, dischargeMos, tempControlGate, smokeGate,
  /// heatGate, passiveBalancing), AND the last BAL_STATUS is younger than
  /// [gateFreshnessMs]. Anything else and a gate write would be built from a
  /// stale/unknown base — which could cut output or disable protection.
  ///
  /// The six gates all come from the ONE BAL_STATUS frame (A8 AC), so a single
  /// decoded frame on this link reports every field the gate-control frame
  /// writes; nothing this firmware does not report is ever waited for.
  bool get hasFreshGateState => gateControlsDisabledReason == null;

  /// Milliseconds since the last decoded BAL_STATUS on this link, or null when
  /// none has been decoded yet. Shown on the controls note and in Diagnostics
  /// so a refused control is explainable on the phone (#55).
  int? get gateStatusAgeMs {
    final last = lastGateStatusMs;
    return last == null ? null : now().millisecondsSinceEpoch - last;
  }

  /// The gate base known on this link (all six gates from the last decoded
  /// BAL_STATUS), or null when none has been decoded yet.
  GateSnapshot? get gateBase =>
      lastGateStatusMs == null ? null : GateSnapshot.fromState(state);

  /// Reason text: not connected.
  static const reasonNotConnected = 'Not connected';

  /// Reason text: connected, but no BAL_STATUS decoded on this link yet.
  static const reasonNoGateStatus =
      'Waiting for gate status from the battery (none received on this '
      'connection yet)';

  /// Reason text for a base older than [gateFreshnessMs].
  static String reasonGateStatusStale(int ageMs) =>
      'No gate status from the battery for ${(ageMs / 1000).round()} s '
      '(needs one within ${gateFreshnessMs ~/ 1000} s)';

  /// #59: a connected link with no decoded telemetry frame for this long is
  /// reported as "not streaming" instead of "waiting for gate status", and
  /// (#62) the AT+V probe classifies why — see [watchdogTick].
  static const int notStreamingMs = 10000;

  /// Reason text for a connected link that has gone silent (#59), refined by
  /// the #62 probe result [cls]. Always starts with "Connected but not
  /// streaming" (Diagnostics keys on that prefix). Never says "asleep": the
  /// BMS's standby flag is a stored setting, not a state we can observe.
  /// #63: dormant and no-response both read "BMS not running", the finer
  /// verdict follows as the detail.
  static String reasonNotStreaming(int silenceMs,
      [StreamClass cls = StreamClass.unknown]) {
    final silent = 'no telemetry for ${(silenceMs / 1000).round()} s';
    return switch (cls) {
      StreamClass.dormant || StreamClass.noResponse =>
        'Connected but not streaming — $bmsNotRunningState: '
            '${probeDetail(cls)}, $silent',
      StreamClass.awakeNotStreaming =>
        'Connected but not streaming — $awakeNotStreamingState ($silent)',
      _ => 'Connected but not streaming — $silent (checking whether the '
          'BMS is in Bluetooth standby)',
    };
  }

  /// Epoch-ms of the last decoded frame of ANY kind on this link, or null.
  int? lastFrameMs;

  /// Epoch-ms of the last decoded TELEMETRY frame on this link (the cyclic
  /// stream — not a version frame or an ack, #62), or null. Silence and the
  /// live indicator (#61) are measured from this.
  int? lastTelemetryMs;
  int? _connectedAtMs;

  /// Milliseconds since the last decoded telemetry frame on this link (or
  /// since the link came up, if none yet); null while not connected.
  int? get silenceMs {
    if (connState != ConnState.connected) return null;
    final since = lastTelemetryMs ?? _connectedAtMs;
    return since == null ? null : now().millisecondsSinceEpoch - since;
  }

  /// True while connected but silent for at least [notStreamingMs] (#59).
  bool get notStreaming => (silenceMs ?? 0) >= notStreamingMs;

  /// #65: true while telemetry is actually flowing on this link — connected,
  /// at least one telemetry frame decoded and not yet [notStreaming]. Only
  /// streaming packs contribute to the fleet's live net current / power and
  /// its "Status"; a silent pack's last state is stale, not data.
  bool get isStreaming =>
      connState == ConnState.connected &&
      lastTelemetryMs != null &&
      !notStreaming;

  /// Why gate writes that CAN TURN SOMETHING OFF (charge / output / both OFF,
  /// passive balancing / heater OFF, factory reset — anything built from the live gate
  /// base) are refused right now, or null when they are allowed. The text
  /// never implies a user approval step: every reason clears by itself once
  /// the battery is connected and reporting.
  String? get gateControlsDisabledReason {
    if (connState != ConnState.connected) return reasonNotConnected;
    if (notStreaming) return reasonNotStreaming(silenceMs!, streamClass);
    if (gateBase == null) return reasonNoGateStatus;
    final ageMs = gateStatusAgeMs!;
    if (ageMs >= gateFreshnessMs) return reasonGateStatusStale(ageMs);
    return null;
  }

  /// #59: why the SAFE writes — Charge ON, Output ON, Both ON and Restart —
  /// are refused, or null. A write that cannot turn anything off is never
  /// blocked on a connected battery: JS-2C14AA had its output OFF, the
  /// fresh-status gate refused "Output ON", and the pack idled into sleep
  /// unreachable. See [safeWriteBase] for the frame such a write carries
  /// without a fresh base.
  String? get safeWritesDisabledReason =>
      connState != ConnState.connected ? reasonNotConnected : null;

  /// #59 / #58: true for the writes that cannot turn anything off: a MOS
  /// switch ON (Charge ON, Output ON, Both ON) and Restart. NOT passive /
  /// heater ON: without a fresh base their frame would also have to force
  /// the MOS bytes to 1, silently turning a switch on as a side effect, so
  /// they keep the fresh-status gate.
  static bool isSafeWrite(GateAction action, {required bool on}) =>
      (isMosAction(action) && on) || action == GateAction.restart;

  /// The applicable refusal reason for [action] / [on] (null = allowed).
  String? disabledReasonFor(GateAction action, {bool on = true}) =>
      isSafeWrite(action, on: on)
          ? safeWritesDisabledReason
          : gateControlsDisabledReason;

  /// The last decoded gate values on this ROW, from any link and of any age
  /// (the state object survives reconnects; only [lastGateStatusMs] resets).
  GateSnapshot? get lastKnownGates => GateSnapshot.fromState(state);

  /// #59 / #58: the base a SAFE write is built from when there is no fresh
  /// status. The MOS bytes:
  ///
  ///  * Charge ON forces ONLY byte[0] to 1; Output ON forces ONLY byte[1].
  ///    The OTHER switch keeps its last-known value on this row (any link,
  ///    any age) — it is never silently switched on. Only when that switch
  ///    has NEVER been reported (no status on any link) is it written as 1,
  ///    the one direction that cannot cut anything; the confirmation says so.
  ///  * Both ON and Restart force both MOS bytes to 1 (the #59 rule).
  ///
  /// The other gates come from [lastKnownGates] and, for a row that has never
  /// decoded a status, protective defaults: tempControlGate = 1 (low-temp
  /// protection ON is the safe direction; 0 would switch it off), smokeGate =
  /// 0 and heatGate = 0, passiveBalancing = 0 (what every observed pack
  /// reports at rest). The momentary flags are 0 unless the action sets one.
  GateSnapshot safeWriteBase(GateAction action) {
    final known = lastKnownGates;
    final forceBoth =
        action == GateAction.restart || action == GateAction.bothMos;
    return GateSnapshot(
      chargeMos: forceBoth ||
          action == GateAction.chargeMos ||
          (state.chargeMos ?? true),
      dischargeMos: forceBoth ||
          action == GateAction.dischargeMos ||
          (state.dischargeMos ?? true),
      tempControlGate: known?.tempControlGate ?? 1,
      smokeGate: known?.smokeGate ?? 0,
      heatGate: known?.heatGate ?? 0,
      passiveBalancing: known?.passiveBalancing ?? false,
    );
  }

  /// #58: what a safe write's frame carries for the MOS bytes without a fresh
  /// status, in words for the confirmation and Diagnostics — e.g.
  /// "output ON (discharge MOS byte = 1); the charge switch keeps its
  /// last-known value (ON)".
  String safeWriteMosText(GateAction action) {
    if (action == GateAction.restart || action == GateAction.bothMos) {
      return 'charge and output ON (both MOS bytes = 1)';
    }
    final charge = action == GateAction.chargeMos;
    final own = charge
        ? 'charge ON (charge MOS byte = 1)'
        : 'output ON (discharge MOS byte = 1)';
    final other = charge ? 'output' : 'charge';
    final otherKnown = charge ? state.dischargeMos : state.chargeMos;
    if (otherKnown == null) {
      return '$own and, with no $other state ever received from this '
          'battery, $other ON too';
    }
    return '$own; the $other switch keeps its last-known value '
        '(${otherKnown ? 'ON' : 'OFF'})';
  }

  /// One line for Diagnostics: connection state, streaming state, gate-status
  /// age and whether controls are available (with the reason when not).
  String gateStatusSummary() {
    final serial = state.serial ?? 'unknown serial';
    final age = gateStatusAgeMs;
    final ageText =
        age == null ? 'no gate status yet' : 'gate status ${_fmtAge(age)} ago';
    final silence = silenceMs;
    final stream = connState != ConnState.connected
        ? ''
        : notStreaming
            ? ' · NOT streaming (${_fmtAge(silence!)} silent)'
            : ' · streaming';
    final reason = gateControlsDisabledReason;
    final avail = reason == null
        ? 'controls available'
        : 'controls unavailable: $reason'
            '${safeWritesDisabledReason == null ? ' (Charge ON / Output ON / Restart still available)' : ''}';
    // #61: frame counter + last-frame age; #62: the probe's verdict.
    final frames = connState != ConnState.connected
        ? ''
        : ' · frames $frameCount'
            ' · last frame ${lastTelemetryMs == null ? 'none' : '${_fmtAge(silence!)} ago'}'
            '${streamClass == StreamClass.unknown ? '' : ' · stream ${streamClass.name}'}';
    return '$serial: ${connState.name}$stream$frames · $ageText · $avail';
  }

  static String _fmtAge(int ms) => ms < 10000
      ? '${(ms / 1000).toStringAsFixed(1)} s'
      : '${(ms / 1000).round()} s';

  /// #55: the availability kind last written to Diagnostics (null = never).
  String? _loggedGateKind;

  /// #55: record EVERY change of control availability in Diagnostics with the
  /// raw inputs — connection state, gate-status age, and the six gate fields —
  /// so an "unavailable" seen on the phone is explainable after the fact.
  /// Called on every decoded BAL_STATUS and every connection-state change;
  /// only a change of kind (available / not connected / no status / stale)
  /// writes a line, so a healthy stream logs once.
  void _noteGateAvailability() {
    final r = gateControlsDisabledReason;
    final kind = r == null
        ? 'available'
        : r == reasonNotConnected
            ? 'not connected'
            : r == reasonNoGateStatus
                ? 'no status'
                : r.startsWith('Connected but not streaming')
                    ? 'not streaming'
                    : 'stale';
    if (kind == _loggedGateKind) return;
    _loggedGateKind = kind;
    final s = state;
    final age = gateStatusAgeMs;
    AppLog.instance.record(
        _source,
        '${s.serial ?? '?'} controls ${r == null ? 'available' : 'unavailable: $r'}'
        ' · conn=${connState.name}'
        ' · gate status ${age == null ? 'none' : '$age ms ago'}'
        ' · chg=${s.chargeMos} dis=${s.dischargeMos} temp=${s.tempControlGate}'
        ' smoke=${s.smokeGate} heat=${s.heatGate} bal=${s.passiveBalancing}');
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

  /// #53: the widest gap the session integrator bridges. 10 s while
  /// continuous; the manager raises it to (interval + margin) in background
  /// sampling mode so sparse samples are held to the next one.
  int maxIntegrateGapMs = 10000;

  /// Integrate |signedCurrent| over the time since the last event. Long gaps
  /// (disconnects) are skipped so offline windows do not accrue throughput.
  void _integrateThroughput(int nowMs) {
    final last = _lastEfcMs;
    _lastEfcMs = nowMs;
    if (last == null) return;
    final dtMs = nowMs - last;
    if (dtMs <= 0 || dtMs > maxIntegrateGapMs) return; // <=0 and offline gaps
    cumulativeThroughputAh += signedCurrent.abs() * (dtMs / 3600000.0);
  }

  BleLink? _link;
  StreamSubscription<BleLinkState>? _stateSub;

  /// Connect to [deviceId], discover + subscribe, run the handshake. The whole
  /// sequence is bounded by [connectTimeout] (L15); a timeout is just another
  /// failed connect. Throws on any failure after marking the row disconnected.
  Future<String> connectTo(String deviceId, {String? name}) async {
    // #55: a disposed row (replaced by startLive / startDemoFleet / un-star)
    // must never be re-linked — it would hold the pack's GATT link invisibly.
    if (_disposed) {
      throw StateError('connection for ${state.serial ?? deviceId} is disposed');
    }
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
      // #55: a dispose() that landed during the awaits above must not open a
      // link on this dead row (the catch below marks it disconnected).
      if (_disposed) {
        throw StateError('connection for ${state.serial ?? deviceId} was '
            'disposed while connecting');
      }
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
    if (gen != _connectGen || _disposed) {
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
    // #60: from here on a stray 0x30 on this link is AT+V's status byte '0'.
    // Flagged before the write so a fast reply cannot race the flag.
    parser.atVersionSent = true;
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
    // #41: while a firmware update runs, ONLY the session's own frames
    // (labelled "OTA: …") go out — any other write could corrupt the flash.
    final ota = OtaLock.refuseReason;
    if (ota != null && !label.startsWith('OTA:')) {
      AppLog.instance.record(_source, 'refused "$label": $ota');
      throw StateError('$ota ($label was not sent)');
    }
    // Issue #19: also record every command we send to the raw log (TX line).
    RawLogger.instance.logTx(state.serial ?? '', label, bytes);
    await link.write(bytes);
  }

  // --- #41 firmware update (OTA) -------------------------------------------

  /// The running firmware-update session on this row, or null.
  OtaSession? otaSession;

  /// True while a firmware update is in flight on THIS battery.
  bool get otaInProgress => otaSession?.inProgress ?? false;

  /// #41: the negotiated ATT MTU of the live link (null: unknown / demo).
  int? get linkMtu => _link?.mtu;

  /// #41: flash [image] to this battery. The caller MUST have run
  /// [otaPreflight] and the typed confirmation first — this method only
  /// refuses the mechanical impossibilities (not connected, another update
  /// running, demo). For the transfer it: marks the parser OTA-active so the
  /// three reply frames decode, takes the app-wide [OtaLock] (every other
  /// write, Pause / Exit, background sampling and the not-streaming probe
  /// are refused meanwhile), fails the session on a link drop, and logs
  /// every step to Diagnostics + the raw log. The session's own frames are
  /// the ONLY writes that pass [_send] while it runs.
  Future<OtaResult> runFirmwareUpdate(
    OtaImage image, {
    Duration resendTimeout = OtaProtocol.resendTimeout,
    Duration recallTimeout = OtaProtocol.recallTimeout,
    Duration finishDelay = OtaProtocol.finishDelay,
    Duration endDelay = OtaProtocol.endDelay,
  }) async {
    if (connState != ConnState.connected) {
      throw StateError('Not connected — firmware update not started');
    }
    if (OtaLock.inProgress) {
      throw StateError(OtaLock.refuseReason!);
    }
    if (_demo != null) {
      throw StateError('Firmware update is not available on a demo battery');
    }
    final serial = state.serial ?? '?';
    final mtu = OtaProtocol.effectiveMtu(linkMtu);
    final session = OtaSession(
      image: image,
      mtu: mtu,
      serial: serial,
      send: (bytes, label) => _send(bytes, label: label),
      replies: events,
      resendTimeout: resendTimeout,
      recallTimeout: recallTimeout,
      finishDelay: finishDelay,
      endDelay: endDelay,
      log: (line) {
        AppLog.instance.record('OTA $serial', line);
        RawLogger.instance.logEvent(serial, 'OTA', line);
      },
    );
    otaSession = session;
    OtaLock.active = session;
    parser.otaActive = true;
    AppLog.instance.record(
        _source,
        '#41 firmware update starting on $serial: link mtu '
        '${linkMtu ?? 'unknown'} -> effective $mtu');
    final dropSub = connection.listen((s) {
      if (s != ConnState.connected) session.linkLost('link state ${s.name}');
    });
    try {
      return await session.run();
    } finally {
      await dropSub.cancel();
      parser.otaActive = false;
      if (OtaLock.active == session) OtaLock.active = null;
      AppLog.instance.record(
          _source,
          '#41 firmware update on $serial ended: ${session.stage.name}'
          '${session.progress.detail.isEmpty ? '' : ' — ${session.progress.detail}'}');
    }
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

  /// #42 / #62: the STORED "Bluetooth standby (power saving)" setting as the
  /// last SLEEP_SET_SUCCESS ack reported it. A setting, never "asleep now":
  /// the pack keeps streaming while a central is connected.
  bool get isSleepModeOn => state.sleepModeOn ?? false;

  /// #38: the pack's current rated / full capacity in Ah (from SOC frames), the
  /// basis the UI shows before a capacity write and validates the read-back against.
  double? get ratedCapacityAh => state.fullAh;

  /// #58: the "Charge" switch (charge MOS, gate byte[0]) as last reported.
  bool get isChargeOn => state.chargeMos ?? false;

  /// #58: the "Output" switch (discharge MOS, gate byte[1]) as last reported.
  /// (Until #58 this was the single "Output" state = both switches on.)
  bool get isOutputOn => state.dischargeMos ?? false;

  /// #58: both switches on (what the MOS_STATUS frame's `mosOn` also reports).
  bool get areBothOn => isChargeOn && isOutputOn;

  /// The reported state of the switch [action] drives (null = not reported).
  /// [GateAction.bothMos] is on iff both are on.
  bool? mosState(GateAction action) => switch (action) {
        GateAction.chargeMos => state.chargeMos,
        GateAction.dischargeMos => state.dischargeMos,
        GateAction.bothMos =>
          state.chargeMos == null || state.dischargeMos == null
              ? null
              : areBothOn,
        _ => null,
      };

  /// Read-back for a MOS switch write (issue #24 / #58). After sending a
  /// Charge / Output / Both command, watch the streamed BAL_STATUS frames and
  /// complete `true` as soon as the pack reports THAT switch at [expectedOn]
  /// (for [GateAction.bothMos]: both bytes), or `false` if it has not within
  /// [timeout] (e.g. you sent "output OFF" but disMos is still 1). Lets the UI
  /// warn the user that the command did not take effect on the hardware.
  Future<bool> confirmMosState(
    GateAction action,
    bool expectedOn, {
    Duration timeout = const Duration(seconds: 4),
  }) {
    // Only a fresh BAL_STATUS frame confirms the change: wait for the next one
    // (or any event that arrives with the state already reflecting the target).
    bool matches() => switch (action) {
          GateAction.chargeMos => state.chargeMos == expectedOn,
          GateAction.dischargeMos => state.dischargeMos == expectedOn,
          _ => state.chargeMos == expectedOn &&
              state.dischargeMos == expectedOn,
        };
    return _confirmVia(matches, timeout);
  }

  /// Build a gate-control frame from the LIVE gate state and send it on FCF1.
  /// Only the [action] byte changes; every other gate keeps its current value
  /// (read from the last BAL_STATUS frame). Restart/factory ignore [on].
  ///
  /// SAFETY (audit C1 / #59 / #58): with a FRESH base
  /// ([gateControlsDisabledReason] null — connected, streaming, all six gates
  /// from a BAL_STATUS within [gateFreshnessMs]) every action is built from
  /// the live gates. Without one, only a SAFE write ([isSafeWrite]: Charge
  /// ON, Output ON, Both ON, Restart) goes out, on any connected link, built
  /// from [safeWriteBase] (its own MOS byte = 1, the other at its last-known
  /// value, so it can cut nothing). Everything else — any write that turns a
  /// switch OFF — is REFUSED with a [StateError]: a frame built from a stale
  /// or unknown base could write chargeMos = dischargeMos = 0 (cutting
  /// output / stopping charge) or tempControlGate = 0 (disabling
  /// protection). A refusal, and a safe write sent without a fresh base, are
  /// recorded in Diagnostics.
  Future<void> sendGateControl(GateAction action, {bool on = true}) async {
    final GateSnapshot base;
    final freshReason = gateControlsDisabledReason;
    if (freshReason == null && gateBase != null) {
      base = gateBase!;
    } else if (isSafeWrite(action, on: on) &&
        safeWritesDisabledReason == null) {
      base = safeWriteBase(action);
      AppLog.instance.record(
          _source,
          'safe write ${mosSwitchName(action)} on ${state.serial ?? '?'} sent '
          'without a fresh gate status ($freshReason): '
          '${safeWriteMosText(action)}, other gates '
          '${lastKnownGates == null ? 'defaults' : 'last known'}');
    } else {
      throw _refusal(action, on: on);
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
    await _send(frame, label: 'gate control ${mosSwitchName(action)} ${on ? 'on' : 'off'}');
  }

  /// The recorded [StateError] for a refused gate write (C1).
  StateError _refusal(GateAction action, {required bool on}) {
    final why = disabledReasonFor(action, on: on) ?? 'gate state unknown';
    AppLog.instance.record(_source,
        'refused gate write ${mosSwitchName(action)} on ${state.serial ?? '?'}: $why');
    return StateError('Refusing gate write ${mosSwitchName(action)}: '
        '$why — a write built from a stale or '
        'unknown gate base could cut output, stop charging or disable '
        'protection.');
  }

  // --- #62 standby-off before a switch-off (SAFETY-CRITICAL) ---------------
  // Live incident: a pack whose output was turned OFF while its Bluetooth
  // standby ("sleep") mode was ON went DORMANT and unwakeable — with both MOS
  // off no current can flow through it (in a parallel bank the sibling takes
  // every amp), and this firmware wakes only on current; the BLE bridge cannot
  // wake the MCU. So EVERY switch-off (Charge / Output / Both, per battery or
  // fleet) turns standby OFF first when it is ON or unknown.

  /// How long a switch-off waits for the standby-OFF ack (AC CA) before
  /// sending the gate frame anyway.
  static const Duration standbyAckTimeout = Duration(seconds: 3);

  /// #62: true when a switch-off must turn Bluetooth standby OFF first —
  /// standby is reported ON, or has never been reported on this row.
  bool get needsStandbyOffFirst => state.sleepModeOn != false;

  /// #62: turn the MOS switch [action] OFF safely. Order:
  ///  1. the C1 pre-check — a switch-off that would be refused sends NOTHING
  ///     (not even the standby-off);
  ///  2. when [needsStandbyOffFirst]: CMD_CLOSE_SLEEP_CONTROL
  ///     (AA CC 01 01 DD EE), then wait for the AC CA ack or
  ///     [standbyAckTimeout];
  ///  3. the gate frame that flips ONLY that switch ([sendGateControl]).
  Future<void> turnSwitchOff(GateAction action) async {
    if (!isMosAction(action)) {
      throw ArgumentError.value(action, 'action', 'not a MOS switch');
    }
    if (disabledReasonFor(action, on: false) != null) {
      throw _refusal(action, on: false);
    }
    if (needsStandbyOffFirst) {
      final serial = state.serial ?? '?';
      final was = state.sleepModeOn == null ? 'unknown' : 'ON';
      AppLog.instance.record(
          _source,
          '#62 Bluetooth standby $was on $serial: turning standby OFF before '
          '${mosSwitchName(action)} OFF');
      await setSleepMode(false);
      final acked =
          await confirmSleepState(false, timeout: standbyAckTimeout);
      AppLog.instance.record(
          _source,
          acked
              ? 'standby OFF acked by $serial'
              : 'no standby-OFF ack from $serial within '
                  '${standbyAckTimeout.inSeconds} s — sending '
                  '${mosSwitchName(action)} OFF anyway');
    }
    await sendGateControl(action, on: false);
  }

  // --- #62 dormant-BMS classification + recovery ladder --------------------
  // Verified live: a pack whose BMS MCU is not running still connects, answers
  // AT+V with ONLY the bridge's 0x30 status byte and ignores every framed
  // command. A pack whose BMS is awake answers AT+V with '0' + the AC 9A
  // version frame; if it is merely not streaming, CMD_BEGIN restarts the
  // stream. The ladder below is USER-initiated (never silent, #62 item 5).

  /// How long the AT+V probe waits for an answer (injectable for tests).
  final Duration probeWindow;
  static const Duration defaultProbeWindow = Duration(milliseconds: 1500);

  /// A silent link is re-probed no more often than this while it stays silent.
  static const int probeRepeatMs = 30000;

  /// How long a ladder step waits for the stream to resume.
  static const Duration resumeTimeout = Duration(seconds: 5);

  /// What the last probe found on this link (reset on connect; any telemetry
  /// frame flips it to [StreamClass.streaming]).
  StreamClass streamClass = StreamClass.unknown;

  /// Epoch-ms the last probe started on this link, or null.
  int? lastProbeMs;

  /// #61: frames decoded on THIS link (reset on connect) / on this row ever.
  int frameCount = 0;
  int totalFrameCount = 0;

  /// Epoch-ms of the last decoded frame on ANY link of this row (never reset)
  /// — the "sampled … ago" age in background sampling mode (#53).
  int? lastFrameEverMs;

  /// Epoch-ms of the last AC 9A version frame / the last bridge 0x30 status
  /// byte on this row, and how many 0x30s have been seen (#62 probe).
  int? lastVersionFrameMs;
  int? lastAtStatusMs;
  int atStatusCount = 0;

  Completer<StreamClass>? _probe;

  /// True while an AT+V probe is running.
  bool get probeInFlight => _probe != null;

  // #62 / #63 texts (pinned by tests). The headline for a pack whose BMS is
  // not running is the same whether or not the bridge's intermittent 0x30
  // arrived; the finer verdict is a detail.
  static const String bmsNotRunningState = 'BMS not running';
  static const String dormantDetail = 'bridge answered (0x30)';
  static const String noResponseState = 'no reply to AT+V';
  static const String awakeNotStreamingState = 'BMS awake, not streaming';

  /// #63: connected, silent, and the probe got neither a version frame nor
  /// telemetry — with ([StreamClass.dormant]) or without
  /// ([StreamClass.noResponse]) the bridge's 0x30. Every user-facing branch
  /// that shows the dormant guidance keys on this, not on `dormant` alone.
  bool get bmsNotRunning =>
      streamClass == StreamClass.dormant ||
      streamClass == StreamClass.noResponse;

  /// The finer probe verdict as a short detail ("bridge answered (0x30)" vs
  /// "no reply to AT+V"), for the secondary line under the headline.
  static String probeDetail(StreamClass cls) => switch (cls) {
        StreamClass.dormant => dormantDetail,
        StreamClass.noResponse => noResponseState,
        StreamClass.awakeNotStreaming => 'version frame received',
        _ => cls.name,
      };

  /// What to tell the user about a pack whose BMS is not running. Recovery
  /// is physical.
  static const String dormantMessage =
      'BMS is not running — it entered Bluetooth standby with its output off '
      'and cannot be woken over Bluetooth. Isolate this pack from the bank '
      'and connect a charger to it alone, or use its reset button.';

  /// Telemetry = the cyclic frames (voltage, temperature, all-data, MOS,
  /// balancer, SOC, estimate, alarms, other). Acks and the version frame are
  /// answers to commands, not the stream.
  static bool isTelemetryEvent(BatteryEvent e) =>
      e is! VersionEvent &&
      e is! SleepEvent &&
      e is! SettingRespondEvent &&
      e is! GateSetEvent &&
      !isOtaEvent(e); // #41: OTA replies answer the session, not the stream

  /// The not-streaming watchdog, driven by the UI tick (~300 ms): a link
  /// that is connected, silent for [notStreamingMs] and not probed in the
  /// last [probeRepeatMs] gets an AT+V probe. Cheap when nothing is due.
  void watchdogTick() {
    if (connState != ConnState.connected || !notStreaming || _probe != null) {
      return;
    }
    // #41: the probe is a write (AT+V) — never during a firmware update.
    if (OtaLock.inProgress) return;
    final nowMs = now().millisecondsSinceEpoch;
    final last = lastProbeMs;
    if (last != null && nowMs - last < probeRepeatMs) return;
    unawaited(probeStreaming());
  }

  /// The AT+V classification. Sends AT+V and, within [probeWindow]:
  ///  * a telemetry frame            -> [StreamClass.streaming];
  ///  * a version frame, no stream   -> [StreamClass.awakeNotStreaming] and
  ///    CMD_BEGIN is re-sent;
  ///  * only the bridge's 0x30       -> [StreamClass.dormant];
  ///  * nothing                      -> [StreamClass.noResponse].
  /// Deduped: a probe already running returns its result.
  Future<StreamClass> probeStreaming() {
    final running = _probe;
    if (running != null) return running.future;
    if (connState != ConnState.connected) {
      return Future.value(StreamClass.unknown);
    }
    final c = Completer<StreamClass>();
    _probe = c;
    lastProbeMs = now().millisecondsSinceEpoch;
    unawaited(_runProbe(c));
    return c.future;
  }

  Future<void> _runProbe(Completer<StreamClass> c) async {
    final serial = state.serial ?? '?';
    final atBefore = atStatusCount;
    var sawVersion = false, sawTelemetry = false;
    final answered = Completer<void>();
    final sub = events.listen((e) {
      if (e is VersionEvent) {
        sawVersion = true;
      } else if (isTelemetryEvent(e)) {
        sawTelemetry = true;
      }
      if ((sawVersion || sawTelemetry) && !answered.isCompleted) {
        answered.complete();
      }
    });
    StreamClass result;
    try {
      parser.atVersionSent = true; // #60: its '0' is a status byte
      await _send(BatteryCommands.getVersion, label: 'AT+V probe (#62)');
      await answered.future.timeout(probeWindow, onTimeout: () {});
      if (sawTelemetry) {
        result = StreamClass.streaming;
      } else if (sawVersion) {
        result = StreamClass.awakeNotStreaming;
        await _send(BatteryCommands.begin,
            label: 're-send wake (CMD_BEGIN) after AT+V probe');
      } else if (atStatusCount > atBefore) {
        result = StreamClass.dormant;
      } else {
        result = StreamClass.noResponse;
      }
    } catch (e) {
      AppLog.instance.record(_source, '$serial AT+V probe failed: $e');
      result = StreamClass.unknown;
    } finally {
      await sub.cancel();
    }
    // Telemetry that arrived meanwhile already set `streaming`; never
    // downgrade it.
    if (streamClass != StreamClass.streaming ||
        result == StreamClass.streaming) {
      streamClass = result;
    }
    AppLog.instance.record(
        _source,
        '$serial AT+V probe: ${result.name}'
        ' (version frame ${sawVersion ? 'yes' : 'no'}, status byte '
        '${atStatusCount > atBefore ? 'yes' : 'no'}, telemetry '
        '${sawTelemetry ? 'yes' : 'no'})');
    _probe = null;
    _noteGateAvailability();
    if (!c.isCompleted) c.complete(result);
  }

  /// Completes true as soon as a telemetry frame is decoded (on any link of
  /// this row), false after [timeout].
  Future<bool> awaitStreaming({Duration timeout = resumeTimeout}) {
    final c = Completer<bool>();
    late StreamSubscription<BatteryEvent> sub;
    Timer? timer;
    void finish(bool ok) {
      if (c.isCompleted) return;
      timer?.cancel();
      sub.cancel();
      c.complete(ok);
    }

    sub = events.listen((e) {
      if (isTelemetryEvent(e)) finish(true);
    });
    timer = Timer(timeout, () => finish(false));
    return c.future;
  }

  /// Ladder step (i): re-send CMD_BEGIN (the handshake's start-streaming
  /// command; changes nothing on the pack). True iff the stream resumed
  /// within [timeout]. Throws if the send fails (not connected).
  Future<bool> resendWake({Duration timeout = resumeTimeout}) async {
    final resumed = awaitStreaming(timeout: timeout);
    AppLog.instance.record(
        _source, '#62 ladder: re-send wake (CMD_BEGIN) to ${state.serial}');
    await _send(BatteryCommands.begin, label: 'wake (CMD_BEGIN, #62 ladder)');
    return resumed;
  }

  /// Ladder step (ii): the both-MOS-on frame from [safeWriteBase] (the vendor
  /// app's de-facto wake). A SAFE write — it can cut nothing. True iff the
  /// stream resumed within [timeout].
  Future<bool> switchesOnToWake({Duration timeout = resumeTimeout}) async {
    final resumed = awaitStreaming(timeout: timeout);
    AppLog.instance.record(
        _source, '#62 ladder: both switches ON to ${state.serial}');
    await sendGateControl(GateAction.bothMos, on: true);
    return resumed;
  }

  // --- #53 one full telemetry cycle (background sample) --------------------

  /// The frame types one ~1 Hz cycle carries; a sample is complete once each
  /// has been decoded on this link.
  static const Set<Type> requiredCycleTypes = {
    VoltageEvent,
    TempEvent,
    AllDataEvent,
    MosEvent,
    BalancerEvent,
    SocEvent,
  };
  final Set<Type> _cycleSeen = {};

  /// True once every [requiredCycleTypes] frame has been decoded on this link.
  bool get cycleComplete => requiredCycleTypes.every(_cycleSeen.contains);

  /// Completes true once [cycleComplete], false after [timeout].
  Future<bool> awaitFullCycle(
      {Duration timeout = const Duration(seconds: 12)}) {
    if (cycleComplete) return Future.value(true);
    return _confirmVia(() => cycleComplete, timeout);
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

  /// Set by [dispose]; a disposed row refuses [connectTo].
  bool _disposed = false;

  Future<void> dispose() async {
    _disposed = true;
    // #55: abandon a connect sequence still in flight — it sees a different
    // generation and drops its late link instead of binding it to this row.
    _connectGen++;
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
      OtaRecallEvent() => 'BMS entered update mode (FF 01 B1 02 EF)',
      OtaAckEvent(:final chunk, :final status, :final checksum) =>
        'chunk=$chunk status=0x${status.toRadixString(16)} '
            'sum=0x${checksum.toRadixString(16)}',
      OtaSuccessEvent() => 'BMS accepted the image (AA BB 01 02 EF)',
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
