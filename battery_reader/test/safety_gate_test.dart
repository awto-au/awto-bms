import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';

import 'fakes.dart';

/// Review-fix Pass A (GitHub #51 + #50), connection-level behaviour:
///
///  * C1 — a gate write is REFUSED (StateError, nothing sent) unless the gate
///    base is fresh: connected, all six gates known, BAL_STATUS < 5 s old.
///  * H3 — the disconnect alarm fires ONLY on a true connected -> disconnected
///    transition, never on a failed retry, and never on a user-initiated
///    disconnect / Restart BMS.
///  * M1 — temp-alarm byte[2] (latched over-temp) is a warning, its restart-
///    induced 1 -> 0 is NOT a MAJOR unknown-byte alarm, and acknowledgeAlarms
///    clears the sticky alarm state.
///
/// Hermetic: a fake transport records every write; a fake clock drives the
/// freshness rule.
void main() {
  // --- frames -------------------------------------------------------------
  // BAL_STATUS (A8 AC): [chargeState, chgMos, disMos, passive, tempGate,
  // smoke, heat] + end B9 21.
  List<int> bal({
    int chgMos = 1,
    int disMos = 1,
    int passive = 0,
    int tempGate = 1,
    int smoke = 0,
    int heat = 0,
  }) =>
      [0xA8, 0xAC, 0x01, chgMos, disMos, passive, tempGate, smoke, heat, 0xB9, 0x21];

  // Temperature alarm (A6 C0): 7 data bytes; [2] = latched over-temp.
  List<int> tempAlarm({int latched = 0, int b3 = 0, int b6 = 0}) =>
      [0xA6, 0xC0, 0, 0, latched, b3, 0, 0, b6, 0xB7, 0x72];

  List<int> payload(List<int> frame) => frame.sublist(2, frame.length - 2);

  // A cell-voltage frame (A0 C1): telemetry that is not a BAL_STATUS.
  const cells = [
    0xA0, 0xC1, 0x04, 0x05, 0x0d, 0x08, 0x0d, 0x07, 0x0d, 0x05, 0x0d, 0xB1, 0xD2
  ];

  group('C1: gate write is refused without a fresh BAL_STATUS', () {
    test('not connected -> refused, nothing written', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      expect(c.hasFreshGateState, isFalse);
      expect(c.gateControlsDisabledReason, contains('Not connected'));
      await expectLater(
          c.sendGateControl(GateAction.passiveBalance, on: true),
          throwsA(isA<StateError>()));
      expect(t.writes, isEmpty);
    });

    test('connected but no BAL_STATUS decoded yet -> refused (the C1 case)',
        () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      expect(c.connState, ConnState.connected);
      expect(c.hasFreshGateState, isFalse);
      expect(c.gateControlsDisabledReason, contains('Waiting for gate status'));
      final before = t.writes.length; // handshake frames only
      // Before the fix this sent C3 1E 00 00 00 00 00 00 01 00 D4 3B —
      // chargeMos = dischargeMos = 0 — cutting the pack's output.
      await expectLater(
          c.sendGateControl(GateAction.passiveBalance, on: true),
          throwsA(isA<StateError>()));
      await expectLater(c.sendGateControl(GateAction.heatGate, on: true),
          throwsA(isA<StateError>()));
      await expectLater(c.sendGateControl(GateAction.output, on: false),
          throwsA(isA<StateError>()));
      expect(t.writes.length, before, reason: 'no gate frame was written');
      expect(t.gateWrites, isEmpty);
      // #59: restart is a SAFE write — it goes out on the safe base (both MOS
      // = 1, never the zero-filled base above).
      await c.sendGateControl(GateAction.restart);
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 1, 0, 0]);
    });

    test('after a BAL_STATUS the write is allowed and built from LIVE gates',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 1, disMos: 1, passive: 0, tempGate: 1));
      expect(c.lastGateStatusMs, clock.millisecondsSinceEpoch);
      expect(c.hasFreshGateState, isTrue);
      expect(c.gateControlsDisabledReason, isNull);

      await c.sendGateControl(GateAction.passiveBalance, on: true);
      expect(t.gateWrites.length, 1);
      // chgMos[0]=1, disMos[1]=1 KEPT from the live base; passive[6] -> 1.
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 0, 1, 0]);
    });

    test('a BAL_STATUS older than 15 s (#55) is stale -> toggle refused',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal());
      expect(c.hasFreshGateState, isTrue);
      clock = clock.add(const Duration(milliseconds: 14999));
      // Other telemetry keeps flowing (else the #59 "not streaming" watchdog
      // reports first, at 10 s); only the BAL_STATUS is stalled.
      c.parser.addBytes(cells);
      expect(c.hasFreshGateState, isTrue);
      clock = clock.add(const Duration(milliseconds: 2));
      expect(c.hasFreshGateState, isFalse);
      expect(c.gateControlsDisabledReason, contains('No gate status'));
      await expectLater(c.sendGateControl(GateAction.output, on: false),
          throwsA(isA<StateError>()));
      expect(t.gateWrites, isEmpty);
      // A fresh frame unlocks it again.
      c.parser.addBytes(bal());
      expect(c.hasFreshGateState, isTrue);
    });

    test('a reconnect invalidates the previous link\'s gate base', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal());
      expect(c.hasFreshGateState, isTrue);
      await c.connectTo('dev-1', name: 'JS-A'); // reconnect on the same row
      expect(c.lastGateStatusMs, isNull);
      expect(c.hasFreshGateState, isFalse);
      expect(c.gateControlsDisabledReason, contains('Waiting for gate status'));
    });

    test('fleetSetOutput refuses when ANY member lacks a fresh base — '
        'no partial writes', () async {
      final tA = FakeTransport();
      final tB = FakeTransport();
      final a = BatteryConnection(transport: tA);
      final b = BatteryConnection(transport: tB);
      await a.connectTo('dev-a', name: 'JS-A');
      await b.connectTo('dev-b', name: 'JS-B');
      a.parser.addBytes(bal()); // A is fresh, B is not
      final m = BatteryManager();
      m.batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      expect(m.fleetControlsDisabledReason, isNull,
          reason: 'connectivity-wise the fleet is fine');
      expect(m.fleetGateWriteDisabledReason, contains('JS-B'));
      await expectLater(m.fleetSetOutput(false), throwsA(isA<StateError>()));
      expect(tA.gateWrites, isEmpty, reason: 'A must not be written either');
      expect(tB.gateWrites, isEmpty);

      b.parser.addBytes(bal());
      expect(m.fleetGateWriteDisabledReason, isNull);
      await m.fleetSetOutput(false);
      expect(tA.gateWrites.length, 1);
      expect(tB.gateWrites.length, 1);
      expect(payload(tA.gateWrites.single).sublist(0, 2), [0, 0]);
    });
  });

  group('H3: disconnect alarm only on a true connected -> disconnected drop',
      () {
    test('a drop from connected alarms (beep + red + reason)', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      expect(c.alarmActive, isFalse);
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.connState, ConnState.disconnected);
      expect(c.alarmActive, isTrue);
      expect(c.consumeBeep(), isTrue);
      expect(c.alarmReasons.last, contains('Disconnected'));
    });

    test('a failed RE-connect attempt (connecting -> disconnected) does NOT '
        'alarm again', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.consumeBeep(), isTrue); // the genuine drop
      final reasonsAfterDrop = c.alarmReasons.length;

      // Every retry at weak signal used to raise the alarm/beep again.
      t.failConnect = true;
      for (var i = 0; i < 3; i++) {
        await expectLater(
            c.connectTo('dev-1', name: 'JS-A'), throwsA(isA<Object>()));
        expect(c.connState, ConnState.disconnected);
      }
      expect(c.consumeBeep(), isFalse, reason: 'no beep on failed retries');
      expect(c.alarmReasons.length, reasonsAfterDrop,
          reason: 'no new "Disconnected" reason per retry');
    });

    test('a first-ever failed connect never alarms', () async {
      final t = FakeTransport()..failConnect = true;
      final c = BatteryConnection(transport: t);
      await expectLater(
          c.connectTo('dev-1', name: 'JS-A'), throwsA(isA<Object>()));
      expect(c.alarmActive, isFalse);
      expect(c.consumeBeep(), isFalse);
    });

    test('a user-initiated Restart BMS drop does not alarm', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal());
      await c.sendGateControl(GateAction.restart);
      expect(c.disconnectExpected, isTrue);
      t.lastLink!.dropLink(); // the pack reboots
      await Future<void>.delayed(Duration.zero);
      expect(c.connState, ConnState.disconnected);
      expect(c.alarmActive, isFalse);
      expect(c.consumeBeep(), isFalse);
      // Reconnecting clears the expectation so a LATER real drop alarms.
      await c.connectTo('dev-1', name: 'JS-A');
      expect(c.disconnectExpected, isFalse);
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.alarmActive, isTrue);
    });

    test('an expected disconnect expires after the window', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.markExpectedDisconnect();
      clock = clock.add(const Duration(seconds: 61));
      expect(c.disconnectExpected, isFalse);
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.alarmActive, isTrue, reason: 'a much later drop still alarms');
    });

    test('user disconnect() does not alarm', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      await c.disconnect();
      expect(c.connState, ConnState.disconnected);
      expect(c.alarmActive, isFalse);
      expect(c.consumeBeep(), isFalse);
    });
  });

  group('M1 / #50: latched over-temp is a warning, not a MAJOR alarm', () {
    test('byte[2]=1 -> overTempLatched + warning state, no alarm', () {
      final c = BatteryConnection(transport: FakeTransport());
      c.parser.addBytes(tempAlarm(latched: 1));
      expect(c.state.overTempLatched, isTrue);
      expect(c.state.faultTemperature, isFalse);
      expect(c.hasGenuineFault, isFalse);
      expect(c.alarmActive, isFalse, reason: 'amber warning, not red alarm');
      expect(c.unknownChangedMetrics, isEmpty);
    });

    test('byte[2] 1 -> 0 (restart cleared it) is NOT an unknown-byte alarm',
        () {
      final c = BatteryConnection(transport: FakeTransport());
      c.parser.addBytes(tempAlarm(latched: 1)); // baseline
      c.parser.addBytes(tempAlarm(latched: 0)); // cleared by the restart
      expect(c.state.overTempLatched, isFalse);
      expect(c.unknownChangedMetrics, isEmpty,
          reason: 'byte[2] is understood; it never enters unknownBytes');
      expect(c.alarmActive, isFalse);
      expect(c.consumeBeep(), isFalse);
    });

    test('bytes [3]/[6] still alert on change, and acknowledgeAlarms clears it',
        () {
      final c = BatteryConnection(transport: FakeTransport());
      c.parser.addBytes(tempAlarm(b3: 1)); // baseline
      c.parser.addBytes(tempAlarm(b3: 0)); // change -> MAJOR
      expect(c.unknownChangedMetrics, {'unknownTempB3'});
      expect(c.alarmActive, isTrue);
      expect(c.consumeBeep(), isTrue);

      c.acknowledgeAlarms();
      expect(c.unknownChangedMetrics, isEmpty);
      expect(c.alarmActive, isFalse);
      expect(c.alarmReasons, isEmpty);
    });

    test('acknowledgeAlarms clears a link error but not a live genuine fault',
        () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.alarmActive, isTrue);
      c.acknowledgeAlarms();
      expect(c.alarmActive, isFalse);

      // A genuine fault (chip over-temp byte[0]) cannot be acknowledged away.
      c.parser.addBytes([0xA6, 0xC0, 1, 0, 0, 0, 0, 0, 0, 0xB7, 0x72]);
      expect(c.alarmActive, isTrue);
      c.acknowledgeAlarms();
      expect(c.alarmActive, isTrue);
      expect(c.alarmReasons.single, contains('temperature'));
    });

    test('a user-initiated restart re-baselines the unknown bytes on reconnect',
        () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal());
      c.parser.addBytes(tempAlarm(b6: 1)); // baseline unknownTempB6 = 1
      await c.sendGateControl(GateAction.restart);
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      await c.connectTo('dev-1', name: 'JS-A');
      // After the reboot the status byte reads differently: new baseline, no
      // MAJOR alarm.
      c.parser.addBytes(tempAlarm(b6: 0));
      expect(c.unknownChangedMetrics, isEmpty);
      expect(c.alarmActive, isFalse);
      // ...but a change from the NEW baseline still alerts.
      c.parser.addBytes(tempAlarm(b6: 1));
      expect(c.unknownChangedMetrics, {'unknownTempB6'});
    });
  });
}
