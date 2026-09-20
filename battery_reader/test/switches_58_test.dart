/// GitHub #58: "Output" split into the two independent MOSFET switches the
/// BMS actually has — "Charge" (charge MOS, gate byte[0]) and "Output"
/// (discharge MOS, gate byte[1]) — with a convenience "Both".
///
///  * frame builder: Charge flips ONLY byte[0], Output ONLY byte[1], Both
///    flips both; every other gate keeps its base value;
///  * safe write (#59): Charge ON / Output ON without a fresh status force
///    ONLY their own byte to 1 and leave the other switch at its last-known
///    value (never silently switched on); Both ON / Restart force both;
///  * safety gate (C1): Charge OFF / Output OFF / Both OFF are refused
///    without a fresh status;
///  * read-back is per switch;
///  * dialog texts + the double-confirm set are pinned, nothing says just
///    "MOS";
///  * the demo battery acks per switch;
///  * fleet: per-switch writes and counts;
///  * UI: two states on the card, the detail header, Gates & status and the
///    fleet panel; two controls plus Both; fleet control pairs.
library;

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/demo_source.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/main.dart';
import 'package:battery_reader/widgets.dart';
import 'package:battery_reader/write_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_57_test.dart' show pumpFor, pumpThroughTransition, scrollTo;
import 'fakes.dart';

// BAL_STATUS (A8 AC): [chargeState, chgMos, disMos, passive, tempGate, smoke,
// heat] + end B9 21.
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

// Standby known OFF so the #62 standby-off note stays out of these pins
// (standby_62_test.dart covers it).
BatteryConnection conn([String serial = 'JS-A']) =>
    BatteryConnection(transport: FakeTransport())
      ..state.serial = serial
      ..state.sleepModeOn = false;

void main() {
  setUp(() {
    AppLog.instance.clear();
    AppLog.instance.echoToConsole = false;
  });

  group('frame builder: each switch flips ONLY its own byte', () {
    // A base with a mix of on/off gates, so a clobbered byte would be visible.
    const base = GateSnapshot(
      chargeMos: true,
      dischargeMos: true,
      tempControlGate: 1,
      smokeGate: 0,
      heatGate: 1,
      passiveBalancing: true,
    ); // -> [1,1,1,0,1,0,1,0]

    test('Charge OFF -> byte[0] only: C3 1E 00 01 01 00 01 00 01 00 D4 3B', () {
      final f = buildGateControlFrame(
          base: base, action: GateAction.chargeMos, on: false);
      expect(f, [0xC3, 0x1E, 0, 1, 1, 0, 1, 0, 1, 0, 0xD4, 0x3B]);
    });

    test('Output OFF -> byte[1] only: C3 1E 01 00 01 00 01 00 01 00 D4 3B', () {
      final f = buildGateControlFrame(
          base: base, action: GateAction.dischargeMos, on: false);
      expect(f, [0xC3, 0x1E, 1, 0, 1, 0, 1, 0, 1, 0, 0xD4, 0x3B]);
    });

    test('Both OFF -> bytes [0] and [1]: C3 1E 00 00 01 00 01 00 01 00 D4 3B',
        () {
      final f = buildGateControlFrame(
          base: base, action: GateAction.bothMos, on: false);
      expect(f, [0xC3, 0x1E, 0, 0, 1, 0, 1, 0, 1, 0, 0xD4, 0x3B]);
    });

    test('Charge ON / Output ON from a both-off base raise only their byte',
        () {
      const off = GateSnapshot(
          chargeMos: false,
          dischargeMos: false,
          tempControlGate: 1,
          smokeGate: 0,
          heatGate: 0,
          passiveBalancing: false); // -> [0,0,1,0,0,0,0,0]
      expect(
          payload(buildGateControlFrame(
              base: off, action: GateAction.chargeMos, on: true)),
          [1, 0, 1, 0, 0, 0, 0, 0]);
      expect(
          payload(buildGateControlFrame(
              base: off, action: GateAction.dischargeMos, on: true)),
          [0, 1, 1, 0, 0, 0, 0, 0]);
      expect(
          payload(buildGateControlFrame(
              base: off, action: GateAction.bothMos, on: true)),
          [1, 1, 1, 0, 0, 0, 0, 0]);
    });

    test('mosSwitchName / isMosAction', () {
      expect(mosSwitchName(GateAction.chargeMos), 'charge');
      expect(mosSwitchName(GateAction.dischargeMos), 'output');
      expect(mosSwitchName(GateAction.bothMos), 'charge + output');
      expect(mosSwitchName(GateAction.restart), 'restart');
      expect(isMosAction(GateAction.chargeMos), isTrue);
      expect(isMosAction(GateAction.dischargeMos), isTrue);
      expect(isMosAction(GateAction.bothMos), isTrue);
      expect(isMosAction(GateAction.heatGate), isFalse);
      expect(isMosAction(GateAction.restart), isFalse);
      expect(GateAction.values.map((a) => a.name), isNot(contains('output')),
          reason: 'the ambiguous both-bytes "output" action is gone');
    });
  });

  group('per-switch state', () {
    test('isChargeOn / isOutputOn / areBothOn read their own byte', () {
      final c = conn();
      expect(c.isChargeOn, isFalse);
      expect(c.isOutputOn, isFalse);
      c.state
        ..chargeMos = true
        ..dischargeMos = false;
      expect(c.isChargeOn, isTrue);
      expect(c.isOutputOn, isFalse);
      expect(c.areBothOn, isFalse);
      expect(c.mosState(GateAction.chargeMos), isTrue);
      expect(c.mosState(GateAction.dischargeMos), isFalse);
      expect(c.mosState(GateAction.bothMos), isFalse);
      c.state.dischargeMos = true;
      expect(c.areBothOn, isTrue);
      expect(c.mosState(GateAction.bothMos), isTrue);
      expect(c.mosState(GateAction.heatGate), isNull);
      expect(conn().mosState(GateAction.bothMos), isNull);
    });
  });

  group('safe write (#59) per switch: only the OWN byte is forced', () {
    test('Charge ON with a STALE base (charge off, output off): byte[0]=1, '
        'byte[1] stays the last-known 0', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 0, disMos: 0, heat: 1, passive: 1));
      clock = clock.add(const Duration(minutes: 2));
      expect(c.gateControlsDisabledReason, isNotNull);
      expect(c.disabledReasonFor(GateAction.chargeMos, on: true), isNull);
      await c.sendGateControl(GateAction.chargeMos, on: true);
      expect(payload(t.gateWrites.single), [1, 0, 1, 0, 1, 0, 1, 0]);
      expect(c.safeWriteMosText(GateAction.chargeMos),
          'charge ON (charge MOS byte = 1); the output switch keeps its '
          'last-known value (OFF)');
      final log = AppLog.instance.entries.map((e) => e.message).join('\n');
      expect(log, contains('safe write charge on JS-A'));
      expect(log, contains('charge MOS byte = 1'));
    });

    test('Output ON with a STALE base (charge on, output off): byte[1]=1, '
        'byte[0] stays the last-known 1', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 1, disMos: 0));
      clock = clock.add(const Duration(minutes: 2));
      await c.sendGateControl(GateAction.dischargeMos, on: true);
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 0, 0, 0]);
      expect(c.safeWriteMosText(GateAction.dischargeMos),
          'output ON (discharge MOS byte = 1); the charge switch keeps its '
          'last-known value (ON)');
    });

    test('Output ON with a STALE base where charge is OFF does NOT switch '
        'charge on', () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 0, disMos: 0));
      clock = clock.add(const Duration(seconds: 30));
      await c.sendGateControl(GateAction.dischargeMos, on: true);
      expect(payload(t.gateWrites.single).sublist(0, 2), [0, 1]);
    });

    test('with NO status ever: own byte = 1, the never-reported other switch '
        'is written ON (the only direction that cannot cut) and the note '
        'says so', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      await c.sendGateControl(GateAction.chargeMos, on: true);
      expect(payload(t.gateWrites.single), [1, 1, 1, 0, 0, 0, 0, 0]);
      expect(c.safeWriteMosText(GateAction.chargeMos),
          'charge ON (charge MOS byte = 1) and, with no output state ever '
          'received from this battery, output ON too');
      expect(chargeAction(c, target: true).message,
          contains('with no output state ever received'));
      expect(chargeAction(c, target: true).message, contains('safe defaults'));
    });

    test('Both ON and Restart force both bytes (the #59 rule unchanged)',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 0, disMos: 0));
      clock = clock.add(const Duration(minutes: 1));
      await c.sendGateControl(GateAction.bothMos, on: true);
      expect(payload(t.gateWrites.last), [1, 1, 1, 0, 0, 0, 0, 0]);
      await c.sendGateControl(GateAction.restart);
      expect(payload(t.gateWrites.last), [1, 1, 1, 0, 0, 1, 0, 0]);
      expect(c.safeWriteMosText(GateAction.bothMos),
          'charge and output ON (both MOS bytes = 1)');
      expect(c.safeWriteMosText(GateAction.restart),
          'charge and output ON (both MOS bytes = 1)');
    });

    test('isSafeWrite: any switch ON + restart; never a switch OFF', () {
      for (final a in [
        GateAction.chargeMos,
        GateAction.dischargeMos,
        GateAction.bothMos
      ]) {
        expect(BatteryConnection.isSafeWrite(a, on: true), isTrue);
        expect(BatteryConnection.isSafeWrite(a, on: false), isFalse);
      }
      expect(BatteryConnection.isSafeWrite(GateAction.restart, on: false),
          isTrue);
      expect(BatteryConnection.isSafeWrite(GateAction.passiveBalance, on: true),
          isFalse);
      expect(BatteryConnection.isSafeWrite(GateAction.factory, on: true),
          isFalse);
    });
  });

  group('safety gate (C1): a switch OFF is refused without a fresh status', () {
    test('no status yet: Charge OFF / Output OFF / Both OFF all refused, '
        'nothing written', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      for (final a in [
        GateAction.chargeMos,
        GateAction.dischargeMos,
        GateAction.bothMos
      ]) {
        expect(c.disabledReasonFor(a, on: false),
            BatteryConnection.reasonNoGateStatus);
        expect(c.disabledReasonFor(a, on: true), isNull);
        await expectLater(
            c.sendGateControl(a, on: false), throwsA(isA<StateError>()));
      }
      expect(t.gateWrites, isEmpty);
      final log = AppLog.instance.entries.map((e) => e.message).join('\n');
      expect(log, contains('refused gate write charge on JS-A'));
      expect(log, contains('refused gate write output on JS-A'));
      expect(log, contains('refused gate write charge + output on JS-A'));
    });

    test('stale status: refused; fresh: allowed and built from the live base',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(heat: 1));
      clock = clock.add(const Duration(seconds: 20));
      await expectLater(c.sendGateControl(GateAction.chargeMos, on: false),
          throwsA(isA<StateError>()));
      await expectLater(c.sendGateControl(GateAction.dischargeMos, on: false),
          throwsA(isA<StateError>()));
      expect(t.gateWrites, isEmpty);
      c.parser.addBytes(bal(heat: 1));
      await c.sendGateControl(GateAction.chargeMos, on: false);
      expect(payload(t.gateWrites.last), [0, 1, 1, 0, 1, 0, 0, 0]);
      await c.sendGateControl(GateAction.dischargeMos, on: false);
      expect(payload(t.gateWrites.last), [1, 0, 1, 0, 1, 0, 0, 0]);
    });

    test('the refusal names the switch, never just "MOS"', () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.connectTo('dev-1', name: 'JS-A');
      Object? err;
      try {
        await c.sendGateControl(GateAction.chargeMos, on: false);
      } catch (e) {
        err = e;
      }
      final msg = writeFailureReason(err!);
      expect(msg, startsWith('Refusing gate write charge:'));
      expect(msg, contains('stop charging'));
      expect(msg, isNot(contains('chargeMos')));
    });

    test('not connected: every switch write refused', () async {
      final c = conn();
      for (final a in [GateAction.chargeMos, GateAction.dischargeMos]) {
        for (final on in [true, false]) {
          expect(c.disabledReasonFor(a, on: on),
              BatteryConnection.reasonNotConnected);
          await expectLater(
              c.sendGateControl(a, on: on), throwsA(isA<StateError>()));
        }
      }
    });
  });

  group('read-back per switch', () {
    test('confirmMosState(charge) completes on the charge byte alone',
        () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 1, disMos: 1));
      final f = c.confirmMosState(GateAction.chargeMos, false,
          timeout: const Duration(seconds: 2));
      // Output going off does NOT satisfy a charge read-back.
      c.parser.addBytes(bal(chgMos: 1, disMos: 0));
      await Future<void>.delayed(Duration.zero);
      c.parser.addBytes(bal(chgMos: 0, disMos: 0));
      expect(await f, isTrue);
    });

    test('confirmMosState(output) ignores the charge byte', () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 1, disMos: 1));
      final f = c.confirmMosState(GateAction.dischargeMos, false,
          timeout: const Duration(seconds: 2));
      c.parser.addBytes(bal(chgMos: 1, disMos: 0)); // charge still on: fine
      expect(await f, isTrue);
    });

    test('confirmMosState(both) needs BOTH bytes; times out on one', () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal(chgMos: 1, disMos: 1));
      final f = c.confirmMosState(GateAction.bothMos, false,
          timeout: const Duration(milliseconds: 300));
      c.parser.addBytes(bal(chgMos: 0, disMos: 1));
      expect(await f, isFalse);
    });
  });

  group('demo battery acks per switch', () {
    test('handleWrite honours byte[0] and byte[1] separately', () {
      final frames = <List<int>>[];
      final d = DemoBattery(frames.add, mode: DemoMode.idle, ackLatency: Duration.zero);
      expect(d.chargeMos, isTrue);
      expect(d.dischargeMos, isTrue);
      const base = GateSnapshot(
          chargeMos: true,
          dischargeMos: true,
          tempControlGate: 1,
          smokeGate: 0,
          heatGate: 0,
          passiveBalancing: false);
      d.handleWrite(buildGateControlFrame(
          base: base, action: GateAction.chargeMos, on: false));
      expect(d.chargeMos, isFalse);
      expect(d.dischargeMos, isTrue);
      d.handleWrite(buildGateControlFrame(
          base: const GateSnapshot(
              chargeMos: false,
              dischargeMos: true,
              tempControlGate: 1),
          action: GateAction.dischargeMos,
          on: false));
      expect(d.chargeMos, isFalse);
      expect(d.dischargeMos, isFalse);
      d.handleWrite(buildGateControlFrame(
          base: const GateSnapshot(tempControlGate: 1),
          action: GateAction.dischargeMos,
          on: true));
      expect(d.chargeMos, isFalse, reason: 'output ON must not touch charge');
      expect(d.dischargeMos, isTrue);
    });

    test('a per-switch write on a demo row is acked and read back per switch',
        () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.startDemo(startSoc: 50, mode: DemoMode.idle, serial: 'JS-DEMO');
      expect(c.isChargeOn, isTrue);
      expect(c.isOutputOn, isTrue);
      await c.sendGateControl(GateAction.chargeMos, on: false);
      expect(
          await c.confirmMosState(GateAction.chargeMos, false,
              timeout: const Duration(seconds: 2)),
          isTrue);
      expect(c.isChargeOn, isFalse);
      expect(c.isOutputOn, isTrue, reason: 'output untouched');
      expect(c.state.gateAck.take(2), [false, true], reason: 'GATE_SET echo');
      await c.sendGateControl(GateAction.dischargeMos, on: false);
      expect(
          await c.confirmMosState(GateAction.dischargeMos, false,
              timeout: const Duration(seconds: 2)),
          isTrue);
      expect(c.isChargeOn, isFalse);
      expect(c.isOutputOn, isFalse);
      expect(c.state.mosOn, isFalse);
      await c.sendGateControl(GateAction.chargeMos, on: true);
      expect(
          await c.confirmMosState(GateAction.chargeMos, true,
              timeout: const Duration(seconds: 2)),
          isTrue);
      expect(c.isChargeOn, isTrue);
      expect(c.isOutputOn, isFalse, reason: 'charge ON must not raise output');
      await c.sendGateControl(GateAction.bothMos, on: true);
      expect(
          await c.confirmMosState(GateAction.bothMos, true,
              timeout: const Duration(seconds: 2)),
          isTrue);
      expect(c.state.mosOn, isTrue);
      await c.dispose();
    });
  });

  group('dialog / double-confirm texts (pinned)', () {
    test('Charge OFF: two-step, names the switch and the serial', () {
      final c = conn();
      c.state
        ..chargeMos = true
        ..dischargeMos = false;
      final a = chargeAction(c, target: false);
      expect(a.dangerous, isTrue);
      expect(a.busyKey, 'charge');
      expect(a.title, 'Turn charge OFF');
      expect(a.message, 'Turn the charge switch (charge MOS) OFF on JS-A?');
      expect(a.sternWarning,
          'This stops JS-A charging — no current can flow into the pack '
          'until charge is turned back on.');
      expect(a.confirmLabel, 'Turn charge OFF');
      expect(a.label, 'charge OFF');
      expect(a.sentToast(), 'Sent: charge OFF to JS-A');
      expect(a.warnTitle, 'Charge not confirmed');
      expect(a.warnMessage!(),
          'Command sent, but JS-A still reports charge ON. The change may '
          'not have taken effect — check the connection and try again.');
    });

    test('Charge ON: single confirm', () {
      final a = chargeAction(conn(), target: true);
      expect(a.dangerous, isFalse);
      expect(a.title, 'Turn charge on');
      expect(a.message, 'Turn the charge switch (charge MOS) ON on JS-A?');
      expect(a.confirmLabel, 'Turn ON');
      expect(a.label, 'charge ON');
      expect(a.sentToast(), 'Sent: charge ON to JS-A');
    });

    test('Both OFF / ON', () {
      final c = conn();
      c.state
        ..chargeMos = true
        ..dischargeMos = false;
      final off = bothMosAction(c, target: false);
      expect(off.dangerous, isTrue);
      expect(off.busyKey, 'charge + output');
      expect(off.title, 'Turn both OFF');
      expect(off.message,
          'Turn both switches (charge + output) OFF on JS-A?');
      expect(off.sternWarning,
          "This cuts JS-A's output — anything powered by it will lose power "
          '— and it will stop charging.');
      expect(off.confirmLabel, 'Turn both OFF');
      expect(off.label, 'charge + output OFF');
      expect(off.sentToast(), 'Sent: charge + output OFF to JS-A');
      expect(off.warnTitle, 'Switches not confirmed');
      expect(off.warnMessage!(),
          'Command sent, but JS-A still reports charge ON, output OFF. The '
          'change may not have taken effect — check the connection and try '
          'again.');
      final on = bothMosAction(c, target: true);
      expect(on.dangerous, isFalse);
      expect(on.title, 'Turn both on');
      expect(on.confirmLabel, 'Turn ON');
    });

    test('nothing user-facing says just "MOS"', () {
      final c = conn();
      c.state
        ..chargeMos = true
        ..dischargeMos = true;
      final texts = <String>[];
      for (final a in [
        chargeAction(c, target: false),
        chargeAction(c, target: true),
        outputAction(c, target: false),
        outputAction(c, target: true),
        bothMosAction(c, target: false),
        bothMosAction(c, target: true),
      ]) {
        texts.addAll([
          a.title,
          a.message,
          a.confirmLabel,
          a.label,
          a.sentToast() ?? '',
          a.sternWarning ?? '',
          a.warnTitle ?? '',
          a.warnMessage?.call() ?? '',
        ]);
      }
      texts.addAll([
        mosSwitchLabel(GateAction.chargeMos),
        mosSwitchLabel(GateAction.dischargeMos),
        mosSwitchLabel(GateAction.bothMos),
        c.gateStatusSummary(),
        controlsUnavailableText('x', safeWritesAvailable: true),
      ]);
      // "charge MOS" / "discharge MOS" as a parenthetical is fine; a bare
      // "MOS" label ("MOS", "MOS ON", "Charge MOS") is not.
      final bare = RegExp(r'(^|[^a-z ])MOS\b|\bMOS (ON|OFF)\b|Charge MOS\b|Discharge MOS\b');
      for (final t in texts) {
        expect(t, isNot(matches(bare)), reason: t);
      }
      expect(mosSwitchLabel(GateAction.chargeMos), 'Charge');
      expect(mosSwitchLabel(GateAction.dischargeMos), 'Output');
      expect(mosSwitchLabel(GateAction.bothMos), 'Both');
    });
  });

  group('fleet: per-switch writes and counts', () {
    Future<(BatteryManager, FakeTransport, FakeTransport)> fleet(
        {bool fresh = true}) async {
      final tA = FakeTransport(), tB = FakeTransport();
      final a = BatteryConnection(transport: tA);
      final b = BatteryConnection(transport: tB);
      await a.connectTo('dev-a', name: 'JS-A');
      await b.connectTo('dev-b', name: 'JS-B');
      if (fresh) {
        a.parser.addBytes(bal(chgMos: 1, disMos: 1));
        b.parser.addBytes(bal(chgMos: 1, disMos: 0));
      }
      // Standby known OFF (the #62 path is covered in standby_62_test.dart).
      a.state.sleepModeOn = false;
      b.state.sleepModeOn = false;
      final m = BatteryManager()..batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      return (m, tA, tB);
    }

    test('fleetSetMos(charge, off) writes byte[0]=0 on every member, output '
        'kept per member', () async {
      final (m, tA, tB) = await fleet();
      expect(m.fleetChargeOnCount, 2);
      expect(m.fleetOutputOnCount, 1);
      final r = await m.fleetSetMos(GateAction.chargeMos, on: false);
      expect(r.allOk, isTrue);
      expect(payload(tA.gateWrites.single).sublist(0, 2), [0, 1]);
      expect(payload(tB.gateWrites.single).sublist(0, 2), [0, 0]);
    });

    test('fleetSetMos(output, on) raises byte[1] only', () async {
      final (m, tA, tB) = await fleet();
      await m.fleetSetMos(GateAction.dischargeMos, on: true);
      expect(payload(tA.gateWrites.single).sublist(0, 2), [1, 1]);
      expect(payload(tB.gateWrites.single).sublist(0, 2), [1, 1]);
    });

    test('OFF refused before ANY member is written without a fresh base; '
        'ON goes out on the safe base', () async {
      final (m, tA, tB) = await fleet(fresh: false);
      for (final a in [
        GateAction.chargeMos,
        GateAction.dischargeMos,
        GateAction.bothMos
      ]) {
        expect(m.fleetMosWriteDisabledReason(a, on: false),
            contains('Waiting for gate status'));
        expect(m.fleetMosWriteDisabledReason(a, on: true), isNull);
        await expectLater(
            m.fleetSetMos(a, on: false), throwsA(isA<StateError>()));
      }
      expect(tA.gateWrites, isEmpty);
      expect(tB.gateWrites, isEmpty);
      final r = await m.fleetSetMos(GateAction.chargeMos, on: true);
      expect(r.allOk, isTrue);
      expect(payload(tA.gateWrites.single), [1, 1, 1, 0, 0, 0, 0, 0]);
      expect(m.fleetGateWriteDisabledReason, isNotNull);
    });

    test('fleetSetMos rejects a non-switch action', () async {
      final (m, _, _) = await fleet();
      await expectLater(m.fleetSetMos(GateAction.heatGate, on: true),
          throwsA(isA<ArgumentError>()));
    });

    test('fleet dialog texts: charge / both (pinned)', () async {
      final (m, _, _) = await fleet();
      final off = fleetChargeAction(m, on: false);
      expect(off.busyKey, 'fleet charge');
      expect(off.title, 'ALL charge OFF');
      expect(off.message,
          'Turn the charge switch (charge MOS) OFF on all 2 batteries in '
          'the fleet?\n\n • JS-A\n • JS-B');
      expect(off.sternWarning,
          'This will stop charging on every fleet battery (JS-A, JS-B); no '
          'current can flow into them until charge is turned back on.\n\n'
          '$parallelBankWarning'); // #62: two members = a parallel bank
      expect(off.confirmLabel, 'Turn ALL charge OFF');
      expect(off.label, 'fleet charge OFF');
      final on = fleetChargeAction(m, on: true);
      expect(on.title, 'All charge ON');
      expect(on.dangerous, isFalse);
      final both = fleetBothMosAction(m, on: false);
      expect(both.busyKey, 'fleet charge + output');
      expect(both.title, 'ALL switches OFF');
      expect(both.message,
          'Turn both switches (charge + output) OFF on all 2 batteries in '
          'the fleet?\n\n • JS-A\n • JS-B');
      expect(both.sternWarning,
          'This will cut output to every fleet battery (JS-A, JS-B) — '
          'anything powered by them will lose power — and stop them charging.'
          '\n\n$parallelBankWarning'); // #62: two members = a parallel bank
      expect(both.confirmLabel, 'Turn ALL switches OFF');
      expect(fleetBothMosAction(m, on: true).title, 'All switches ON');
      await both.send();
      expect(both.sentToast(), 'Sent: charge + output OFF to 2 batteries');
      final chg = fleetChargeAction(m, on: true);
      await chg.send();
      expect(chg.sentToast(), 'Sent: charge ON to 2 batteries');
    });
  });

  group('UI: two states everywhere, two controls plus Both', () {
    Widget app(Widget home) => MaterialApp(
          navigatorKey: gNavKey,
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          home: home,
        );

    testWidgets('list cards show a Charge badge and an Output badge each',
        (tester) async {
      SharedPreferences.setMockInitialValues({'demo_mode_v1': true});
      await tester.pumpWidget(const BatteryReaderApp());
      await pumpFor(tester, const Duration(seconds: 3));
      final badges = tester.widgetList<SwitchBadge>(find.byType(SwitchBadge));
      expect(badges.where((b) => b.label == 'Charge'), isNotEmpty);
      expect(badges.where((b) => b.label == 'Output'), isNotEmpty);
      // The charging demo pack (JS-2C14AA) reports output OFF, charge ON.
      expect(find.text('Charge on'), findsWidgets);
      expect(find.text('Output off'), findsWidgets);
      // The fleet panel counts each switch once a pack is in the fleet.
      expect(find.textContaining('Charge 1/1 on'), findsNothing);
      await tester.tap(find.byIcon(Icons.star_border).first);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.textContaining(RegExp(r'Charge 1/1 on  ·  Output [01]/1 on')),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
        'detail page: header badges, Gates & status rows, two controls + Both, '
        'Charge OFF double-confirms and is acked per switch', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      manager.startDemoFleet();
      final aliases = AliasStore(prefs: SharedPreferences.getInstance);
      // The idle demo pack: both switches on.
      final conn = manager.batteries
          .firstWhere((b) => b.isChargeOn && b.isOutputOn);
      await tester.pumpWidget(app(
          BatteryDetailPage(conn: conn, manager: manager, aliases: aliases)));
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.text('Charge on'), findsOneWidget);
      expect(find.text('Output on'), findsOneWidget);
      // Gates & status rows (lazily built: scroll them into view first).
      await scrollTo(tester, find.text('Charge switch'));
      expect(find.text('Output switch'), findsOneWidget);
      expect(find.text('Both switches'), findsWidgets);
      expect(find.text('Charge (charge MOS)'), findsOneWidget);
      expect(find.text('Output (discharge MOS)'), findsOneWidget);
      expect(find.text('Turn charge OFF'), findsOneWidget);
      expect(find.text('Turn output OFF'), findsOneWidget);
      expect(find.text('Both OFF'), findsOneWidget);
      expect(find.text('Both ON'), findsOneWidget);
      expect(find.textContaining('MOS ON'), findsNothing);

      final btn = find.widgetWithText(FilledButton, 'Turn charge OFF');
      await scrollTo(tester, btn);
      await tester.tap(btn);
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(find.text('Turn the charge switch (charge MOS) OFF on ${conn.state.serial}?'),
          findsOneWidget);
      await tester.tap(find.text('Continue…'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(find.text('Are you sure?'), findsOneWidget);
      expect(find.textContaining('stops ${conn.state.serial} charging'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Turn charge OFF').last);
      await pumpFor(tester, const Duration(seconds: 3));
      expect(conn.isChargeOn, isFalse);
      expect(conn.isOutputOn, isTrue, reason: 'the output switch is untouched');
      expect(find.text('Turn charge ON'), findsOneWidget);
      expect(find.text('Turn output OFF'), findsOneWidget);
      // The header badges (scrolled out of the lazy list: scroll back up).
      await tester.scrollUntilVisible(find.text('Charge off'), -200,
          scrollable: find.byType(Scrollable).first);
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(find.text('Charge off'), findsOneWidget);
      expect(find.text('Output on'), findsOneWidget);
      // Turning it back on: single confirm, acked.
      final on = find.widgetWithText(FilledButton, 'Turn charge ON');
      await scrollTo(tester, on);
      await tester.tap(on);
      await pumpFor(tester, const Duration(milliseconds: 500));
      await tester.tap(find.widgetWithText(FilledButton, 'Turn ON'));
      await pumpFor(tester, const Duration(seconds: 3));
      expect(conn.isChargeOn, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      await pumpThroughTransition(tester);
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets('fleet controls: All charge / All output / All switches pairs',
        (tester) async {
      SharedPreferences.setMockInitialValues({'demo_mode_v1': true});
      await tester.pumpWidget(const BatteryReaderApp());
      await pumpFor(tester, const Duration(seconds: 3));
      for (final t in [
        'All charge OFF',
        'All charge ON',
        'All output OFF',
        'All output ON',
        'All switches OFF',
        'All switches ON',
      ]) {
        await scrollTo(tester, find.text(t));
        expect(find.text(t), findsOneWidget, reason: t);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
