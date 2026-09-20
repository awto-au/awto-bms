/// GitHub #57: the red "Failed assertion: '_dependents.isEmpty': is not true"
/// screen. The regression tests here drive the exact sequence that produced it
/// (a text-entry dialog dismissed while its pop transition is still running)
/// plus the surrounding async-UI paths as guards.
library;

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_charts.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/intervals.dart';
import 'package:battery_reader/main.dart';
import 'package:battery_reader/write_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

Widget _app({required Widget home}) => MaterialApp(
      navigatorKey: gNavKey,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: home,
    );

/// Pump [total] in [step]s (the demo emits every second, so the tree never
/// "settles"; pumpAndSettle would time out).
Future<void> pumpFor(WidgetTester tester, Duration total,
    {Duration step = const Duration(milliseconds: 100)}) async {
  var left = total;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200,
      scrollable: find.byType(Scrollable).first);
  await pumpFor(tester, const Duration(milliseconds: 500));
}

BatteryManager demoManager() {
  final m =
      BatteryManager(transport: NoopTransport(), fleetStore: FakeFleetStore());
  m.startDemoFleet();
  return m;
}

/// Frame-by-frame through a dialog's pop transition: this is where a
/// controller disposed too early blows up (#57).
Future<void> pumpThroughTransition(WidgetTester tester) =>
    pumpFor(tester, const Duration(seconds: 1),
        step: const Duration(milliseconds: 16));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('#57 regression: text-entry dialogs outlive their controllers', () {
    testWidgets('rename dialog: Cancel during the pop transition',
        (tester) async {
      final aliases = AliasStore(prefs: _prefs);
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => editBatteryAlias(ctx, aliases, 'JS-TEST01'),
              child: const Text('rename'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('rename'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpThroughTransition(tester);
      expect(find.byType(TextField), findsNothing);
      // The page underneath must still be alive (no red screen).
      expect(find.text('rename'), findsOneWidget);
    });

    testWidgets('rename dialog: Save during the pop transition',
        (tester) async {
      final aliases = AliasStore(prefs: _prefs);
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => editBatteryAlias(ctx, aliases, 'JS-TEST01'),
              child: const Text('rename'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('rename'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField), 'Left');
      await tester.tap(find.text('Save'));
      await pumpThroughTransition(tester);
      expect(find.byType(TextField), findsNothing);
      expect(aliases.aliasFor('JS-TEST01'), 'Left');
      expect(find.text('rename'), findsOneWidget);
    });

    testWidgets('capacity dialog: Cancel during the pop transition',
        (tester) async {
      final manager = demoManager();
      final conn = manager.batteries.first;
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => askCapacity(ctx, conn),
              child: const Text('capacity'),
            ),
          ),
        ),
      ));
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.tap(find.text('capacity'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpThroughTransition(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('capacity'), findsOneWidget);
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets('capacity dialog: Next… during the pop transition',
        (tester) async {
      final manager = demoManager();
      final conn = manager.batteries.first;
      double? got;
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => got = await askCapacity(ctx, conn),
              child: const Text('capacity'),
            ),
          ),
        ),
      ));
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.tap(find.text('capacity'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField), '120');
      await tester.tap(find.text('Next…'));
      await pumpThroughTransition(tester);
      expect(find.byType(TextField), findsNothing);
      expect(got, 120);
      manager.disposeAll();
      await tester.pump();
    });
  });

  group('#57 guards: async UI paths', () {
    testWidgets('detail page: write with read-back, pop during read-back',
        (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: _prefs);
      final conn = manager.batteries.first;
      await tester.pumpWidget(_app(home: const Scaffold(body: Text('root'))));
      await pumpFor(tester, const Duration(seconds: 2));

      gNavKey.currentState!.push(MaterialPageRoute(
          builder: (_) => BatteryDetailPage(
              conn: conn, manager: manager, aliases: aliases)));
      await pumpFor(tester, const Duration(seconds: 1));

      final btn = find.widgetWithText(FilledButton, 'Turn output OFF');
      await scrollTo(tester, btn);
      await tester.tap(btn);
      await pumpFor(tester, const Duration(milliseconds: 500));
      await tester.tap(find.text('Continue…'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      await tester
          .tap(find.widgetWithText(FilledButton, 'Turn output OFF').last);
      await tester.pump(); // send
      await tester.pump(const Duration(milliseconds: 50));
      // Pop the page while the read-back (~200 ms demo ack, up to 4 s) runs.
      gNavKey.currentState!.pop();
      await pumpFor(tester, const Duration(seconds: 6));
      expect(find.text('root'), findsOneWidget);
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets('charts page: ticks, window toggles, refresh, pop mid-load',
        (tester) async {
      final manager = demoManager();
      final conn = manager.batteries.first;
      await tester.pumpWidget(_app(home: const Scaffold(body: Text('root'))));
      await pumpFor(tester, const Duration(seconds: 3));

      gNavKey.currentState!.push(MaterialPageRoute(
          builder: (_) => BatteryChartsPage(serial: conn.state.serial!)));
      await pumpFor(tester, const Duration(seconds: 6));
      await tester.tap(find.text(LookbackWindow.h24.label));
      await pumpFor(tester, const Duration(seconds: 2));
      await tester.tap(find.text(LookbackWindow.all.label));
      await pumpFor(tester, const Duration(seconds: 2));
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      gNavKey.currentState!.pop();
      await pumpFor(tester, const Duration(seconds: 2));
      expect(find.text('root'), findsOneWidget);
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets('deep-link: popUntil root + push while a dialog is open',
        (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: _prefs);
      final conn = manager.batteries.first;
      await tester.pumpWidget(_app(home: const Scaffold(body: Text('root'))));
      await pumpFor(tester, const Duration(seconds: 2));
      gNavKey.currentState!.push(MaterialPageRoute(
          builder: (_) => BatteryDetailPage(
              conn: conn, manager: manager, aliases: aliases)));
      await pumpFor(tester, const Duration(seconds: 1));
      final btn = find.widgetWithText(FilledButton, 'Turn output OFF');
      await scrollTo(tester, btn);
      await tester.tap(btn);
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(find.text('Continue…'), findsOneWidget);
      // The notification deep-link sequence (#45).
      final nav = gNavKey.currentState!;
      nav.popUntil((r) => r.isFirst);
      nav.push(MaterialPageRoute(
          builder: (_) => BatteryDetailPage(
              conn: manager.batteries[1], manager: manager, aliases: aliases)));
      await pumpFor(tester, const Duration(seconds: 6));
      expect(find.textContaining(manager.batteries[1].state.serial!),
          findsWidgets);
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets('detail page open while the fleet is replaced (demo restart)',
        (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: _prefs);
      final conn = manager.batteries.first;
      await tester.pumpWidget(_app(home: const Scaffold(body: Text('root'))));
      await pumpFor(tester, const Duration(seconds: 2));
      gNavKey.currentState!.push(MaterialPageRoute(
          builder: (_) => BatteryDetailPage(
              conn: conn, manager: manager, aliases: aliases)));
      await pumpFor(tester, const Duration(seconds: 1));
      manager.startDemoFleet(); // disposes conn under the open page
      await pumpFor(tester, const Duration(seconds: 4));
      gNavKey.currentState!.pop();
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.text('root'), findsOneWidget);
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets(
        'full app in demo mode: list -> detail -> charts -> rename -> settings',
        (tester) async {
      SharedPreferences.setMockInitialValues({'demo_mode_v1': true});
      await tester.pumpWidget(const BatteryReaderApp());
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.textContaining('JS-2C14AA'), findsWidgets);

      await tester.tap(find.textContaining('JS-2C14AA').first);
      await pumpFor(tester, const Duration(seconds: 2));
      await tester.tap(find.byIcon(Icons.show_chart));
      await pumpFor(tester, const Duration(seconds: 6));
      await tester.tap(find.text(LookbackWindow.h24.label));
      await pumpFor(tester, const Duration(seconds: 3));
      await tester.pageBack();
      await pumpFor(tester, const Duration(seconds: 2));
      await tester.tap(find.text(LookbackWindow.h1.label));
      await pumpFor(tester, const Duration(seconds: 4));
      // The rename dialog from the detail page's app bar (the #57 trigger).
      await tester.tap(find.byIcon(Icons.edit).first);
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.tap(find.text('Cancel'));
      await pumpThroughTransition(tester);
      await tester.pageBack();
      await pumpFor(tester, const Duration(seconds: 2));

      await tester.tap(find.byIcon(Icons.settings));
      await pumpFor(tester, const Duration(seconds: 2));
      await scrollTo(tester, find.text('Demo mode'));
      await tester.tap(find.text('Demo mode'));
      await pumpFor(tester, const Duration(seconds: 3));
      await tester.tap(find.text('Demo mode'));
      await pumpFor(tester, const Duration(seconds: 3));
      await tester.pageBack();
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.text('Batteries'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
