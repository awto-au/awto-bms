/// GitHub #69 / #70.
///
/// #69: the Charts page is charts + window selector only — every logging /
/// status string (the dotted / dashed legend, the "telemetry is recorded…"
/// explanation) moved to the battery DETAIL page as the "Logging" line under
/// the Trends selector ([LoggingLine] / [loggingStatusLine]).
///
/// #70: every chart card shows current / max / min / median for the window
/// in view ([seriesStats], time-weighted median) and carries a FULL / FIT
/// Y-axis toggle ([YAxisToggle]) whose default is the persisted Settings
/// choice ([SettingsStore.chartYAxisFit] -> [gYAxisMode]); the sparklines
/// follow that default.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_charts.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/intervals.dart';
import 'package:battery_reader/main.dart'
    show BatteryDetailPage, LoggingLine, gNavKey;
import 'package:battery_reader/settings_store.dart';
import 'package:battery_reader/sparkline.dart';
import 'package:battery_reader/temp_unit.dart';

import 'fakes.dart';

ReadingInterval iv(double v, int start, int end) =>
    ReadingInterval(metric: 'm', valueNum: v, startMs: start, endMs: end);

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

Widget _app({required Widget home}) => MaterialApp(
      navigatorKey: gNavKey,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: home,
    );

/// Pump [total] in [step]s (the demo emits every second, so the tree never
/// settles; pumpAndSettle would time out).
Future<void> pumpFor(WidgetTester tester, Duration total,
    {Duration step = const Duration(milliseconds: 100)}) async {
  var left = total;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

BatteryManager demoManager() {
  final m =
      BatteryManager(transport: NoopTransport(), fleetStore: FakeFleetStore());
  m.startDemoFleet();
  return m;
}

void main() {
  // -------------------------------------------------------------------------
  group('#70 seriesStats — current / max / min / time-weighted median', () {
    test('no rows, or no numeric rows, -> null', () {
      expect(seriesStats(const [], 0, 1000), isNull);
      expect(
          seriesStats([
            const ReadingInterval(
                metric: 'm', valueText: 'x', startMs: 0, endMs: 10),
          ], 0, 1000),
          isNull);
    });

    test('rows entirely outside the window are ignored', () {
      expect(seriesStats([iv(9, 0, 100), iv(8, 2000, 3000)], 500, 1500),
          isNull);
    });

    test('current is the row that ENDS latest, max/min over the values', () {
      final st = seriesStats([
        iv(3.1, 0, 100),
        iv(3.3, 100, 200),
        iv(3.0, 200, 300), // the open, latest row
      ], 0, 300)!;
      expect(st.current, 3.0);
      expect(st.max, 3.3);
      expect(st.min, 3.0);
      expect(st.rows, 3);
    });

    test(
        'the median is TIME-WEIGHTED: a background sample held for 15 min '
        'outweighs a burst of short changes (#53 hold, not one point)', () {
      // 3.30 held 15 min (one background sample), then three quick 1 s
      // readings at 3.00 / 3.05 / 3.10. A per-sample median would be ~3.05;
      // by held time 3.30 covers > half the window.
      final st = seriesStats([
        iv(3.30, 0, 900000),
        iv(3.00, 900000, 901000),
        iv(3.05, 901000, 902000),
        iv(3.10, 902000, 903000),
      ], 0, 903000)!;
      expect(st.median, 3.30);
      expect(st.current, 3.10);
      expect(st.max, 3.30);
      expect(st.min, 3.00);
    });

    test('a row straddling the window edge counts only its clipped part', () {
      // 1.0 held 0..1000 but the window starts at 900 -> 100 ms of it; 5.0
      // held 1000..1500 -> 500 ms. Median by held time = 5.0.
      final st = seriesStats([iv(1, 0, 1000), iv(5, 1000, 1500)], 900, 1500)!;
      expect(st.median, 5.0);
      expect(st.min, 1.0);
      expect(st.max, 5.0);
    });

    test('all zero-length rows fall back to the plain sample median', () {
      final st = seriesStats([iv(7, 10, 10), iv(3, 20, 20), iv(5, 30, 30)],
          0, 100)!;
      expect(st.median, 5.0);
      expect(st.current, 5.0);
    });

    test('statsText renders now/max/min/med through the °F transform', () {
      final st = seriesStats([iv(25, 0, 100), iv(43, 100, 300)], 0, 300)!;
      expect(statsText(st), 'now 43.0 · max 43.0 · min 25.0 · med 43.0');
      // 43 °C -> 109.4 °F, rendered with fmtStat's >= 100 -> 0 dp rule.
      expect(statsText(st, celsiusToFahrenheit),
          'now 109 · max 109 · min 77.0 · med 109');
      final cells = seriesStats([iv(3.0, 0, 100), iv(3.3, 100, 1000)], 0, 1000)!;
      expect(statsText(cells),
          'now 3.300 · max 3.300 · min 3.000 · med 3.300');
    });
  });

  // -------------------------------------------------------------------------
  group('#70 yBounds — FULL (0-based, #32) vs FIT (tight to the data)', () {
    test('cells 3.0–3.3 V: FULL keeps 0 as the floor, FIT zooms to the band',
        () {
      final (flo, fhi) = yBounds(3.0, 3.3);
      expect(flo, 0);
      expect(fhi, closeTo(3.63, 1e-9));
      final (lo, hi) = yBounds(3.0, 3.3, mode: YAxisMode.fit);
      expect(lo, closeTo(2.97, 1e-9));
      expect(hi, closeTo(3.33, 1e-9));
    });

    test('temps 25–43 °C: FIT pads by 10 % of the span each side', () {
      final (lo, hi) = yBounds(25, 43, mode: YAxisMode.fit);
      expect(lo, closeTo(23.2, 1e-9));
      expect(hi, closeTo(44.8, 1e-9));
      final (flo, fhi) = yBounds(25, 43);
      expect(flo, 0);
      expect(fhi, closeTo(47.3, 1e-9));
    });

    test('FIT ignores the explicit SOC 0..100 and the centreZero symmetry', () {
      expect(yBounds(78, 82, minY: 0, maxY: 100), (0.0, 100.0));
      final (lo, hi) = yBounds(78, 82, minY: 0, maxY: 100, mode: YAxisMode.fit);
      expect(lo, closeTo(77.6, 1e-9));
      expect(hi, closeTo(82.4, 1e-9));
      final (clo, chi) = yBounds(-4, 12, centreZero: true, mode: YAxisMode.fit);
      expect(clo, closeTo(-5.6, 1e-9));
      expect(chi, closeTo(13.6, 1e-9));
    });

    test('FIT on a flat series widens by 1 % of the value (±1 at 0)', () {
      final (lo, hi) = yBounds(3.3, 3.3, mode: YAxisMode.fit);
      expect(lo, closeTo(3.267, 1e-9));
      expect(hi, closeTo(3.333, 1e-9));
      expect(yBounds(0, 0, mode: YAxisMode.fit), (-1.0, 1.0));
      expect(yBounds(double.infinity, double.negativeInfinity,
          mode: YAxisMode.fit), (0.0, 1.0));
    });

    test('sparklines (pad 0): FIT is exactly min..max', () {
      final runs = buildSparklineRuns([iv(3.0, 0, 100), iv(3.3, 100, 200)]);
      expect(sparkYBounds(runs), (0.0, 3.3));
      expect(sparkYBounds(runs, mode: YAxisMode.fit), (3.0, 3.3));
    });

    test('YAxisMode helpers', () {
      expect(YAxisMode.full.other, YAxisMode.fit);
      expect(YAxisMode.fit.other, YAxisMode.full);
      expect(YAxisMode.fromFit(true), YAxisMode.fit);
      expect(YAxisMode.fromFit(false), YAxisMode.full);
      expect(YAxisMode.fit.isFit, isTrue);
      expect(YAxisMode.full.isFit, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('#70 Settings persistence — chart Y axis default', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppLog.instance.echoToConsole = false;
    });
    tearDown(() => AppLog.instance.echoToConsole = true);

    test('additive key, default FULL (fit = false), listed in `all`', () async {
      expect(SettingsStore.chartYAxisFit.key, 'chart_y_axis_fit_v1');
      expect(SettingsStore.chartYAxisFit.defaultValue, isFalse);
      expect(SettingsStore.all, contains(SettingsStore.chartYAxisFit));
      expect(await SettingsStore().loadChartYAxisFit(), isFalse);
    });

    test('round trip: save fit -> load fit -> YAxisMode.fit', () async {
      final s = SettingsStore();
      await s.saveChartYAxisFit(true);
      expect(await s.loadChartYAxisFit(), isTrue);
      expect(YAxisMode.fromFit(await s.loadChartYAxisFit()), YAxisMode.fit);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('chart_y_axis_fit_v1'), isTrue);
      await s.saveChartYAxisFit(false);
      expect(await s.loadChartYAxisFit(), isFalse);
    });

    test('a persisted value from a previous run is honoured', () async {
      SharedPreferences.setMockInitialValues({'chart_y_axis_fit_v1': true});
      expect(await SettingsStore().loadChartYAxisFit(), isTrue);
    });

    test('an unavailable plugin falls back to FULL', () async {
      Future<SharedPreferences> broken() async =>
          throw StateError('MissingPluginException');
      expect(await SettingsStore(prefs: broken).loadChartYAxisFit(), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('#70 YAxisToggle widget', () {
    testWidgets('FULL: unfold_more + "Full", tooltip "Fit axis to data"; a tap '
        'asks for FIT', (tester) async {
      YAxisMode? got;
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: YAxisToggle(mode: YAxisMode.full, onChanged: (m) => got = m),
        ),
      ));
      expect(find.byIcon(Icons.unfold_more), findsOneWidget);
      expect(find.byIcon(Icons.unfold_less), findsNothing);
      expect(find.text('Full'), findsOneWidget);
      expect(find.byTooltip(YAxisToggle.fitTooltip), findsOneWidget);
      await tester.tap(find.byType(YAxisToggle));
      expect(got, YAxisMode.fit);
    });

    testWidgets('FIT: unfold_less + "Fit", tooltip "Show full range"; a tap '
        'asks for FULL', (tester) async {
      YAxisMode? got;
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: YAxisToggle(mode: YAxisMode.fit, onChanged: (m) => got = m),
        ),
      ));
      expect(find.byIcon(Icons.unfold_less), findsOneWidget);
      expect(find.byIcon(Icons.unfold_more), findsNothing);
      expect(find.text('Fit'), findsOneWidget);
      expect(find.byTooltip(YAxisToggle.fullTooltip), findsOneWidget);
      await tester.tap(find.byType(YAxisToggle));
      expect(got, YAxisMode.full);
    });
  });

  // -------------------------------------------------------------------------
  group('#70 ChartCard — stats row + per-card axis toggle', () {
    final cells = [iv(3.0, 0, 100000), iv(3.3, 100000, 1000000)];

    Widget card({YAxisMode mode = YAxisMode.full, bool multi = false}) => _app(
          home: Scaffold(
            body: ListView(children: [
              ChartCard(
                title: 'Cell voltages',
                unit: 'V',
                fromMs: 0,
                toMs: 1000000,
                mode: mode,
                series: [
                  Series('Cell 1', cellColor(0), cells),
                  if (multi)
                    Series('Cell 2', cellColor(1), [iv(3.1, 0, 1000000)]),
                ],
              ),
            ]),
          ),
        );

    LineChartData chart(WidgetTester t) =>
        t.widget<LineChart>(find.byType(LineChart)).data;

    testWidgets('shows now/max/min/med for the window in the series colour',
        (tester) async {
      await tester.pumpWidget(card());
      final f = find.text('now 3.300 · max 3.300 · min 3.000 · med 3.300');
      expect(f, findsOneWidget);
      final t = tester.widget<Text>(f);
      expect(t.style!.color!.toARGB32() & 0xFFFFFF,
          cellColor(0).toARGB32() & 0xFFFFFF);
    });

    testWidgets('several series: one labelled line per series',
        (tester) async {
      await tester.pumpWidget(card(multi: true));
      expect(find.text('Cell 1: now 3.300 · max 3.300 · min 3.000 · med 3.300'),
          findsOneWidget);
      expect(find.text('Cell 2: now 3.100 · max 3.100 · min 3.100 · med 3.100'),
          findsOneWidget);
    });

    testWidgets('starts in the given (Settings) mode: FULL -> 0-based axis; '
        'the toggle flips icon AND bounds for the session', (tester) async {
      await tester.pumpWidget(card());
      expect(chart(tester).minY, 0);
      expect(chart(tester).maxY, closeTo(3.63, 1e-9));
      expect(find.byIcon(Icons.unfold_more), findsOneWidget);
      expect(find.byTooltip(YAxisToggle.fitTooltip), findsOneWidget);

      await tester.tap(find.byType(YAxisToggle));
      await tester.pump();
      expect(chart(tester).minY, closeTo(2.97, 1e-9));
      expect(chart(tester).maxY, closeTo(3.33, 1e-9));
      expect(find.byIcon(Icons.unfold_less), findsOneWidget);
      expect(find.byIcon(Icons.unfold_more), findsNothing);
      expect(find.byTooltip(YAxisToggle.fullTooltip), findsOneWidget);
      // The axis labels come from the bounds, so "0.00" is gone in FIT.
      expect(find.text('0.00'), findsNothing);

      await tester.tap(find.byType(YAxisToggle));
      await tester.pump();
      expect(chart(tester).minY, 0);
      expect(find.byIcon(Icons.unfold_more), findsOneWidget);
    });

    testWidgets('a FIT default starts tight', (tester) async {
      await tester.pumpWidget(card(mode: YAxisMode.fit));
      expect(chart(tester).minY, closeTo(2.97, 1e-9));
      expect(find.byIcon(Icons.unfold_less), findsOneWidget);
      expect(find.text('Fit'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  group('#69 loggingStatusLine (pure)', () {
    test('states', () {
      expect(
          loggingStatusLine(
              enabled: true,
              degraded: false,
              sampleIntervalMs: 0,
              rowsInWindow: 1234,
              windowLabel: '24h'),
          'Logging on · continuous · 1234 rows in 24h');
      expect(
          loggingStatusLine(
              enabled: true,
              degraded: false,
              sampleIntervalMs: 300000,
              rowsInWindow: 1,
              windowLabel: '1h'),
          'Logging on · background samples every 5 min · 1 row in 1h');
      expect(
          loggingStatusLine(
              enabled: true,
              degraded: false,
              sampleIntervalMs: 0,
              rowsInWindow: 0,
              windowLabel: 'All'),
          'Logging on · continuous · no rows yet — telemetry is recorded '
          'while this battery is connected');
      expect(
          loggingStatusLine(
              enabled: false,
              degraded: false,
              sampleIntervalMs: 0,
              rowsInWindow: 0,
              windowLabel: '1h'),
          'Logging off — database not open');
      expect(
          loggingStatusLine(
              enabled: true,
              degraded: true,
              lastError: 'disk I/O error',
              sampleIntervalMs: 0,
              rowsInWindow: 5,
              windowLabel: '1h'),
          'Logging failing — disk I/O error');
    });

    test('fmtSampleInterval', () {
      expect(fmtSampleInterval(30000), '30 s');
      expect(fmtSampleInterval(300000), '5 min');
      expect(fmtSampleInterval(7200000), '2 h');
    });

    test('the legend text is the one moved off the Charts page', () {
      expect(sampleLegendText, 'Dotted = background samples · dashed = offline');
    });
  });

  // -------------------------------------------------------------------------
  group('#69 pages: the Charts page has no logging text, the Detail page has it',
      () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      gYAxisMode = YAxisMode.full;
    });

    testWidgets('Charts page: charts + window selector only (+ stats/toggles)',
        (tester) async {
      final manager = demoManager();
      final conn = manager.batteries.first;
      await tester.pumpWidget(_app(home: const Scaffold(body: Text('root'))));
      await pumpFor(tester, const Duration(seconds: 3));
      gNavKey.currentState!.push(MaterialPageRoute(
          builder: (_) => BatteryChartsPage(serial: conn.state.serial!)));
      await pumpFor(tester, const Duration(seconds: 4));

      // The window selector and the chart cards are there…
      expect(find.text(LookbackWindow.h1.label), findsOneWidget);
      expect(find.text('Cell voltages'), findsOneWidget);
      // (The ListView builds lazily, so only the on-screen cards exist.)
      expect(find.byType(ChartCard), findsWidgets);
      expect(find.byType(YAxisToggle), findsWidgets);
      expect(find.textContaining('now '), findsWidgets);
      // …and no logging / status text at all (#69).
      expect(find.textContaining('Dotted'), findsNothing);
      expect(find.textContaining('dashed'), findsNothing);
      expect(find.textContaining('Logging'), findsNothing);
      expect(find.textContaining('rows'), findsNothing);
      expect(find.textContaining('Telemetry is recorded'), findsNothing);
      expect(find.byType(LoggingLine), findsNothing);

      gNavKey.currentState!.pop();
      await pumpFor(tester, const Duration(seconds: 1));
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets('Detail page: the Logging line sits in the Trends card',
        (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: _prefs);
      final conn = manager.batteries.first;
      await tester.pumpWidget(_app(
          home: BatteryDetailPage(
              conn: conn, manager: manager, aliases: aliases)));
      await pumpFor(tester, const Duration(seconds: 4));
      final line = find.byType(LoggingLine);
      await tester.scrollUntilVisible(line, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(line, findsOneWidget);
      expect(find.textContaining('Logging'), findsOneWidget);
      // Placed with the Trends section.
      expect(find.text('Trends'), findsOneWidget);
      manager.disposeAll();
      await tester.pump();
    });
  });
}
