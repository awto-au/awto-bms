/// #12: the mouse wheel scrolls every desktop pane. Real [PointerScrollEvent]s
/// (a mouse [TestPointer] hovers, then rolls) go through the binding's hit
/// test and pointer-signal resolver exactly as a Windows wheel notch does, so
/// a pane that swallowed or ignored the wheel would fail here. Checked with
/// the Windows platform and the desktop 0.75 text scale, at the minimum
/// desktop window (900x600, so every pane has something to scroll), over:
///  * the Detail pane — its header AND the Trends section (where the wheel
///    was first reported dead),
///  * the Charts tab — over a chart card (fl_chart),
///  * the left pane — the battery rows,
/// and, in a narrow window (the single-pane layout), the list rows, the fleet
/// panel and the detail page over Trends.
library;

import 'package:battery_reader/battery_charts.dart' show BatteryChartsPage;
import 'package:battery_reader/battery_list_page.dart' show BatteryListView;
import 'package:battery_reader/main.dart';
import 'package:battery_reader/nav.dart' show gRouteTracker;
import 'package:battery_reader/sections/battery_header_line.dart';
import 'package:fl_chart/fl_chart.dart' show LineChart;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'real_fonts.dart';

/// Pump [total] in 100 ms steps (the demo fleet never settles).
Future<void> pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  var left = total;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

/// The app shell with the desktop scaler forced on.
Widget desktopApp() => MaterialApp(
      navigatorKey: gNavKey,
      navigatorObservers: [gRouteTracker],
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: desktopTextScaler(TextScaler.noScaling)),
        child: child!,
      ),
      home: const AdaptiveScaffold(rememberWindow: false),
    );

/// The tallest downward-scrolling Scrollable under [within].
ScrollableState mainScrollable(WidgetTester tester, Finder within) {
  final all = tester
      .stateList<ScrollableState>(
          find.descendant(of: within, matching: find.byType(Scrollable)))
      .where((s) => s.axisDirection == AxisDirection.down)
      .toList();
  expect(all, isNotEmpty, reason: 'no vertical scrollable under $within');
  double h(ScrollableState s) =>
      (s.context.findRenderObject() as RenderBox).size.height;
  all.sort((a, b) => h(b).compareTo(h(a)));
  return all.first;
}

int _pointerId = 100;

/// Hover a MOUSE at [at], roll the wheel one notch-ish (120 px) towards the
/// side [s] can move to, and return how far [s] moved (signed, along the
/// wheel's direction: > 0 means it followed the wheel).
Future<double> wheel(WidgetTester tester, Offset at, ScrollableState s) async {
  final p = s.position;
  expect(p.maxScrollExtent, greaterThan(0),
      reason: 'the pane must have something to scroll');
  final dy = p.pixels < p.maxScrollExtent ? 120.0 : -120.0;
  final before = p.pixels;
  final mouse = TestPointer(_pointerId++, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(mouse.hover(at));
  await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
  await pumpFor(tester, const Duration(milliseconds: 300));
  return (p.pixels - before) * dy.sign;
}

/// Step [s] down until [f] is built (lazy lists), then bring it into view.
Future<void> reveal(WidgetTester tester, Finder f, ScrollableState s) async {
  while (
      f.evaluate().isEmpty && s.position.pixels < s.position.maxScrollExtent) {
    s.position.jumpTo(
        (s.position.pixels + 200).clamp(0.0, s.position.maxScrollExtent));
    await tester.pump();
  }
  await tester.ensureVisible(f);
  await pumpFor(tester, const Duration(milliseconds: 300));
}

/// A point inside [f]'s visible part (its centre, clamped into [pane]).
Offset inside(WidgetTester tester, Finder f, Finder pane) {
  final r = tester.getRect(f).intersect(tester.getRect(pane));
  expect(r.isEmpty, isFalse, reason: '$f is not on screen');
  return r.center;
}

void main() {
  setUpAll(loadRealFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'demo_mode_v1': true,
      'fleet_serials_v1': ['DEMO-1', 'DEMO-2', 'DEMO-3'],
    });
  });

  testWidgets(
      '#12 the wheel scrolls the Detail pane, the Charts tab and '
      'the left pane (Windows, 900x600, 0.75)', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(desktopApp());
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.byType(DesktopShell), findsOneWidget);

      // Detail pane, over the header card.
      final detail = find.byType(BatteryDetailView);
      final ds = mainScrollable(tester, detail);
      expect(
          await wheel(tester,
              inside(tester, find.byType(BatteryHeaderLine), detail), ds),
          greaterThan(0),
          reason: 'Detail pane over the header');
      // Detail pane, over the Trends section (the reported spot).
      await reveal(tester, find.byType(TrendsSection), ds);
      expect(
          await wheel(
              tester, inside(tester, find.byType(TrendsSection), detail), ds),
          greaterThan(0),
          reason: 'Detail pane over Trends');
      expect(tester.takeException(), isNull);

      // Left pane: the battery rows, over a row card.
      final rows = find.byType(BatteryListView);
      final ls = mainScrollable(tester, rows);
      expect(
          await wheel(
              tester, inside(tester, find.byType(SummaryCard).first, rows), ls),
          greaterThan(0),
          reason: 'left pane battery rows');
      // (The fleet footer below the rows fits at 900x600 with this demo
      // fleet — nothing to scroll; the narrow-window test rolls it.)

      // Charts tab, over a chart card.
      await tester.tap(find.text('Charts'));
      await pumpFor(tester, const Duration(seconds: 4));
      final charts = find.byType(BatteryChartsPage);
      final cs = mainScrollable(tester, charts);
      expect(
          await wheel(
              tester, inside(tester, find.text('Cell voltages'), charts), cs),
          greaterThan(0),
          reason: 'Charts tab over the title of a chart card');
      // Over a plot itself (the fl_chart canvas).
      cs.position.jumpTo(0);
      await tester.pump();
      expect(
          await wheel(
              tester, inside(tester, find.byType(LineChart).first, charts), cs),
          greaterThan(0),
          reason: 'Charts tab over a plot');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      '#12 the wheel scrolls the single-pane list, fleet panel and '
      'detail page (over Trends) (Windows, narrow window)', (tester) async {
    tester.view.physicalSize = const Size(600, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(desktopApp());
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.byType(BatteryListPage), findsOneWidget);
      final rows = find.byType(BatteryListView);
      expect(
          await wheel(
              tester,
              inside(tester, find.byType(SummaryCard).first, rows),
              mainScrollable(tester, rows)),
          greaterThan(0),
          reason: 'phone list rows');
      final fleet = find.byType(FleetTotal);
      expect(
          await wheel(
              tester, tester.getCenter(fleet), mainScrollable(tester, fleet)),
          greaterThan(0),
          reason: 'phone fleet panel');
      mainScrollable(tester, rows).position.jumpTo(0);
      await tester.pump();
      await tester.tap(find.textContaining('DEMO 1').first);
      await pumpFor(tester, const Duration(seconds: 2));
      final page = find.byType(BatteryDetailPage);
      expect(page, findsOneWidget);
      final s = mainScrollable(tester, page);
      await reveal(tester, find.byType(TrendsSection), s);
      expect(
          await wheel(
              tester, inside(tester, find.byType(TrendsSection), page), s),
          greaterThan(0),
          reason: 'phone detail page over Trends');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
