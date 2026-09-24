/// GitHub #62: a switch-off must turn Bluetooth standby ("sleep") OFF first.
///
/// Live incident: a pack whose output was turned OFF while standby was ON
/// went dormant and unwakeable — with both MOS off no current flows through
/// it, this firmware wakes only on current, and the BLE bridge cannot wake
/// the MCU. So Output OFF / Charge OFF / Both OFF (per battery and fleet):
///
///  * standby ON  -> stern confirm carries the dormancy sentence; the send is
///    CMD_CLOSE_SLEEP_CONTROL (AA CC 01 01 DD EE), wait for the AC CA ack
///    (or 3 s), THEN the gate frame;
///  * standby unknown -> standby-OFF is sent anyway, the note says so;
///  * standby OFF -> no standby frame, no note;
///  * a switch-off that the C1 gate refuses sends NOTHING, not even the
///    standby-off;
///  * the sleep toggle is "Bluetooth standby (power saving)" with the
///    vendor's explanation; enabling it double-confirms.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/write_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

List<int> bal({int chgMos = 1, int disMos = 1}) =>
    [0xA8, 0xAC, 0x01, chgMos, disMos, 0, 1, 0, 0, 0xB9, 0x21];

/// SLEEP_SET_SUCCESS: AC CA <byte0> DE ED; byte0 == 0 => standby ON.
List<int> sleepAck({required bool on}) => [0xAC, 0xCA, on ? 0 : 1, 0xDE, 0xED];

const closeSleep = [0xAA, 0xCC, 0x01, 0x01, 0xDD, 0xEE];
const openSleep = [0xAA, 0xCC, 0x00, 0x01, 0xDD, 0xEE];

List<int> payload(List<int> frame) => frame.sublist(2, frame.length - 2);

bool isGate(List<int> w) => w.length == 12 && w[0] == 0xC3 && w[1] == 0x1E;

/// Let the in-flight write chain progress up to its next await.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    AppLog.instance.clear();
    AppLog.instance.echoToConsole = false;
  });

  Future<(BatteryConnection, FakeTransport)> connected(
      {bool? standby}) async {
    final t = FakeTransport();
    final c = BatteryConnection(transport: t);
    await c.connectTo('dev-1', name: 'JS-A');
    c.parser.addBytes(bal());
    if (standby != null) c.parser.addBytes(sleepAck(on: standby));
    expect(c.state.sleepModeOn, standby);
    t.writes.clear(); // drop the handshake
    return (c, t);
  }

  group('turnSwitchOff: standby-OFF goes out BEFORE the gate frame', () {
    for (final action in [
      GateAction.dischargeMos,
      GateAction.chargeMos,
      GateAction.bothMos
    ]) {
      test('${mosSwitchName(action)} OFF with standby ON: AA CC 01 01 DD EE, '
          'ack, then the gate frame', () async {
        final (c, t) = await connected(standby: true);
        expect(c.needsStandbyOffFirst, isTrue);
        final f = c.turnSwitchOff(action);
        await settle();
        // Only the standby-off has gone out; the gate frame waits for the ack.
        expect(t.writes, [closeSleep]);
        c.parser.addBytes(sleepAck(on: false));
        await f;
        expect(t.writes.length, 2);
        expect(t.writes[0], closeSleep);
        expect(isGate(t.writes[1]), isTrue);
        final p = payload(t.writes[1]);
        switch (action) {
          case GateAction.dischargeMos:
            expect(p.sublist(0, 2), [1, 0]);
          case GateAction.chargeMos:
            expect(p.sublist(0, 2), [0, 1]);
          default:
            expect(p.sublist(0, 2), [0, 0]);
        }
        expect(c.state.sleepModeOn, isFalse);
        final log = AppLog.instance.entries.map((e) => e.message).join('\n');
        expect(log, contains('Bluetooth standby ON on JS-A'));
        expect(log, contains('standby OFF acked by JS-A'));
      });
    }

    test('standby UNKNOWN: standby-OFF is sent anyway, then the gate frame',
        () async {
      final (c, t) = await connected();
      expect(c.state.sleepModeOn, isNull);
      expect(c.needsStandbyOffFirst, isTrue);
      final f = c.turnSwitchOff(GateAction.dischargeMos);
      await settle();
      expect(t.writes, [closeSleep]);
      c.parser.addBytes(sleepAck(on: false));
      await f;
      expect(t.writes.length, 2);
      expect(isGate(t.writes[1]), isTrue);
      expect(AppLog.instance.entries.map((e) => e.message).join('\n'),
          contains('Bluetooth standby unknown on JS-A'));
    });

    test('standby OFF (known): no standby frame, just the gate frame',
        () async {
      final (c, t) = await connected(standby: false);
      expect(c.needsStandbyOffFirst, isFalse);
      await c.turnSwitchOff(GateAction.dischargeMos);
      expect(t.writes.length, 1);
      expect(isGate(t.writes.single), isTrue);
      expect(payload(t.writes.single).sublist(0, 2), [1, 0]);
    });

    test('no ack within 3 s: the gate frame is still sent (and logged)',
        () async {
      final (c, t) = await connected(standby: true);
      final sw = Stopwatch()..start();
      await c.turnSwitchOff(GateAction.dischargeMos);
      sw.stop();
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(seconds: 3)));
      expect(t.writes.length, 2);
      expect(t.writes[0], closeSleep);
      expect(isGate(t.writes[1]), isTrue);
      expect(AppLog.instance.entries.map((e) => e.message).join('\n'),
          contains('no standby-OFF ack from JS-A within 3 s'));
      expect(BatteryConnection.standbyAckTimeout, const Duration(seconds: 3));
    });

    test('a switch-off the C1 gate refuses sends NOTHING — not even the '
        'standby-off', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A'); // no BAL_STATUS yet
      c.parser.addBytes(sleepAck(on: true));
      t.writes.clear();
      await expectLater(c.turnSwitchOff(GateAction.dischargeMos),
          throwsA(isA<StateError>()));
      await expectLater(c.turnSwitchOff(GateAction.chargeMos),
          throwsA(isA<StateError>()));
      expect(t.writes, isEmpty);
      expect(c.state.sleepModeOn, isTrue, reason: 'standby untouched');
    });

    test('not connected: refused, nothing sent', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';
      await expectLater(c.turnSwitchOff(GateAction.dischargeMos),
          throwsA(isA<StateError>()));
      expect(t.writes, isEmpty);
    });

    test('rejects a non-switch action', () async {
      final (c, _) = await connected(standby: false);
      await expectLater(c.turnSwitchOff(GateAction.heatGate),
          throwsA(isA<ArgumentError>()));
    });

    test('a switch ON never touches standby', () async {
      final (c, t) = await connected(standby: true);
      await c.sendGateControl(GateAction.dischargeMos, on: true);
      expect(t.writes.length, 1);
      expect(isGate(t.writes.single), isTrue);
      expect(c.state.sleepModeOn, isTrue);
    });
  });

  group('the switch-off actions route through turnSwitchOff', () {
    test('outputAction(off).send sends standby-OFF first when standby is ON',
        () async {
      final (c, t) = await connected(standby: true);
      final a = outputAction(c, target: false);
      final f = a.send();
      await settle();
      expect(t.writes, [closeSleep]);
      c.parser.addBytes(sleepAck(on: false));
      await f;
      expect(t.writes.length, 2);
      expect(payload(t.writes[1]).sublist(0, 2), [1, 0]);
    });

    test('chargeAction(off) and bothMosAction(off) too; ON actions do not',
        () async {
      final (c, t) = await connected(standby: true);
      final f = chargeAction(c, target: false).send();
      await settle();
      expect(t.writes, [closeSleep]);
      c.parser.addBytes(sleepAck(on: false));
      await f;
      expect(payload(t.writes[1]).sublist(0, 2), [0, 1]);
      t.writes.clear();
      c.parser.addBytes(sleepAck(on: true));
      final g = bothMosAction(c, target: false).send();
      await settle();
      expect(t.writes, [closeSleep]);
      c.parser.addBytes(sleepAck(on: false));
      await g;
      expect(payload(t.writes[1]).sublist(0, 2), [0, 0]);
      t.writes.clear();
      c.parser.addBytes(sleepAck(on: true));
      await outputAction(c, target: true).send();
      expect(t.writes.length, 1);
      expect(isGate(t.writes.single), isTrue);
    });
  });

  group('wording (pinned)', () {
    test('the dormancy sentence is exactly the incident wording', () {
      expect(
          standbyDormancyWarning,
          'With the output off this pack cannot pass current, so if it enters '
          'Bluetooth standby it cannot be woken by the app, a charger or a '
          'load until it is physically isolated. Standby will be turned OFF '
          'first.');
    });

    test('Output OFF with standby ON: stern page carries the sentence',
        () async {
      final (c, _) = await connected(standby: true);
      final a = outputAction(c, target: false);
      expect(a.dangerous, isTrue);
      expect(
          a.sternWarning,
          "This cuts JS-A's output — anything powered by it will lose power."
          '\n\n$standbyDormancyWarning');
      expect(a.sternWarning, isNot(contains('not known')));
      // Both OFF: the same sentence.
      expect(bothMosAction(c, target: false).sternWarning,
          endsWith('\n\n$standbyDormancyWarning'));
      // Charge OFF: the charge variant.
      expect(chargeAction(c, target: false).sternWarning,
          endsWith('\n\n$standbyDormancyWarningCharge'));
      expect(standbyDormancyWarningCharge,
          endsWith('Standby will be turned OFF first.'));
    });

    test('standby unknown: the note says the state is not known', () async {
      final (c, _) = await connected();
      expect(
          outputAction(c, target: false).sternWarning,
          "This cuts JS-A's output — anything powered by it will lose power."
          "\n\nThis pack's Bluetooth standby state is not known. "
          '$standbyDormancyWarning');
    });

    test('standby OFF: no note; switch ON: never a note', () async {
      final (c, _) = await connected(standby: false);
      expect(outputAction(c, target: false).sternWarning,
          "This cuts JS-A's output — anything powered by it will lose power.");
      expect(outputAction(c, target: false).sternWarning,
          isNot(contains('standby')));
      c.parser.addBytes(sleepAck(on: true));
      expect(outputAction(c, target: true).sternWarning, isNull);
      expect(outputAction(c, target: true).message, isNot(contains('standby')));
    });

    test('the standby toggle: renamed, vendor explanation, ON double-confirms',
        () {
      final c = BatteryConnection(transport: FakeTransport())
        ..state.serial = 'JS-A';
      expect(
          standbyExplanation,
          'When ON, the BMS stops its Bluetooth comms when it sees no '
          'charge/discharge current; current wakes it; to turn it off you '
          'must apply charge or a load first.');
      final on = sleepAction(c, target: true);
      expect(on.dangerous, isTrue);
      expect(on.busyKey, 'sleep');
      expect(on.title, 'Turn Bluetooth standby on');
      expect(on.message,
          'Turn Bluetooth standby (power saving) ON on JS-A?\n\n'
          '$standbyExplanation');
      expect(on.sternWarning,
          'Once JS-A sees no current it will STOP its Bluetooth comms — the '
          'app loses the connection and live data until charge or a load '
          'wakes it. A pack in standby with its output off cannot be woken at '
          'all until it is physically isolated.');
      expect(on.confirmLabel, 'Turn standby ON');
      expect(on.label, 'standby ON');
      expect(on.sentToast(), 'Sent: Bluetooth standby ON to JS-A');
      expect(on.warnTitle, isNull, reason: 'the link may drop before any ack');
      final off = sleepAction(c, target: false);
      expect(off.dangerous, isFalse);
      expect(off.title, 'Turn Bluetooth standby off');
      expect(off.message, 'Turn Bluetooth standby (power saving) OFF on JS-A?');
      expect(off.confirmLabel, 'Turn standby OFF');
      expect(off.label, 'standby OFF');
      expect(off.sentToast(), 'Sent: Bluetooth standby OFF to JS-A');
      expect(off.warnTitle, 'Standby OFF not confirmed');
      expect(off.warnMessage!(),
          'Command sent, but JS-A did not confirm Bluetooth standby OFF within '
          'a few seconds. Its standby setting may still be ON — check the '
          'connection and try again.');
      // Nothing user-facing says "sleep" any more.
      for (final t in [on.title, on.message, on.confirmLabel, off.title,
          off.message, off.confirmLabel, off.warnTitle!, off.warnMessage!()]) {
        expect(t.toLowerCase(), isNot(contains('sleep')), reason: t);
      }
    });

    test('the standby commands are the vendor frames', () {
      expect(BatteryCommands.closeSleep, closeSleep);
      expect(BatteryCommands.openSleep, openSleep);
    });
  });

  group('fleet switch-off', () {
    test('each member with standby ON / unknown gets standby-OFF first; the '
        'stern page names them', () async {
      final tA = FakeTransport(), tB = FakeTransport(), tC = FakeTransport();
      final a = BatteryConnection(transport: tA);
      final b = BatteryConnection(transport: tB);
      final c = BatteryConnection(transport: tC);
      await a.connectTo('dev-a', name: 'JS-A');
      await b.connectTo('dev-b', name: 'JS-B');
      await c.connectTo('dev-c', name: 'JS-C');
      for (final x in [a, b, c]) {
        x.parser.addBytes(bal());
      }
      a.parser.addBytes(sleepAck(on: true)); // ON
      b.parser.addBytes(sleepAck(on: false)); // OFF
      // c: unknown
      for (final t in [tA, tB, tC]) {
        t.writes.clear();
      }
      final m = BatteryManager()..batteries.addAll([a, b, c]);
      for (final x in [a, b, c]) {
        m.setInFleet(x, true);
      }
      expect(m.fleetNeedingStandbyOff.map((x) => x.state.serial),
          ['JS-A', 'JS-C']);
      final action = fleetOutputAction(m, on: false);
      expect(action.sternWarning,
          'This will cut output to every fleet battery (JS-A, JS-B, JS-C); '
          'anything powered by them will lose power.\n\n'
          '$standbyDormancyWarning (JS-A, JS-C)\n\n'
          '$parallelBankWarning'); // #62: three members = a parallel bank
      expect(fleetOutputAction(m, on: true).sternWarning, isNull);

      final f = action.send();
      await settle();
      expect(tA.writes, [closeSleep]);
      a.parser.addBytes(sleepAck(on: false));
      await settle();
      await settle();
      // A done (standby-off + gate); B (standby OFF) gets the gate only; C
      // (unknown) gets standby-off and waits for its ack.
      expect(tA.writes.length, 2);
      expect(isGate(tA.writes[1]), isTrue);
      expect(tB.writes.length, 1);
      expect(isGate(tB.writes.single), isTrue);
      expect(tC.writes, [closeSleep]);
      c.parser.addBytes(sleepAck(on: false));
      await f;
      expect(await action.readBack!(), isTrue, reason: 'all members OK');
      expect(tC.writes.length, 2);
      expect(isGate(tC.writes[1]), isTrue);
      expect(action.sentToast(), 'Sent: output OFF to 3 batteries');
    });

    test('no members need it: the fleet stern page has no standby note',
        () async {
      final tA = FakeTransport();
      final a = BatteryConnection(transport: tA);
      await a.connectTo('dev-a', name: 'JS-A');
      a.parser.addBytes(bal());
      a.parser.addBytes(sleepAck(on: false));
      final m = BatteryManager()..batteries.add(a);
      m.setInFleet(a, true);
      expect(m.fleetNeedingStandbyOff, isEmpty);
      expect(fleetChargeAction(m, on: false).sternWarning,
          isNot(contains('standby')));
    });
  });
}
