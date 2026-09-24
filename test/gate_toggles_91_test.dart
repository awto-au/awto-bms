/// #91: the low-temp protection (CMD_GATE_CONTROL byte[2]) and smoke sensor
/// (byte[3]) toggles in the shared Controls section.
///
///  * each write re-sends all eight gate bytes from the FRESH base and flips
///    ONLY its own byte;
///  * ON and OFF are refused (nothing sent) without a fresh base — not
///    connected, no BAL_STATUS on this link, or one older than 15 s;
///  * OFF double-confirms with a plain "this DISABLES …" page; ON is a single
///    confirm; no standby-off is sent (neither gate cuts current);
///  * read-back against the next BAL_STATUS, with the "not confirmed" warning;
///  * disabled reasons in the UI; the Firmware update stays last;
///  * Gates & status shows them as On / Off.
library;

import 'dart:async';

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/metrics.dart';
import 'package:battery_reader/sections/controls_section.dart';
import 'package:battery_reader/write_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// BAL_STATUS (A8 AC): [chargeState, chgMos, disMos, passive, tempGate, smoke,
// heat] + end B9 21.
List<int> bal({
  int chgMos = 1,
  int disMos = 1,
  int passive = 1,
  int tempGate = 1,
  int smoke = 0,
  int heat = 1,
}) =>
    [
      0xA8,
      0xAC,
      0x01,
      chgMos,
      disMos,
      passive,
      tempGate,
      smoke,
      heat,
      0xB9,
      0x21
    ];

List<int> payload(List<int> frame) => frame.sublist(2, frame.length - 2);

/// A connected pack with standby known OFF and a fresh BAL_STATUS [base].
Future<(BatteryConnection, FakeTransport)> fresh(List<int> base,
    {DateTime Function()? now}) async {
  final t = FakeTransport();
  final c = BatteryConnection(transport: t, now: now ?? DateTime.now);
  await c.connectTo('dev-1', name: 'JS-91');
  c.state.sleepModeOn = false;
  c.parser.addBytes(base);
  return (c, t);
}

Widget _app(Widget home) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.5)),
        child: child!,
      ),
      home: home,
    );

Finder _rowButton(String label) => find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
    matching: find.byType(FilledButton));

void main() {
  setUp(() {
    AppLog.instance.clear();
    AppLog.instance.echoToConsole = false;
  });

  group('frames: each toggle flips ONLY its own byte of the fresh base', () {
    // Base payload [1,1,1,0,1,0,1,0]: chg, dis, temp ON, smoke OFF, heat ON,
    // passive ON — a clobbered byte would show.
    const base = [1, 1, 1, 0, 1, 0, 1, 0];

    Future<List<int>> sent(WriteAction Function(BatteryConnection) a,
        {List<int>? frame}) async {
      final (c, t) = await fresh(frame ?? bal());
      final before = t.writes.length;
      await a(c).send();
      expect(t.writes.length, before + 1,
          reason: 'one frame only — no standby-off, no extra write');
      return t.gateWrites.single;
    }

    test('low-temp protection OFF: C3 1E 01 01 00 00 01 00 01 00 D4 3B',
        () async {
      final f = await sent((c) => lowTempProtectionAction(c, target: false));
      expect(f, [0xC3, 0x1E, 1, 1, 0, 0, 1, 0, 1, 0, 0xD4, 0x3B]);
      expect(_diff(base, payload(f)), [GateControl.iTempControlGate]);
    });

    test('low-temp protection ON from a temp-off base raises only byte[2]',
        () async {
      final f = await sent((c) => lowTempProtectionAction(c, target: true),
          frame: bal(tempGate: 0));
      expect(f, [0xC3, 0x1E, 1, 1, 1, 0, 1, 0, 1, 0, 0xD4, 0x3B]);
      expect(_diff([1, 1, 0, 0, 1, 0, 1, 0], payload(f)),
          [GateControl.iTempControlGate]);
    });

    test('smoke sensor ON: C3 1E 01 01 01 01 01 00 01 00 D4 3B', () async {
      final f = await sent((c) => smokeSensorAction(c, target: true));
      expect(f, [0xC3, 0x1E, 1, 1, 1, 1, 1, 0, 1, 0, 0xD4, 0x3B]);
      expect(_diff(base, payload(f)), [GateControl.iSmokeGate]);
    });

    test('smoke sensor OFF from a smoke-on base lowers only byte[3]', () async {
      final f = await sent((c) => smokeSensorAction(c, target: false),
          frame: bal(smoke: 1));
      expect(f, [0xC3, 0x1E, 1, 1, 1, 0, 1, 0, 1, 0, 0xD4, 0x3B]);
      expect(_diff([1, 1, 1, 1, 1, 0, 1, 0], payload(f)),
          [GateControl.iSmokeGate]);
    });

    test('a switches-off base is carried, never forced on', () async {
      final f = await sent((c) => lowTempProtectionAction(c, target: false),
          frame: bal(chgMos: 0, disMos: 0, passive: 0, heat: 0));
      expect(payload(f), [0, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('OFF with standby ON/unknown sends NO standby-off first', () async {
      final (c, t) = await fresh(bal());
      c.state.sleepModeOn = null;
      final before = t.writes.length;
      await lowTempProtectionAction(c, target: false).send();
      await smokeSensorAction(c, target: true).send();
      expect(t.writes.length, before + 2);
      expect(t.gateWrites.length, 2);
    });
  });

  group('refused without a fresh gate base (nothing sent)', () {
    for (final (name, make)
        in <(String, WriteAction Function(BatteryConnection))>[
      ('low-temp OFF', (c) => lowTempProtectionAction(c, target: false)),
      ('low-temp ON', (c) => lowTempProtectionAction(c, target: true)),
      ('smoke OFF', (c) => smokeSensorAction(c, target: false)),
      ('smoke ON', (c) => smokeSensorAction(c, target: true)),
    ]) {
      test('$name: not connected', () async {
        final t = FakeTransport();
        final c = BatteryConnection(transport: t)..state.serial = 'JS-91';
        await expectLater(make(c).send(), throwsA(isA<StateError>()));
        expect(t.writes, isEmpty);
      });

      test('$name: connected, no BAL_STATUS on this link', () async {
        final t = FakeTransport();
        final c = BatteryConnection(transport: t);
        await c.connectTo('dev-1', name: 'JS-91');
        // Last-known gates from an earlier link do not count.
        c.state
          ..chargeMos = true
          ..dischargeMos = true
          ..tempControlGate = 1
          ..smokeGate = 0
          ..heatGate = 0
          ..passiveBalancing = false;
        await expectLater(make(c).send(), throwsA(isA<StateError>()));
        expect(t.gateWrites, isEmpty);
      });

      test('$name: BAL_STATUS older than 15 s', () async {
        var clock = DateTime.utc(2026, 9, 24, 12);
        final (c, t) = await fresh(bal(), now: () => clock);
        clock = clock.add(const Duration(milliseconds: 15001));
        // Other telemetry keeps flowing; only BAL_STATUS stalled.
        c.parser.addBytes(const [
          0xA0, 0xC1, 0x04, 0x05, 0x0d, 0x08, 0x0d, 0x07, 0x0d, 0x05, 0x0d, //
          0xB1, 0xD2
        ]);
        expect(c.hasFreshGateState, isFalse);
        await expectLater(make(c).send(), throwsA(isA<StateError>()));
        expect(t.gateWrites, isEmpty);
      });
    }
  });

  group('confirm texts', () {
    BatteryConnection conn() => BatteryConnection(transport: FakeTransport())
      ..state.serial = 'JS-91'
      ..state.sleepModeOn = false;

    test('low-temp OFF double-confirms and says it disables protection', () {
      final a = lowTempProtectionAction(conn(), target: false);
      expect(a.dangerous, isTrue);
      expect(a.busyKey, 'low-temp protection');
      expect(a.title, 'Turn Low-temp protection OFF');
      expect(a.message, 'Turn Low-temp protection OFF on JS-91?');
      expect(
          a.sternWarning,
          'This DISABLES low-temperature protection on JS-91. The BMS will '
          'no longer stop charging when the cells are too cold, and charging '
          'lithium cells below freezing can permanently damage them. Only '
          'turn it off if you are certain.');
      expect(a.confirmLabel, 'Turn Low-temp protection OFF');
      expect(a.label, 'low-temp protection OFF');
      expect(a.sentToast(), 'Sent: Low-temp protection OFF to JS-91');
    });

    test('low-temp ON is a single confirm with the note', () {
      final a = lowTempProtectionAction(conn(), target: true);
      expect(a.dangerous, isFalse);
      expect(a.danger, isFalse);
      expect(a.title, 'Turn Low-temp protection on');
      expect(a.message,
          'Turn Low-temp protection ON on JS-91?\n\n$lowTempEnableNote');
      expect(a.confirmLabel, 'Turn ON');
      expect(a.label, 'low-temp protection ON');
    });

    test('smoke OFF double-confirms; smoke ON is single with the caveat', () {
      final off = smokeSensorAction(conn(), target: false);
      expect(off.dangerous, isTrue);
      expect(off.busyKey, 'smoke sensor');
      expect(off.title, 'Turn Smoke sensor OFF');
      expect(
          off.sternWarning,
          'This DISABLES the smoke sensor on JS-91. The BMS will no longer '
          'act on its smoke-sensor input, so smoke or fire at the pack would '
          'not be detected by the BMS.');
      expect(off.label, 'smoke sensor OFF');
      final on = smokeSensorAction(conn(), target: true);
      expect(on.dangerous, isFalse);
      expect(on.message, 'Turn Smoke sensor ON on JS-91?\n\n$smokeEnableNote');
      expect(on.label, 'smoke sensor ON');
    });

    test('passive balancing / heater keep no read-back (unchanged)', () {
      final a = gateToggleAction(conn(),
          label: 'Heater',
          busyKey: WriteKeys.heater,
          isOn: false,
          action: GateAction.heatGate);
      expect(a.readBack, isNull);
      expect(a.warnTitle, isNull);
    });
  });

  group('read-back', () {
    test('confirmed by the next BAL_STATUS showing the new value', () async {
      final (c, _) = await fresh(bal());
      final a = lowTempProtectionAction(c, target: false);
      expect(a.warnTitle, 'Low-temp protection not confirmed');
      await a.send();
      final done = a.readBack!();
      c.parser.addBytes(bal(tempGate: 0));
      expect(await done, isTrue);
      expect(c.lowTempProtectionOn, isFalse);
    });

    test('a BAL_STATUS still showing the old value -> not confirmed + warning',
        () async {
      final (c, _) = await fresh(bal(smoke: 0));
      final a = smokeSensorAction(c, target: true);
      await a.send();
      final ok = await c.confirmGateState(GateAction.smokeGate, true,
          timeout: const Duration(milliseconds: 50));
      c.parser.addBytes(bal(smoke: 0));
      expect(ok, isFalse);
      expect(a.warnTitle, 'Smoke sensor not confirmed');
      expect(
          a.warnMessage!(),
          'Command sent, but JS-91 still reports Smoke sensor OFF. The change '
          'may not have taken effect — check the connection and try again.');
    });

    test('a different gate changing does not confirm this one', () async {
      final (c, _) = await fresh(bal());
      final done = c.confirmGateState(GateAction.tempControlGate, false,
          timeout: const Duration(milliseconds: 100));
      c.parser.addBytes(bal(smoke: 1)); // smoke moved, temp still 1
      expect(await done, isFalse);
    });

    test('gateState reports unknown as null, never off', () {
      final c = BatteryConnection(transport: FakeTransport());
      expect(c.lowTempProtectionOn, isNull);
      expect(c.smokeSensorOn, isNull);
      c.state
        ..tempControlGate = 1
        ..smokeGate = 0;
      expect(c.lowTempProtectionOn, isTrue);
      expect(c.smokeSensorOn, isFalse);
    });
  });

  group('Controls UI', () {
    Future<void> view(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('disconnected: both rows shown, disabled, reason shown',
        (tester) async {
      await view(tester);
      final c = BatteryConnection(transport: FakeTransport());
      await tester.pumpWidget(_app(Scaffold(
          body: SingleChildScrollView(
              child: ControlsSection(
                  conn: c, busy: BusyWrites(), onChanged: () {})))));
      for (final l in ['Low-temp protection', 'Smoke sensor']) {
        expect(find.text(l), findsOneWidget);
        expect(tester.widget<FilledButton>(_rowButton(l)).onPressed, isNull);
      }
      expect(find.textContaining('Not connected'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'connected without BAL_STATUS: disabled with the gate reason; a '
        'fresh base enables them; a write in flight disables them',
        (tester) async {
      await view(tester);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await tester.runAsync(() => c.connectTo('dev-1', name: 'JS-91'));
      final busy = BusyWrites();
      Widget section() => _app(Scaffold(
          body: SingleChildScrollView(
              child: ControlsSection(conn: c, busy: busy, onChanged: () {}))));
      await tester.pumpWidget(section());
      expect(find.textContaining('Waiting for gate status'), findsOneWidget);
      for (final l in ['Low-temp protection', 'Smoke sensor']) {
        expect(tester.widget<FilledButton>(_rowButton(l)).onPressed, isNull);
      }
      c.parser.addBytes(bal());
      await tester.pumpWidget(section());
      for (final l in ['Low-temp protection', 'Smoke sensor']) {
        expect(tester.widget<FilledButton>(_rowButton(l)).onPressed, isNotNull);
      }
      // State + button text: low-temp On -> "Turn off"; smoke Off -> "Turn on".
      expect(
          find.descendant(
              of: _rowButton('Low-temp protection'),
              matching: find.text('Turn off')),
          findsOneWidget);
      expect(
          find.descendant(
              of: _rowButton('Smoke sensor'), matching: find.text('Turn on')),
          findsOneWidget);
      // Firmware update stays the last control, below the new rows.
      expect(tester.getTopLeft(find.text('Firmware update')).dy,
          greaterThan(tester.getTopLeft(find.text('Smoke sensor')).dy));
      expect(tester.getTopLeft(find.text('Smoke sensor')).dy,
          greaterThan(tester.getTopLeft(find.text('Low-temp protection')).dy));
      final release = Completer<void>();
      final held = busy.run('heater', () {}, () => release.future);
      await tester.pumpWidget(section());
      for (final l in ['Low-temp protection', 'Smoke sensor']) {
        expect(tester.widget<FilledButton>(_rowButton(l)).onPressed, isNull);
      }
      release.complete();
      await held;
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'low-temp OFF: first page, then "Are you sure?" with the plain '
        'warning; cancelling sends nothing; accepting sends only byte[2] '
        'and reads it back', (tester) async {
      await view(tester);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await tester.runAsync(() => c.connectTo('dev-1', name: 'JS-91'));
      c.state.sleepModeOn = false;
      c.parser.addBytes(bal());
      final busy = BusyWrites();
      await tester.pumpWidget(_app(Scaffold(
          body: SingleChildScrollView(
              child: ControlsSection(conn: c, busy: busy, onChanged: () {})))));

      // Cancel on the second page -> nothing sent.
      await tester.tap(_rowButton('Low-temp protection'));
      await tester.pumpAndSettle();
      expect(
          find.text('Turn Low-temp protection OFF on JS-91?'), findsOneWidget);
      await tester.tap(find.text('Continue…'));
      await tester.pumpAndSettle();
      expect(find.text('Are you sure?'), findsOneWidget);
      expect(find.textContaining('DISABLES low-temperature protection'),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.gateWrites, isEmpty);

      // Accept both pages -> one frame, only byte[2] lowered.
      await tester.tap(_rowButton('Low-temp protection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn Low-temp protection OFF'));
      await tester.pump();
      await tester.pump();
      expect(payload(t.gateWrites.single), [1, 1, 0, 0, 1, 0, 1, 0]);
      expect(busy.contains(WriteKeys.lowTemp), isTrue,
          reason: 'held until the read-back completes');
      c.parser.addBytes(bal(tempGate: 0)); // the pack reports it
      await tester.pumpAndSettle();
      expect(busy.any, isFalse);
      expect(find.text('Low-temp protection not confirmed'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('smoke ON: single confirm; no read-back -> warning',
        (tester) async {
      await view(tester);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await tester.runAsync(() => c.connectTo('dev-1', name: 'JS-91'));
      c.parser.addBytes(bal());
      await tester.pumpWidget(_app(Scaffold(
          body: SingleChildScrollView(
              child: ControlsSection(
                  conn: c, busy: BusyWrites(), onChanged: () {})))));
      await tester.tap(_rowButton('Smoke sensor'));
      await tester.pumpAndSettle();
      expect(find.textContaining('has not been verified'), findsOneWidget);
      await tester.tap(find.text('Turn ON'));
      await tester.pump();
      await tester.pump();
      expect(payload(t.gateWrites.single), [1, 1, 1, 1, 1, 0, 1, 0]);
      expect(find.text('Are you sure?'), findsNothing);
      // The pack never reports smoke ON -> the 4 s read-back times out.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Smoke sensor not confirmed'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  test('Gates & status shows the two gates as On / Off, logs 0/1', () {
    final c = BatteryConnection(transport: FakeTransport())
      ..state.tempControlGate = 1
      ..state.smokeGate = 0;
    MetricDef row(String key) => metricTable.firstWhere((m) => m.key == key);
    expect(row(Metric.tempControlGate).format(c), 'On');
    expect(row(Metric.smokeGate).format(c), 'Off');
    expect(row(Metric.tempControlGate).extract!(c), 1);
    expect(row(Metric.smokeGate).extract!(c), 0);
    c.state
      ..tempControlGate = null
      ..smokeGate = null;
    expect(row(Metric.tempControlGate).format(c), '—');
    expect(row(Metric.smokeGate).format(c), '—');
  });
}

/// Indices at which [a] and [b] differ.
List<int> _diff(List<int> a, List<int> b) => [
      for (var i = 0; i < a.length; i++)
        if (a[i] != b[i]) i
    ];
