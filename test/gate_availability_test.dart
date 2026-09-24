/// GitHub #55: the "gate controls locked" report on JS-2C14B8.
///
/// The C1 safety gate was re-locking on every short stall of a weak link
/// (5 s window vs. a −90 dBm pack that re-handshook 82 times and stalled ≥ 5 s
/// nine times in one session) and applied the same strict rule to RESTART —
/// the very action needed to clear a latched over-temp. These tests pin down
/// the loosened rule:
///
///  * freshness is measured from the last DECODED BAL_STATUS, exposed as an
///    age, with a 15 s window;
///  * a healthy ~1 s stream never becomes unavailable; a stall shorter than
///    15 s does not either;
///  * restart / factory (momentary) only need a connected link and a base
///    decoded on it — any age — and the frame carries that last base;
///  * a zero-filled base is still never sent;
///  * the wording never implies a permission step.
library;

import 'dart:async';

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/write_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  reproductionTests();

  List<int> bal({
    int chgMos = 1,
    int disMos = 1,
    int passive = 0,
    int tempGate = 1,
    int smoke = 0,
    int heat = 0,
  }) =>
      [0xA8, 0xAC, 0x01, chgMos, disMos, passive, tempGate, smoke, heat, 0xB9, 0x21];

  List<int> payload(List<int> frame) => frame.sublist(2, frame.length - 2);

  // A cell-voltage frame (A0 C1): telemetry that is not a BAL_STATUS.
  List<int> cells() =>
      [0xA0, 0xC1, 0x04, 0x05, 0x0d, 0x08, 0x0d, 0x07, 0x0d, 0x05, 0x0d, 0xB1, 0xD2];

  group('#55: gate-status age is exposed', () {
    test('null before the first BAL_STATUS, then the elapsed ms', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      expect(c.gateStatusAgeMs, isNull);
      expect(c.gateBase, isNull);
      c.parser.addBytes(bal());
      expect(c.gateStatusAgeMs, 0);
      clock = clock.add(const Duration(milliseconds: 1200));
      expect(c.gateStatusAgeMs, 1200);
      expect(c.gateBase, isNotNull);
    });

    test('the summary line names the serial, the age and the availability',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      expect(c.gateStatusSummary(), contains('no gate status yet'));
      expect(c.gateStatusSummary(), contains('unavailable'));
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      c.parser.addBytes(bal());
      clock = clock.add(const Duration(milliseconds: 1500));
      final line = c.gateStatusSummary();
      expect(line, contains('connected'));
      expect(line, contains('gate status 1.5 s ago'));
      expect(line, contains('controls available'));
      clock = clock.add(const Duration(seconds: 20));
      final stale = c.gateStatusSummary();
      expect(stale, contains('controls unavailable'));
      expect(stale, contains('Charge ON / Output ON / Restart still available'));
    });
  });

  group('#55: a healthy stream never becomes unavailable', () {
    test('BAL_STATUS every ~1 s for a minute: available throughout', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      for (var i = 0; i < 60; i++) {
        c.parser.addBytes(bal());
        // Jittery cadence: 0.8–1.4 s, and the UI is not rebuilt at all.
        clock = clock.add(Duration(milliseconds: 800 + (i % 7) * 100));
        expect(c.gateControlsDisabledReason, isNull, reason: 'tick $i');
        expect(c.safeWritesDisabledReason, isNull, reason: 'tick $i');
      }
    });

    test('BAL_STATUS stall < 15 s (other frames flowing) stays available; '
        '15 s does not', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      c.parser.addBytes(bal());
      for (var i = 0; i < 14; i++) {
        clock = clock.add(const Duration(seconds: 1));
        c.parser.addBytes(cells()); // telemetry keeps flowing, no BAL_STATUS
        expect(c.gateControlsDisabledReason, isNull, reason: 'second $i');
      }
      clock = clock.add(const Duration(seconds: 1));
      c.parser.addBytes(cells());
      expect(c.gateControlsDisabledReason,
          BatteryConnection.reasonGateStatusStale(15000));
      expect(c.gateControlsDisabledReason, contains('15 s'));
      // The next decoded frame makes it available again, no rebuild needed.
      c.parser.addBytes(bal());
      expect(c.gateControlsDisabledReason, isNull);
    });
  });

  group('#59: safe writes (Output ON / Restart) and the streaming watchdog',
      () {
    test('Output ON is allowed on a connected row with NO status at all: '
        'MOS = 1/1, protective defaults for the rest', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-aa', name: 'JS-2C14AA');
      expect(c.gateControlsDisabledReason,
          BatteryConnection.reasonNoGateStatus);
      expect(c.safeWritesDisabledReason, isNull);
      expect(c.disabledReasonFor(GateAction.bothMos, on: true), isNull);
      expect(c.disabledReasonFor(GateAction.bothMos, on: false), isNotNull);
      await c.sendGateControl(GateAction.bothMos, on: true);
      // chg=1 dis=1 temp=1 (protection ON) smoke=0 heat=0 restart=0 bal=0 f=0
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 0, 0, 0]);
    });

    test('Output ON with a STALE base: MOS forced 1/1, the rest last-known',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-aa', name: 'JS-2C14AA');
      // The pack reports output OFF, heater on, passive on; then goes quiet.
      c.parser.addBytes(bal(chgMos: 0, disMos: 0, heat: 1, passive: 1));
      clock = clock.add(const Duration(minutes: 2));
      expect(c.gateControlsDisabledReason, isNotNull);
      await c.sendGateControl(GateAction.bothMos, on: true);
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 1, 0, 1, 0]);
    });

    test('Output OFF / passive OFF / heater OFF / factory stay refused '
        'without a fresh status', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-aa', name: 'JS-2C14AA');
      for (final f in [
        () => c.sendGateControl(GateAction.bothMos, on: false),
        () => c.sendGateControl(GateAction.passiveBalance, on: false),
        () => c.sendGateControl(GateAction.heatGate, on: false),
        () => c.sendGateControl(GateAction.factory),
        // Passive / heater ON would have to force MOS on too: gated.
        () => c.sendGateControl(GateAction.passiveBalance, on: true),
      ]) {
        await expectLater(f(), throwsA(isA<StateError>()));
      }
      expect(t.gateWrites, isEmpty);
      // Same with a stale base.
      c.parser.addBytes(bal());
      clock = clock.add(const Duration(seconds: 20));
      await expectLater(c.sendGateControl(GateAction.bothMos, on: false),
          throwsA(isA<StateError>()));
      expect(t.gateWrites, isEmpty);
      // And allowed once fresh.
      c.parser.addBytes(bal());
      await c.sendGateControl(GateAction.bothMos, on: false);
      expect(payload(t.gateWrites.single).sublist(0, 2), [0, 0]);
    });

    test('a connected link silent for 10 s reads "not streaming"; safe '
        'writes still go out; frames resuming clears it', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-aa', name: 'JS-2C14AA');
      c.parser.addBytes(bal());
      expect(c.notStreaming, isFalse);
      clock = clock.add(const Duration(seconds: 9));
      expect(c.gateControlsDisabledReason, isNull);
      clock = clock.add(const Duration(seconds: 1));
      expect(c.notStreaming, isTrue);
      expect(c.gateControlsDisabledReason,
          BatteryConnection.reasonNotStreaming(10000));
      expect(c.gateControlsDisabledReason, contains('not streaming'));
      // #62: never "asleep" — standby is a stored setting, not a state.
      expect(c.gateControlsDisabledReason, isNot(contains('asleep')));
      expect(c.gateControlsDisabledReason, contains('standby'));
      expect(c.gateStatusSummary(), contains('NOT streaming'));
      expect(c.safeWritesDisabledReason, isNull);
      await c.sendGateControl(GateAction.restart);
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 1, 0, 0]);
      c.parser.addBytes(cells());
      expect(c.notStreaming, isFalse);
      expect(c.gateStatusSummary(), contains('streaming'));
    });

    test('a fresh link that never sends a frame reads "not streaming" after '
        '10 s (measured from connect)', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await c.connectTo('dev-aa', name: 'JS-2C14AA');
      expect(c.gateControlsDisabledReason,
          BatteryConnection.reasonNoGateStatus);
      clock = clock.add(const Duration(seconds: 10));
      expect(c.gateControlsDisabledReason, contains('not streaming'));
    });
  });

  group('#55: restart is a safe write', () {
    test('allowed with a STALE base; MOS forced on, the rest from that base',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      c.parser.addBytes(bal(chgMos: 1, disMos: 1, passive: 0, tempGate: 1));
      clock = clock.add(const Duration(minutes: 3)); // way past the window
      expect(c.gateControlsDisabledReason, isNotNull);
      expect(c.safeWritesDisabledReason, isNull);
      expect(c.disabledReasonFor(GateAction.bothMos, on: false), isNotNull);
      expect(c.disabledReasonFor(GateAction.restart), isNull);
      expect(c.disabledReasonFor(GateAction.factory), isNotNull,
          reason: 'factory erases configuration: fresh gate kept');

      await c.sendGateControl(GateAction.restart);
      expect(t.gateWrites.length, 1);
      // chg[0]=1 dis[1]=1 temp[2]=1 smoke[3]=0 heat[4]=0 restart[5]=1
      // passive[6]=0 factory[7]=0 — never zeros for the MOS bytes.
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 1, 0, 0]);
      expect(c.disconnectExpected, isTrue, reason: 'reboot drop is expected');
    });

    test('a persistent toggle with the same stale base is still refused',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      c.parser.addBytes(bal());
      clock = clock.add(const Duration(seconds: 30));
      await expectLater(c.sendGateControl(GateAction.bothMos, on: false),
          throwsA(isA<StateError>()));
      expect(t.gateWrites, isEmpty);
    });

    test('refused only while not connected; with no status on this link it '
        'goes out on the safe base (MOS on, never a zero MOS)', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      expect(c.safeWritesDisabledReason, BatteryConnection.reasonNotConnected);
      await expectLater(
          c.sendGateControl(GateAction.restart), throwsA(isA<StateError>()));
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      expect(c.safeWritesDisabledReason, isNull);
      await c.sendGateControl(GateAction.restart);
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 1, 0, 0]);
      // After a reconnect the last-known gates of this ROW are reused.
      c.parser.addBytes(bal(heat: 1));
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      expect(c.gateControlsDisabledReason,
          BatteryConnection.reasonNoGateStatus);
      await c.sendGateControl(GateAction.restart);
      expect(payload(t.gateWrites.last), [1, 1, 1, 0, 1, 1, 0, 0]);
    });

    test('the confirmation notes a missing fresh base; fresh does not',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await c.connectTo('dev-1', name: 'JS-2C14B8');
      // Never seen a status: safe defaults are spelled out.
      expect(restartAction(c).sternWarning, contains('safe defaults'));
      expect(outputAction(c, target: true).message, contains('safe defaults'));
      c.parser.addBytes(bal());
      expect(restartAction(c).sternWarning, isNot(contains('Note:')));
      expect(outputAction(c, target: true).message, isNot(contains('Note:')));
      clock = clock.add(const Duration(seconds: 42));
      expect(restartAction(c).sternWarning, contains('42 s'));
      expect(restartAction(c).sternWarning, contains('last-known values'));
      // #58: Output ON forces ONLY its own byte; the charge switch keeps its
      // last-known value (ON from the BAL_STATUS above).
      expect(outputAction(c, target: true).message,
          contains('output ON (discharge MOS byte = 1)'));
      expect(outputAction(c, target: true).message,
          contains('the charge switch keeps its last-known value (ON)'));
      expect(chargeAction(c, target: true).message,
          contains('charge ON (charge MOS byte = 1)'));
      expect(bothMosAction(c, target: true).message,
          contains('both MOS bytes = 1'));
      expect(outputAction(c, target: false).message, isNot(contains('Note:')));
      expect(chargeAction(c, target: false).message, isNot(contains('Note:')));
      expect(restartAction(c).dangerous, isTrue,
          reason: 'still double-confirmed');
    });
  });

  group('#55: wording is automatic, never a permission step', () {
    final reasons = [
      BatteryConnection.reasonNotConnected,
      BatteryConnection.reasonNoGateStatus,
      BatteryConnection.reasonGateStatusStale(20000),
      BatteryConnection.reasonNotStreaming(12000),
    ];

    test('reasons and notes contain no "locked" / "approve"', () {
      for (final r in reasons) {
        for (final text in [
          r,
          controlsUnavailableText(r),
          controlsUnavailableText(r, safeWritesAvailable: true),
          restartUnavailableText(r),
        ]) {
          final lower = text.toLowerCase();
          expect(lower, isNot(contains('lock')), reason: text);
          expect(lower, isNot(contains('approv')), reason: text);
          expect(lower, isNot(contains('permission')), reason: text);
        }
      }
    });

    test('the note says it clears automatically and carries the reason', () {
      final r = BatteryConnection.reasonGateStatusStale(20000);
      final text = controlsUnavailableText(r, safeWritesAvailable: true);
      expect(text, startsWith('Controls unavailable — '));
      expect(text, contains('20 s'));
      expect(text, contains('automatically'));
      expect(text,
          contains('Charge ON, Output ON and Restart BMS stay available'));
      expect(controlsUnavailableText(r),
          isNot(contains('stay available')));
      expect(restartUnavailableText(BatteryConnection.reasonNotConnected),
          contains('automatically'));
    });
  });
}

// ---------------------------------------------------------------------------
// #55 reproduction: on a CONNECTED, STREAMING pack the controls must be
// available — through every path a real row takes to being connected.
// ---------------------------------------------------------------------------

void reproductionTests() {
  List<int> bal({int chgMos = 1, int disMos = 1}) =>
      [0xA8, 0xAC, 0x01, chgMos, disMos, 0, 1, 0, 0, 0xB9, 0x21];

  group('#55 reproduction: a connected streaming row is available', () {
    test('remembered favourite -> discovered -> bound -> connected -> streams',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final store = FakeFleetStore()
        ..saved = {
          'JS-2C14B8': const FleetRecord(
              serial: 'JS-2C14B8', profile: 'JS', remoteId: 'dev-b8'),
        };
      final m =
          BatteryManager(transport: t, fleetStore: store, now: () => clock);
      await m.loadFleetMembership();
      m.materialiseRememberedFleet();
      final placeholder = m.batteries.single;
      expect(placeholder.connState, ConnState.disconnected);
      expect(placeholder.gateControlsDisabledReason,
          BatteryConnection.reasonNotConnected);

      // Discovery binds the SAME row (no duplicate), then connects it.
      final bound = m.resolveDiscovered(
          serial: 'JS-2C14B8',
          deviceId: 'dev-b8',
          profile: DeviceProfile.sphere);
      expect(identical(bound, placeholder), isTrue);
      await m.connectForTest(bound, 'dev-b8', 'JS-2C14B8');
      expect(m.batteries.single.connState, ConnState.connected);
      expect(m.batteries.single.gateControlsDisabledReason,
          BatteryConnection.reasonNoGateStatus);

      // The stream arrives on that row: available within one frame, and
      // stays available across a minute of ~1 s frames with no UI involved.
      for (var i = 0; i < 60; i++) {
        m.batteries.single.parser.addBytes(bal());
        clock = clock.add(const Duration(seconds: 1));
        final row = m.batteries.single;
        expect(row.gateControlsDisabledReason, isNull, reason: 'frame $i');
        expect(row.safeWritesDisabledReason, isNull);
        expect(identical(row, placeholder), isTrue);
      }
      expect(m.batteries.single.gateStatusSummary(), contains('available'));
      await m.batteries.single.sendGateControl(GateAction.restart);
      expect(t.gateWrites.length, 1);
      m.disposeAll();
    });

    test('reconnect on the same row: unavailable only until the first frame',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-b8', name: 'JS-2C14B8');
      c.parser.addBytes(bal());
      expect(c.gateControlsDisabledReason, isNull);
      // Link drops -> manager reconnects the same row.
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.connState, ConnState.disconnected);
      await c.connectTo('dev-b8', name: 'JS-2C14B8');
      expect(c.connState, ConnState.connected);
      expect(
          c.gateControlsDisabledReason, BatteryConnection.reasonNoGateStatus);
      c.parser.addBytes(bal());
      clock = clock.add(const Duration(seconds: 1));
      expect(c.gateControlsDisabledReason, isNull);
      expect(c.safeWritesDisabledReason, isNull);
    });

    test(
        'the state field is right even after dispose(): a disposed row '
        'refuses to reconnect and never streams as "disconnected"', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-b8', name: 'JS-2C14B8');
      await c.dispose();
      expect(c.connState, ConnState.disconnected);
      // Before #55 this connected the disposed row's link and left connState
      // at `disconnected` (the closed-controller guard returned before the
      // field was updated) — a streaming pack showing "Not connected".
      await expectLater(c.connectTo('dev-b8', name: 'JS-2C14B8'),
          throwsA(isA<StateError>()));
      expect(c.connState, isNot(ConnState.connected));
      expect(t.connectCalls, 1, reason: 'no second link was opened');
    });

    test('an in-flight connect is abandoned by dispose() (no zombie link)',
        () async {
      final t = FakeTransport()..connectGate = Completer<void>();
      final c = BatteryConnection(transport: t);
      final pending = c.connectTo('dev-b8', name: 'JS-2C14B8');
      // Let the sequence reach the (gated) transport connect.
      for (var i = 0; i < 20 && t.connectCalls == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(t.connectCalls, 1);
      await c.dispose();
      t.connectGate!.complete(); // the transport now hands back a live link
      await expectLater(pending, throwsA(isA<StateError>()));
      expect(t.lastLink!.disconnected, isTrue, reason: 'late link dropped');
      expect(c.connState, ConnState.disconnected);
    });

    test('Diagnostics gets one line per availability change with the inputs',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      AppLog.instance.clear();
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await c.connectTo('dev-b8', name: 'JS-2C14B8');
      c.parser.addBytes(bal());
      for (var i = 0; i < 20; i++) {
        c.parser.addBytes(bal());
        clock = clock.add(const Duration(seconds: 1));
      }
      final lines = AppLog.instance
          .recent()
          .map((e) => e.message)
          .where((m) => m.contains('controls'))
          .toList();
      // connecting (not connected) -> connected (no status) -> available;
      // the 20 healthy frames add nothing.
      expect(lines.length, 3, reason: lines.join('\n'));
      expect(
          lines.any((l) => l.contains('unavailable: Not connected')), isTrue);
      expect(
          lines.any((l) => l.contains('unavailable: Waiting for gate status')),
          isTrue);
      final ok = lines.firstWhere((l) => l.contains('controls available'));
      expect(ok, contains('JS-2C14B8'));
      expect(ok, contains('conn=connected'));
      expect(ok, contains('chg=true dis=true temp=1 smoke=0 heat=0 bal=false'));
      expect(ok, contains('gate status 0 ms ago'));
    });
  });
}
