/// #118: the firmware update is a red action in Controls (like Restart BMS /
/// Factory reset), disabled with its reason; the separate "Advanced" card is
/// gone; the update page goes File -> Checks -> Confirm with no separate
/// warning step, and still needs every check plus the typed serial.
library;

import 'dart:async';
import 'dart:io';

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/app_theme.dart' show kRed;
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_detail.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart' show ChargeState;
import 'package:battery_reader/ota_update.dart';
import 'package:battery_reader/ota_update_page.dart';
import 'package:battery_reader/sections/controls_section.dart';
import 'package:battery_reader/write_actions.dart' show BusyWrites;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

Widget _app(Widget home) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.5)),
        child: child!,
      ),
      home: home,
    );

Future<void> _view(WidgetTester tester, double w, double h) async {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A connected pack that passes every pre-flight check: streaming, SOC 80 %,
/// idle at 0 A, version known, no fault.
Future<(BatteryConnection, FakeTransport)> _readyConn(
    WidgetTester tester) async {
  final transport = FakeTransport();
  final conn = BatteryConnection(transport: transport);
  await tester.runAsync(() => conn.connectTo('dev-1', name: 'dev-1'));
  conn.parser.addBytes(const [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21]);
  conn.state
    ..serial = 'JS-118'
    ..socPercent = 80
    ..remainingAh = 80
    ..fullAh = 100
    ..packVoltage = 53.2
    ..packCurrent = 0
    ..chargeState = ChargeState.idle
    ..firmwareVersion = '1.0.1';
  return (conn, transport);
}

Finder _firmwareButton() => find.ancestor(
    of: find.text('Firmware update'), matching: find.byType(OutlinedButton));

void main() {
  group('#118 Controls: red Firmware update action', () {
    testWidgets('disconnected: red, disabled, reason as the hint',
        (tester) async {
      await _view(tester, 400, 2000);
      final conn = BatteryConnection(transport: FakeTransport());
      await tester.pumpWidget(_app(Scaffold(
          body: SingleChildScrollView(
              child: ControlsSection(
                  conn: conn, busy: BusyWrites(), onChanged: () {})))));
      expect(_firmwareButton(), findsOneWidget);
      final b = tester.widget<OutlinedButton>(_firmwareButton());
      expect(b.onPressed, isNull);
      expect(b.style!.foregroundColor!.resolve({}), kRed);
      expect(find.text('Not connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'connected: enabled, current version as the hint; a write in '
        'flight disables it with the reason', (tester) async {
      await _view(tester, 400, 2000);
      final (conn, _) = await _readyConn(tester);
      final busy = BusyWrites();
      Widget section() => _app(Scaffold(
          body: SingleChildScrollView(
              child:
                  ControlsSection(conn: conn, busy: busy, onChanged: () {}))));
      await tester.pumpWidget(section());
      expect(tester.widget<OutlinedButton>(_firmwareButton()).onPressed,
          isNotNull);
      expect(find.text('Current 1.0.1'), findsOneWidget);
      expect(firmwareUpdateDisabledReason(conn, busy), isNull);

      conn.state.serial = '';
      expect(firmwareUpdateDisabledReason(conn, busy), 'Serial unknown');
      conn.state.serial = 'JS-118';

      final release = Completer<void>();
      final held = busy.run('restart', () {}, () => release.future);
      await tester.pumpWidget(section());
      expect(
          tester.widget<OutlinedButton>(_firmwareButton()).onPressed, isNull);
      expect(find.text('Write in progress (restart)'), findsOneWidget);
      release.complete();
      await held;
      expect(tester.takeException(), isNull);
    });
  });

  group('#118 no Advanced card', () {
    test('the AdvancedSection source is gone', () {
      expect(File('lib/sections/advanced_section.dart').existsSync(), isFalse);
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        expect(f.readAsStringSync().contains('AdvancedSection'), isFalse,
            reason: f.path);
      }
    });

    for (final arrangement in DetailArrangement.values) {
      testWidgets(
          '${arrangement.name}: no "Advanced" card; the firmware '
          'action sits inside Controls', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await _view(
            tester, arrangement == DetailArrangement.grid ? 1280 : 400, 6000);
        final (conn, _) = await _readyConn(tester);
        final manager = BatteryManager(
            transport: NoopTransport(), fleetStore: FakeFleetStore());
        manager.batteries.add(conn);
        bool awake() => true;
        await tester.pumpWidget(_app(Scaffold(
            body: BatteryDetailView(
                conn: conn,
                manager: manager,
                aliases: AliasStore(prefs: SharedPreferences.getInstance),
                keepAwake: awake,
                arrangement: arrangement,
                dense: arrangement == DetailArrangement.grid))));
        await tester.pump();
        await tester.pump();
        expect(find.text('Advanced'), findsNothing);
        expect(
            find.descendant(
                of: find.byType(ControlsSection), matching: _firmwareButton()),
            findsOneWidget);
        expect(
            tester
                .widget<ControlsSection>(find.byType(ControlsSection))
                .keepAwake,
            same(awake));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('#118 update flow: checks + typed confirmation, no warning step', () {
    testWidgets(
        'File -> Checks -> Confirm; the confirm step carries the risk '
        'line and needs the typed serial', (tester) async {
      await _view(tester, 400, 3000);
      final (conn, transport) = await _readyConn(tester);
      final written = transport.writes.length;
      var awake = false;
      await tester.pumpWidget(_app(FirmwareUpdatePage(
        conn: conn,
        busy: BusyWrites(),
        keepAwake: () => awake,
        keepAwakeDetail: () => '',
        pickImage: () async =>
            OtaImage(name: 'PB51250506.bin', bytes: List.filled(400, 7)),
      )));

      // The step chips: no "Warning".
      final chips = [
        for (final c in tester.widgetList<Chip>(find.byType(Chip)))
          (c.label as Text).data,
      ];
      expect(chips, ['File', 'Checks', 'Confirm', 'Flash', 'Result']);

      await tester.tap(find.text('Choose .bin file'));
      await tester.pump();
      await tester.tap(find.text('Continue to pre-flight checks'));
      await tester.pump();
      expect(find.text('2. Pre-flight checks (all must pass)'), findsOneWidget);

      // A failing check (device may sleep) blocks Continue.
      Finder cont() => find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(cont()).onPressed, isNull);
      expect(find.textContaining('Refused: every check must pass'),
          findsOneWidget);

      // Every check passes: Continue goes straight to the typed confirm.
      awake = true;
      await tester.tap(find.text('Re-check'));
      await tester.pump();
      expect(tester.widget<FilledButton>(cont()).onPressed, isNotNull);
      await tester.tap(cont());
      await tester.pump();

      expect(find.text('Read this before continuing'), findsNothing);
      expect(find.textContaining('Read this before'), findsNothing);
      expect(find.textContaining('I understand'), findsNothing);
      expect(
          find.text('3. Type the battery serial to confirm'), findsOneWidget);
      expect(find.text(otaSternWarning), findsOneWidget);

      Finder start() =>
          find.widgetWithText(FilledButton, 'Start firmware update');
      expect(tester.widget<FilledButton>(start()).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'JS-999');
      await tester.pump();
      expect(tester.widget<FilledButton>(start()).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'JS-118');
      await tester.pump();
      expect(tester.widget<FilledButton>(start()).onPressed, isNotNull);

      // A check that stops passing disables Start again.
      awake = false;
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<FilledButton>(start()).onPressed, isNull);

      // Back returns to the checks (there is no warning step in between).
      await tester.tap(find.widgetWithText(OutlinedButton, 'Back'));
      await tester.pump();
      expect(find.text('2. Pre-flight checks (all must pass)'), findsOneWidget);

      // Nothing was sent to the pack.
      expect(transport.writes.length, written);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
