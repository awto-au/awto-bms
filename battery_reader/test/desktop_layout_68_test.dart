/// #68 drift guards: the phone (stacked) detail page and the desktop (grid)
/// detail pane must render the SAME shared section widgets, in the same
/// order, with the same labels and values — and main.dart must no longer
/// define any per-field row inline. Plus the responsive shell's two
/// arrangements at 400 px and 1280 px (no overflow, shared widgets in both),
/// the keyboard selection, the chart grid and the window-bounds memory.
library;

import 'dart:io';

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_charts.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/desktop_shell.dart';
import 'package:battery_reader/intervals.dart' show LookbackWindow;
import 'package:battery_reader/main.dart';
import 'package:battery_reader/metrics.dart';
import 'package:battery_reader/nav.dart' show gRouteTracker;
import 'package:battery_reader/sections/battery_header_line.dart';
import 'package:battery_reader/sections/capacity_section.dart';
import 'package:battery_reader/sections/cells_section.dart';
import 'package:battery_reader/sections/controls_section.dart';
import 'package:battery_reader/sections/gates_status_section.dart';
import 'package:battery_reader/sections/pack_section.dart';
import 'package:battery_reader/sections/section_card.dart';
import 'package:battery_reader/sections/temperatures_section.dart';
import 'package:battery_reader/alarm_events_view.dart';
import 'package:battery_reader/settings_store.dart';
import 'package:battery_reader/widgets.dart';
import 'package:battery_reader/window_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Pump [total] in [step]s (the demo fleet emits every second, so the tree
/// never settles; pumpAndSettle would time out).
Future<void> pumpFor(WidgetTester tester, Duration total,
    {Duration step = const Duration(milliseconds: 100)}) async {
  var left = total;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

Future<void> view(WidgetTester tester, double w, double h) async {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

BatteryManager demoManager() {
  final m =
      BatteryManager(transport: NoopTransport(), fleetStore: FakeFleetStore());
  m.startDemoFleet();
  return m;
}

/// The test font ("FlutterTest") advances a full em per glyph — about twice
/// the width of Roboto — so a phone-width layout that is fine on a device
/// overflows under it. The layout checks below scale text by this factor,
/// which approximates a proportional font's average advance (~0.5 em), so
/// an overflow they report is a real one.
const double kTestFontScale = 0.5;

Widget scaledText(BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(kTestFontScale)),
      child: child!,
    );

Widget app(Widget home) => MaterialApp(
      navigatorKey: gNavKey,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: scaledText,
      home: home,
    );

/// The app shell as [BatteryReaderApp] builds it (root navigator key + the
/// route tracker the keyboard handler relies on), with the test font scaled.
Widget shellApp() => MaterialApp(
      navigatorKey: gNavKey,
      navigatorObservers: [gRouteTracker],
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: scaledText,
      home: const AdaptiveScaffold(),
    );

/// The widget type each catalogue section renders as — ONE mapping, so the
/// test walks [DetailSection.values] rather than a hand-written list.
Type sectionType(DetailSection s) => switch (s) {
      DetailSection.pack => PackSection,
      DetailSection.capacity => CapacitySection,
      DetailSection.cells => CellsSection,
      DetailSection.temperature => TemperaturesSection,
      DetailSection.gates => GatesStatusSection,
    };

/// An age ("0.8 s ago", "3 min ago") is wall-clock derived and real time
/// passes between the two pumps, so it is compared as "<age> ago".
final RegExp _age = RegExp(r'\d+(\.\d+)? ?(s|min|h|d) ago');
String normaliseValue(String v) => v.replaceAll(_age, '<age> ago');

/// The (label, value) rows inside the section widget of type [t].
List<(String, String)> rowsOf(WidgetTester tester, Type t) => [
      for (final r in tester.widgetList<KvRow>(find.descendant(
          of: find.byType(t), matching: find.byType(KvRow))))
        (r.k, normaliseValue(r.v)),
    ];

/// The section-card titles in tree (= visual) order.
List<String> cardTitles(WidgetTester tester) => [
      for (final c in tester.widgetList<SectionCard>(find.byType(SectionCard)))
        c.title,
    ];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'demo_mode_v1': true});
  });

  group('#68 drift guard: phone page and desktop pane share the sections', () {
    testWidgets(
        'every MetricDef section renders as the same widget, in the same '
        'order, with the same labels and values in both arrangements',
        (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: SharedPreferences.getInstance);
      final conn = manager.batteries.first;
      // Let the demo pack populate its state, then FREEZE it: from here on
      // only zero-duration pumps, so both arrangements see identical values.
      await tester.pumpWidget(const SizedBox());
      await pumpFor(tester, const Duration(seconds: 2));

      // Phone: the stacked page (tall surface so every section is built).
      await view(tester, 400, 6000);
      await tester.pumpWidget(app(
          BatteryDetailPage(conn: conn, manager: manager, aliases: aliases)));
      await tester.pump();
      await tester.pump();
      expect(find.byType(BatteryDetailView), findsOneWidget);
      final phoneView =
          tester.widget<BatteryDetailView>(find.byType(BatteryDetailView));
      expect(phoneView.arrangement, DetailArrangement.stacked);
      expect(phoneView.dense, isFalse);
      final phoneTitles = cardTitles(tester);
      final phoneRows = {
        for (final s in DetailSection.values)
          s: rowsOf(tester, sectionType(s)),
      };
      final phoneOrder = [
        for (final s in DetailSection.values)
          tester.getTopLeft(find.byType(sectionType(s))).dy,
      ];
      for (final s in DetailSection.values) {
        expect(find.byType(sectionType(s)), findsOneWidget, reason: '$s');
      }
      // The other shared sections are all there too.
      expect(find.byType(BatteryHeaderLine), findsOneWidget);
      expect(find.byType(TrendsSection), findsOneWidget);
      expect(find.byType(ControlsSection), findsOneWidget);
      expect(find.byType(AlarmEventsSection), findsOneWidget);
      expect(find.byType(LoggingLine), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Desktop: the grid pane, dense.
      await view(tester, 1280, 6000);
      await tester.pumpWidget(app(Scaffold(
          body: BatteryDetailView(
              conn: conn,
              manager: manager,
              aliases: aliases,
              arrangement: DetailArrangement.grid,
              dense: true))));
      await tester.pump();
      await tester.pump();
      final deskTitles = cardTitles(tester);
      final deskRows = {
        for (final s in DetailSection.values)
          s: rowsOf(tester, sectionType(s)),
      };
      for (final s in DetailSection.values) {
        expect(find.byType(sectionType(s)), findsOneWidget, reason: '$s');
      }
      expect(find.byType(BatteryHeaderLine), findsOneWidget);
      expect(find.byType(TrendsSection), findsOneWidget);
      expect(find.byType(ControlsSection), findsOneWidget);
      expect(find.byType(AlarmEventsSection), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Same section widgets, same order.
      final catalogueTitles = [
        for (final s in DetailSection.values)
          (tester.widget(find.byType(sectionType(s))) as dynamic)
              .runtimeType
              .toString(),
      ];
      expect(catalogueTitles.toSet().length, DetailSection.values.length);
      expect(phoneTitles, deskTitles,
          reason: 'section cards in the same order');
      expect(phoneTitles.take(DetailSection.values.length).toList(),
          ['Pack', 'Capacity', 'Cells', 'Temperature', 'Gates & status']);
      for (var i = 1; i < phoneOrder.length; i++) {
        expect(phoneOrder[i], greaterThan(phoneOrder[i - 1]),
            reason: 'phone sections stack in catalogue order');
      }
      // Same labels AND values, row for row, straight from the catalogue.
      for (final s in DetailSection.values) {
        expect(phoneRows[s], isNotEmpty, reason: '$s has rows');
        expect(deskRows[s], phoneRows[s], reason: '$s rows identical');
        expect([for (final r in phoneRows[s]!) r.$1],
            [for (final m in detailMetrics(s)) m.labelOnDetail],
            reason: '$s labels come from the MetricDef catalogue');
      }
      // Density really is a flag on the SAME widgets, not different ones.
      for (final s in DetailSection.values) {
        final w = tester.widget(find.byType(sectionType(s))) as dynamic;
        expect(w.dense, isTrue, reason: '$s dense on desktop');
      }
      expect(tester.widget<ControlsSection>(find.byType(ControlsSection)).dense,
          isTrue);
      expect(
          tester.widget<BatteryHeaderLine>(find.byType(BatteryHeaderLine)).dense,
          isTrue);
      await tester.pumpWidget(const SizedBox());
      manager.disposeAll();
      await tester.pump();
    });

    test('main.dart defines no per-field row, section or list card inline',
        () {
      final src = File('lib/main.dart').readAsStringSync();
      for (final banned in const [
        'KvRow(',
        'SocBar(',
        'SwitchBadge(',
        'LiveStatusLine(',
        'Sparkline(',
        'fSignedA(',
        'fPct(',
        'fAh(',
        'fV(',
        'detailMetrics(',
        'class SummaryCard',
        'class FleetTotal',
        'class BatteryDetailPage',
        'class SettingsPage',
        'class _Section',
        'class _BatteryGauge',
        'class _ControlsSection',
        'class _TrendsSection',
        'labelOnDetail',
      ]) {
        expect(src.contains(banned), isFalse,
            reason: 'main.dart still contains "$banned"');
      }
      expect(src.split('\n').length, lessThan(200),
          reason: 'main.dart is the entry point only');
    });

    test('each shared section widget is defined exactly once under lib/', () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      for (final cls in const [
        'BatteryHeaderLine',
        'PackSection',
        'CapacitySection',
        'CellsSection',
        'TemperaturesSection',
        'GatesStatusSection',
        'ControlsSection',
        'AlarmEventsSection',
        'TrendsSection',
        'AdvancedSection',
        'SummaryCard',
        'FleetTotal',
        'LiveStatusLine',
        'SocBar',
        'SwitchBadge',
        'SectionCard',
        'LoggingLine',
      ]) {
        final defs = [
          for (final f in files)
            if (RegExp('^class $cls\\b', multiLine: true)
                .hasMatch(f.readAsStringSync()))
              f.path,
        ];
        expect(defs.length, 1, reason: '$cls defined in $defs');
      }
    });
  });

  group('#68 AdaptiveScaffold: one shell, two arrangements', () {
    testWidgets('400 px: the phone navigation (list -> detail -> charts), '
        'no overflow, shared widgets', (tester) async {
      await view(tester, 400, 800);
      await tester.pumpWidget(shellApp());
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.byType(AdaptiveScaffold), findsOneWidget);
      expect(find.byType(BatteryListPage), findsOneWidget);
      expect(find.byType(DesktopShell), findsNothing);
      expect(find.byType(SummaryCard), findsWidgets);
      expect(find.byType(FleetTotal), findsOneWidget);
      for (final c in tester.widgetList<SummaryCard>(find.byType(SummaryCard))) {
        expect(c.dense, isFalse);
        expect(c.selected, isFalse);
      }
      expect(tester.takeException(), isNull);

      // Tap a row: the detail ROUTE opens (phone behaviour unchanged).
      await tester.tap(find.textContaining('JS-2C14AA').first);
      await pumpFor(tester, const Duration(seconds: 2));
      expect(find.byType(BatteryDetailPage), findsOneWidget);
      expect(find.byType(BatteryHeaderLine), findsOneWidget);
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 10; i++) {
        await tester.drag(scrollable, const Offset(0, -400));
        await pumpFor(tester, const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      }
      // Esc returns to the list on a narrow window.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.byType(BatteryDetailPage), findsNothing);
      expect(find.text('Batteries'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('1280 px: two panes, the same row / footer / section widgets '
        'dense, tabs Detail / Charts / Settings, no overflow', (tester) async {
      await view(tester, 1280, 720);
      await tester.pumpWidget(shellApp());
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.byType(AdaptiveScaffold), findsOneWidget);
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(BatteryListPage), findsNothing);
      expect(find.byType(BatteryDetailPage), findsNothing);
      // Left pane: the SAME SummaryCard / FleetTotal widgets, dense.
      // (The rows list is lazy: at 720 px high not every row is built.)
      final cards =
          tester.widgetList<SummaryCard>(find.byType(SummaryCard)).toList();
      expect(cards.length, greaterThanOrEqualTo(3));
      for (final c in cards) {
        expect(c.dense, isTrue);
      }
      expect(cards.where((c) => c.selected).length, 1,
          reason: 'the first battery is selected by default');
      expect(tester.widget<FleetTotal>(find.byType(FleetTotal)).dense, isTrue);
      final left = tester.getSize(find.byType(SummaryCard).first);
      expect(left.width, lessThanOrEqualTo(kLeftPaneWidth));
      // Right pane: the detail view in the grid arrangement, dense, with the
      // shared sections.
      final v = tester.widget<BatteryDetailView>(find.byType(BatteryDetailView));
      expect(v.arrangement, DetailArrangement.grid);
      expect(v.dense, isTrue);
      expect(find.byType(BatteryHeaderLine), findsOneWidget);
      for (final s in DetailSection.values) {
        expect(find.byType(sectionType(s)), findsOneWidget, reason: '$s');
      }
      expect(find.byType(ControlsSection), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Two-up: Pack and Capacity share a row.
      expect(tester.getTopLeft(find.byType(PackSection)).dy,
          tester.getTopLeft(find.byType(CapacitySection)).dy);
      expect(tester.getTopLeft(find.byType(CapacitySection)).dx,
          greaterThan(tester.getTopLeft(find.byType(PackSection)).dx));

      // Selecting another row swaps the pane, no route.
      await tester.tap(find.textContaining('JS-9F031B').first);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.byType(BatteryDetailPage), findsNothing);
      expect(
          tester
              .widget<BatteryDetailView>(find.byType(BatteryDetailView))
              .conn
              .state
              .serial,
          'JS-9F031B');
      final shell = tester.state<AdaptiveScaffoldState>(
          find.byType(AdaptiveScaffold));
      expect(shell.selected?.state.serial, 'JS-9F031B');
      // Down / Up move the selection.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(shell.selected?.state.serial, 'JS-5A77C0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(shell.selected?.state.serial, 'JS-2C14AA');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await pumpFor(tester, const Duration(milliseconds: 300));
      expect(shell.selected?.state.serial, 'JS-2C14AA', reason: 'clamped');
      expect(tester.takeException(), isNull);

      // Charts tab: the charts page embedded, 2 columns at 1280.
      await tester.tap(find.text('Charts'));
      await pumpFor(tester, const Duration(seconds: 2));
      expect(shell.tab, DesktopTab.charts);
      final charts = tester.widget<BatteryChartsPage>(find.byType(BatteryChartsPage));
      expect(charts.embedded, isTrue);
      expect(charts.serial, 'JS-2C14AA');
      expect(find.byType(SegmentedButton<LookbackWindow>), findsOneWidget,
          reason: 'the window selector is the toolbar');
      expect(find.byType(AppBar), findsNothing);
      expect(tester.takeException(), isNull);

      // Settings tab: the settings page embedded; Diagnostics opens in-pane.
      await tester.tap(find.text('Settings'));
      await pumpFor(tester, const Duration(seconds: 1));
      final settings = tester.widget<SettingsPage>(find.byType(SettingsPage));
      expect(settings.embedded, isTrue);
      expect(find.byType(AppBar), findsNothing);
      await tester.tap(find.text('Diagnostics').last);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.text('Back to Settings'), findsNothing);
      expect(find.byTooltip('Back to Settings'), findsOneWidget);
      expect(find.byType(BatteryDetailPage), findsNothing);
      await tester.tap(find.byTooltip('Back to Settings'));
      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(find.byType(SettingsPage), findsOneWidget);
      // Selecting a row from Settings returns to Detail.
      await tester.scrollUntilVisible(find.textContaining('RV-1180E2'), 100,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      await tester.tap(find.textContaining('RV-1180E2').first);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(shell.tab, DesktopTab.detail);
      expect(shell.selected?.state.serial, 'RV-1180E2');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('resizing across 900 px swaps the arrangement in place',
        (tester) async {
      await view(tester, 899, 800);
      await tester.pumpWidget(shellApp());
      await pumpFor(tester, const Duration(seconds: 2));
      expect(find.byType(BatteryListPage), findsOneWidget);
      tester.view.physicalSize = const Size(900, 800);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(BatteryListPage), findsNothing);
      tester.view.physicalSize = const Size(600, 800);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.byType(BatteryListPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('#68 chart grid', () {
    test('columns: 1 below 1100, 2 from 1100, 3 from 1500', () {
      expect(chartColumnsFor(400), 1);
      expect(chartColumnsFor(1099), 1);
      expect(chartColumnsFor(1100), 2);
      expect(chartColumnsFor(1499), 2);
      expect(chartColumnsFor(1500), 3);
      expect(chartColumnsFor(2560), 3);
    });

    test('one column returns the cards unchanged; N columns rows them', () {
      final cards = [for (var i = 0; i < 7; i++) Text('$i')];
      expect(identical(chartGridRows(cards, 1), cards), isTrue);
      final rows = chartGridRows(cards, 3);
      expect(rows.length, 3);
      expect(rows.every((r) => r is IntrinsicHeight), isTrue);
    });
  });

  group('#68 window memory', () {
    test('WindowBounds round-trips through SettingsStore and rejects junk',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(prefs: SharedPreferences.getInstance);
      expect(await store.loadWindowBounds(), isNull);
      const b = WindowBounds(left: 10, top: 20, width: 1200, height: 700);
      await store.saveWindowBounds(b);
      expect(await store.loadWindowBounds(), b);
      expect(WindowBounds.fromMap({'left': 1, 'top': 2, 'width': 100, 'height': 50}),
          isNull, reason: 'below the 900x600 minimum');
      expect(WindowBounds.fromMap({'left': 'x'}), isNull);
      expect(
          WindowBounds.fromMap({
            'left': 0,
            'top': 0,
            'width': 1000,
            'height': 700,
            'maximized': true
          })!
              .maximized,
          isTrue);
    });

    testWidgets('restore applies the saved bounds; a runner report is saved '
        '(debounced), maximized keeps the normal size', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(prefs: SharedPreferences.getInstance);
      const saved = WindowBounds(left: 5, top: 6, width: 1100, height: 650);
      await store.saveWindowBounds(saved);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WindowMemory.channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(WindowMemory.channel, null));
      final memory = WindowMemory(store);
      await memory.restore();
      expect(calls.map((c) => c.method), ['setBounds']);
      expect(WindowBounds.fromMap(calls.first.arguments as Map), saved);

      // The runner reports a move: saved after the debounce.
      Future<void> report(Map<String, Object> m) async {
        final data = WindowMemory.channel.codec
            .encodeMethodCall(MethodCall('boundsChanged', m));
        await messenger.handlePlatformMessage(
            WindowMemory.channel.name, data, (_) {});
      }

      await report({'left': 50, 'top': 60, 'width': 1000, 'height': 640});
      expect(await store.loadWindowBounds(), saved, reason: 'not yet');
      await tester.pump(WindowMemory.saveDelay * 2);
      expect(await store.loadWindowBounds(),
          const WindowBounds(left: 50, top: 60, width: 1000, height: 640));
      // Maximized: only the flag flips; the normal bounds are kept.
      await report({
        'left': 0,
        'top': 0,
        'width': 1920,
        'height': 1040,
        'maximized': true
      });
      await tester.pump(WindowMemory.saveDelay * 2);
      expect(
          await store.loadWindowBounds(),
          const WindowBounds(
              left: 50, top: 60, width: 1000, height: 640, maximized: true));
      memory.dispose();
    });
  });
}
