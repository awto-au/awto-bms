import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/write_actions.dart';

import 'fakes.dart';

/// Review pass C2: the data-driven write controls. Every control is now a
/// [WriteAction] descriptor; these tests pin the EXACT dialog texts, the
/// double-confirm (stern warning) set, the busy keys, the failure labels, the
/// toasts and the read-back / warning wiring to what the hand-written handlers
/// produced before — so the refactor is provably behaviour-preserving.
void main() {
  BatteryConnection conn([String serial = 'JS-A']) =>
      BatteryConnection(transport: FakeTransport())..state.serial = serial;

  group('the double-confirm set is exactly: output OFF, sleep ON, restart, '
      'factory reset, fleet output OFF', () {
    test('dangerous actions carry a stern warning; the rest do not', () {
      final c = conn();
      final m = BatteryManager()..batteries.add(c);
      m.setInFleet(c, true);
      expect(outputAction(c, target: false).dangerous, isTrue);
      expect(outputAction(c, target: true).dangerous, isFalse);
      expect(sleepAction(c, target: true).dangerous, isTrue);
      expect(sleepAction(c, target: false).dangerous, isFalse);
      expect(restartAction(c).dangerous, isTrue);
      expect(factoryAction(c).dangerous, isTrue);
      expect(fleetOutputAction(m, on: false).dangerous, isTrue);
      expect(fleetOutputAction(m, on: true).dangerous, isFalse);
      expect(capacityAction(c, 100).dangerous, isFalse);
      for (final on in [true, false]) {
        expect(
            gateToggleAction(c,
                    label: 'Passive balancing',
                    busyKey: WriteKeys.passive,
                    isOn: on,
                    action: GateAction.passiveBalance)
                .dangerous,
            isFalse);
        expect(
            gateToggleAction(c,
                    label: 'Heater',
                    busyKey: WriteKeys.heater,
                    isOn: on,
                    action: GateAction.heatGate)
                .dangerous,
            isFalse);
      }
    });
  });

  group('output (#26 / #24)', () {
    test('OFF: two-step confirm, read-back, warning names the live state', () {
      final c = conn();
      c.state
        ..chargeMos = true
        ..dischargeMos = true;
      final a = outputAction(c, target: false);
      expect(a.busyKey, 'output');
      expect(a.title, 'Turn output OFF');
      expect(a.message,
          'Turn the output (charge + discharge MOS) OFF on JS-A?');
      expect(a.sternWarning,
          "This cuts JS-A's output — anything powered by it will lose power, "
          'and it will stop charging.');
      expect(a.confirmLabel, 'Turn output OFF');
      expect(a.label, 'output OFF');
      expect(a.sentToast(), 'Sent: output OFF to JS-A');
      expect(a.readBack, isNotNull);
      expect(a.warnTitle, 'Output not confirmed');
      expect(a.warnMessage!(),
          'Command sent, but JS-A still reports output ON. The change may '
          'not have taken effect — check the connection and try again.');
    });

    test('ON: single confirm', () {
      final a = outputAction(conn(), target: true);
      expect(a.title, 'Turn output on');
      expect(a.message, 'Turn the output (charge + discharge MOS) ON on JS-A?');
      expect(a.confirmLabel, 'Turn ON');
      expect(a.danger, isFalse);
      expect(a.label, 'output ON');
      expect(a.sentToast(), 'Sent: output ON to JS-A');
    });

    test('no serial yet -> "this battery"', () {
      final noSerial = BatteryConnection(transport: FakeTransport());
      expect(outputAction(noSerial, target: true).message,
          contains('on this battery?'));
      expect(serialOf(noSerial), 'this battery');
    });
  });

  group('gate toggles (passive balancing, heater)', () {
    test('turning ON is a plain confirm with the enable note appended', () {
      final a = gateToggleAction(conn(),
          label: 'Heater',
          busyKey: WriteKeys.heater,
          isOn: false,
          action: GateAction.heatGate,
          enableNote: 'The self-heating element draws power from the pack '
              'and warms the cells.');
      expect(a.title, 'Turn Heater on');
      expect(a.message,
          'Turn Heater ON on JS-A?\n\nThe self-heating element draws power '
          'from the pack and warms the cells.');
      expect(a.confirmLabel, 'Turn ON');
      expect(a.danger, isFalse);
      expect(a.label, 'heater ON');
      expect(a.sentToast(), 'Sent: Heater ON to JS-A');
      expect(a.readBack, isNull);
      expect(a.busyKey, 'heater');
    });

    test('turning OFF is a red single confirm (not dangerous by default)', () {
      final a = gateToggleAction(conn(),
          label: 'Passive balancing',
          busyKey: WriteKeys.passive,
          isOn: true,
          action: GateAction.passiveBalance,
          enableNote: 'ignored when turning off');
      expect(a.title, 'Turn Passive balancing off');
      expect(a.message, 'Turn Passive balancing OFF on JS-A?');
      expect(a.confirmLabel, 'Turn OFF');
      expect(a.danger, isTrue);
      expect(a.sternWarning, isNull);
      expect(a.label, 'passive balancing OFF');
      expect(a.sentToast(), 'Sent: Passive balancing OFF to JS-A');
      expect(a.busyKey, 'passive balancing');
    });

    test('a dangerousWhenOff toggle double-confirms with the off warning', () {
      final a = gateToggleAction(conn(),
          label: 'Charge MOS',
          busyKey: 'x',
          isOn: true,
          action: GateAction.chargeMos,
          dangerousWhenOff: true);
      expect(a.title, 'Turn Charge MOS OFF');
      expect(a.message, 'Turn Charge MOS OFF on JS-A?');
      expect(a.sternWarning, 'This turns Charge MOS off on JS-A.');
      expect(a.confirmLabel, 'Turn Charge MOS OFF');
    });
  });

  group('sleep (#42)', () {
    test('sleep ON: two-step, read-back, but NO warning on timeout', () {
      final a = sleepAction(conn(), target: true);
      expect(a.busyKey, 'sleep');
      expect(a.title, 'Put BMS to sleep');
      expect(a.message, 'Put JS-A into sleep mode?');
      expect(a.sternWarning,
          'Sleeping the BMS may DROP the BLE link and STOP telemetry from '
          'JS-A — you may lose the connection and live data until it wakes.');
      expect(a.confirmLabel, 'Sleep now');
      expect(a.label, 'sleep ON');
      expect(a.sentToast(), 'Sent: sleep ON to JS-A');
      expect(a.readBack, isNotNull);
      expect(a.warnTitle, isNull, reason: 'the link may drop before any ack');
    });

    test('wake: single confirm, warns when not confirmed', () {
      final a = sleepAction(conn(), target: false);
      expect(a.title, 'Wake BMS');
      expect(a.message, 'Wake JS-A from sleep mode?');
      expect(a.confirmLabel, 'Wake');
      expect(a.danger, isFalse);
      expect(a.label, 'sleep OFF');
      expect(a.warnTitle, 'Wake not confirmed');
      expect(a.warnMessage!(),
          'Command sent, but JS-A did not report waking within a few '
          'seconds. It may still be asleep — check the connection and try '
          'again.');
    });
  });

  group('capacity (#38)', () {
    test('red single confirm, read-back and warning', () {
      final a = capacityAction(conn(), 120);
      expect(a.busyKey, 'capacity');
      expect(a.title, 'Write rated capacity');
      expect(a.message,
          "Set JS-A's rated capacity to 120 Ah?\n\nThis rewrites the pack’s "
          'SOC and remaining-time estimator basis.');
      expect(a.confirmLabel, 'Write capacity');
      expect(a.danger, isTrue);
      expect(a.label, 'capacity 120 Ah');
      expect(a.sentToast(), 'Sent: capacity 120 Ah to JS-A');
      expect(a.warnTitle, 'Capacity write not confirmed');
      expect(a.warnMessage!(),
          'Command sent, but JS-A did not acknowledge the new capacity within '
          'a few seconds. It may not have taken effect — check the connection '
          'and try again.');
    });
  });

  group('restart / factory', () {
    test('restart: two-step, no read-back', () {
      final a = restartAction(conn());
      expect(a.busyKey, 'restart');
      expect(a.title, 'Restart BMS');
      expect(a.message, 'Restart (reboot) the BMS on JS-A?');
      expect(a.sternWarning,
          'The battery management system on JS-A will reboot; output may '
          'drop briefly and the link will reconnect. A restart also CLEARS the '
          'latched over-temperature protection (temp-alarm byte[2]), which '
          'inhibits charging while set.');
      expect(a.confirmLabel, 'Restart');
      expect(a.label, 'restart BMS');
      expect(a.sentToast(), 'Sent: restart to JS-A');
      expect(a.readBack, isNull);
    });

    test('factory reset: two-step, no read-back', () {
      final a = factoryAction(conn());
      expect(a.busyKey, 'factory reset');
      expect(a.title, 'Factory reset');
      expect(a.message, 'FACTORY RESET JS-A?');
      expect(a.sternWarning,
          "This erases JS-A's configuration and restores factory defaults. "
          'It cannot be undone and may cut output. Only do this if you are '
          'certain.');
      expect(a.confirmLabel, 'Factory reset');
      expect(a.label, 'factory reset');
      expect(a.sentToast(), 'Sent: FACTORY RESET to JS-A');
    });
  });

  group('fleet output (#11 / M3)', () {
    BatteryManager fleet() {
      final m = BatteryManager();
      final a = conn('JS-A'), b = conn('JS-B');
      m.batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      return m;
    }

    test('OFF lists every serial and double-confirms', () {
      final a = fleetOutputAction(fleet(), on: false);
      expect(a.busyKey, 'fleet output');
      expect(a.title, 'ALL output OFF');
      expect(a.message,
          'Turn the discharge MOS (output) OFF on all 2 batteries in the '
          'fleet?\n\n • JS-A\n • JS-B');
      expect(a.sternWarning,
          'This will cut output to every fleet battery (JS-A, JS-B); '
          'anything powered by them will lose power.');
      expect(a.confirmLabel, 'Turn ALL output OFF');
      expect(a.label, 'fleet output OFF');
    });

    test('ON is a single confirm sharing the same busy key', () {
      final a = fleetOutputAction(fleet(), on: true);
      expect(a.busyKey, 'fleet output');
      expect(a.title, 'All output ON');
      expect(a.message,
          'Turn the discharge MOS (output) ON on all 2 batteries in the '
          'fleet?\n\n • JS-A\n • JS-B');
      expect(a.confirmLabel, 'Turn ALL output ON');
      expect(a.danger, isFalse);
    });

    test('before the send there is no toast and the read-back is "ok"', () {
      final a = fleetOutputAction(fleet(), on: true);
      expect(a.sentToast(), isNull);
    });

    test('a partly failed fleet write: NO toast, the warning lists the '
        'failures by serial', () async {
      final tA = FakeTransport(), tB = FakeTransport();
      final a = BatteryConnection(transport: tA);
      final b = BatteryConnection(transport: tB);
      await a.connectTo('dev-a', name: 'JS-A');
      await b.connectTo('dev-b', name: 'JS-B');
      for (final x in [a, b]) {
        x.parser.addBytes(
            [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21]); // BAL_STATUS
      }
      final m = BatteryManager()..batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      tB.failWrite = true;
      final action = fleetOutputAction(m, on: false);
      await action.send();
      expect(action.sentToast(), isNull, reason: 'partial failure: no Sent:');
      expect(await action.readBack!(), isFalse);
      expect(action.warnTitle, 'Fleet write partly failed');
      expect(action.warnMessage!(),
          'Sent output OFF to 1 battery (JS-A).\n\nFailed on 1 battery:\n'
          ' • JS-B: GATT write failed');
      // All OK -> toast, read-back true, so no warning is raised.
      tB.failWrite = false;
      final ok = fleetOutputAction(m, on: true);
      await ok.send();
      expect(ok.sentToast(), 'Sent: output ON to 2 batteries');
      expect(await ok.readBack!(), isTrue);
    });
  });

  group('BusyWrites (M4)', () {
    test('holds the key for the body, repaints both edges, drops re-entry',
        () async {
      final busy = BusyWrites();
      var repaints = 0;
      final f = busy.run('output', () => repaints++, () async {
        expect(busy.any, isTrue);
        expect(busy.contains('output'), isTrue);
        expect(busy.current, 'output');
        // A double-tap for the same key while held is dropped.
        await busy.run('output', () => repaints += 100, () async {
          fail('re-entrant run must not execute');
        });
      });
      expect(busy.any, isTrue);
      await f;
      expect(busy.any, isFalse);
      expect(busy.current, isNull);
      expect(repaints, 2);
    });

    test('the key is released even when the body throws', () async {
      final busy = BusyWrites();
      await expectLater(
          busy.run('k', () {}, () async => throw StateError('boom')),
          throwsA(isA<StateError>()));
      expect(busy.any, isFalse);
    });
  });

  group('labels', () {
    test('gateWriteLabel names the gate and the direction (not for restart / '
        'factory)', () {
      expect(gateWriteLabel(GateAction.output, on: true), 'output ON');
      expect(gateWriteLabel(GateAction.passiveBalance, on: false),
          'passive balancing OFF');
      expect(gateWriteLabel(GateAction.heatGate, on: true), 'heater ON');
      expect(gateWriteLabel(GateAction.tempControlGate, on: true),
          'low-temp protection ON');
      expect(gateWriteLabel(GateAction.smokeGate, on: false),
          'smoke sensor OFF');
      expect(gateWriteLabel(GateAction.chargeMos, on: true), 'charge MOS ON');
      expect(gateWriteLabel(GateAction.dischargeMos, on: true),
          'discharge MOS ON');
      expect(gateWriteLabel(GateAction.restart, on: true), 'restart BMS');
      expect(gateWriteLabel(GateAction.factory, on: true), 'factory reset');
    });

    test('busy keys are the original strings', () {
      expect(WriteKeys.output, 'output');
      expect(WriteKeys.passive, 'passive balancing');
      expect(WriteKeys.heater, 'heater');
      expect(WriteKeys.sleep, 'sleep');
      expect(WriteKeys.capacity, 'capacity');
      expect(WriteKeys.restart, 'restart');
      expect(WriteKeys.factory, 'factory reset');
    });
  });
}
