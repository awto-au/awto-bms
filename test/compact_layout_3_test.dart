/// #3 compact layout pins: every read-only data row is exactly ONE text line
/// with no gap to the next, a section card is title line + 5 px rule + rows
/// inside 6 px padding (4 px above the title) and 2 px margin (cards 4 px
/// apart), a Trends sparkline row is one line tall, and the detail page has
/// no spacer rows. The same numbers hold on the phone (stacked) page and the
/// desktop (grid, dense) pane. Plus no overflow at 320 / 360 / 412 / 1280 px.
library;

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/intervals.dart' show LookbackWindow;
import 'package:battery_reader/main.dart';
import 'package:battery_reader/metrics.dart';
import 'package:battery_reader/nav.dart' show gRouteTracker;
import 'package:battery_reader/sections/battery_header_line.dart';
import 'package:battery_reader/sections/pack_section.dart';
import 'package:battery_reader/sections/section_card.dart';
import 'package:battery_reader/sections/trends_section.dart';
import 'package:battery_reader/stale.dart';
import 'package:battery_reader/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// The test font advances a full em per glyph (about twice Roboto), so the
/// layouts are checked at half scale like the #68 tests; every expected
/// height below is derived from a reference text line at the SAME scale.
const double kScale = 0.5;

Future<void> view(WidgetTester tester, double w, double h) async {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> pumpFor(WidgetTester tester, Duration total) async {
  var left = total;
  const step = Duration(milliseconds: 100);
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

Widget app(Widget home, {double scale = kScale, bool shell = false}) =>
    MaterialApp(
      navigatorKey: gNavKey,
      navigatorObservers: shell ? [gRouteTracker] : const [],
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

const refKey = Key('ref-line');

/// One body-text line (the default text style) at the pumped scale.
double refLine(WidgetTester tester) =>
    tester.getSize(find.byKey(refKey)).height;

Rect rectOf(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The rows of [of] are each one [line] tall and touch (0 px between).
void expectOneLineRows(WidgetTester tester, Finder of, double line) {
  final rows = find.descendant(of: of, matching: find.byType(KvRow));
  expect(rows, findsWidgets);
  Rect? prev;
  for (final e in rows.evaluate()) {
    final r = rectOf(e);
    expect(r.height, closeTo(line, 0.5), reason: 'one text line per row');
    if (prev != null) {
      expect(r.top - prev.bottom, closeTo(0, 1.01),
          reason: '0-1 px between rows');
    }
    prev = r;
  }
}

/// The height a [SectionCard] of [rows] one-line rows must have: margin 2+2,
/// padding 4 above + 6 below, the title line, the 5 px rule, the rows.
double cardHeight(double title, double line, int rows) =>
    4 + 10 + title + kTitleRuleHeight + rows * line;

BatteryManager demoManager() {
  final m =
      BatteryManager(transport: NoopTransport(), fleetStore: FakeFleetStore());
  m.startDemoFleet();
  return m;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the compact constants are the #3 spec', () {
    expect(kCardPadding, const EdgeInsets.fromLTRB(6, 4, 6, 6));
    expect(kCardMargin, const EdgeInsets.all(2)); // 4 px between cards
    expect(kTitleRuleHeight, 5);
    expect(sectionPadding(false), kCardPadding);
    expect(sectionPadding(true), kCardPadding, reason: 'phone == desktop');
    expect(SparkRow.lineHeight, 20);
  });

  for (final scale in [kScale, 1.0]) {
    testWidgets(
        'KvRow, SectionCard and SparkRow are one text line '
        '(text scale $scale)', (tester) async {
      await view(tester, 360, 1200);
      await tester.pumpWidget(app(
          scale: scale,
          const Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Ag', key: refKey),
                SectionCard('First', [
                  KvRow('SOC', '61%'),
                  KvRow('Voltage', '12.10 V', stale: true),
                  KvRow('EFC', '0.00', tooltip: 'Equivalent full cycles'),
                ]),
                SectionCard('Second', [KvRow('Temp A', '30 °C')]),
                KvRow.info('Name', 'JBD-1234'),
                SparkRow(
                  label: 'Current',
                  value: '-22.0 A out',
                  intervals: [],
                  fromMs: 0,
                  toMs: 1000,
                  color: Colors.teal,
                ),
              ],
            ),
          )));
      final line = refLine(tester);
      expect(line, closeTo(14 * 1.43 * scale, 0.5));

      // Rows: one line each, touching.
      for (final e in find.byType(SectionCard).evaluate()) {
        expectOneLineRows(tester, find.byWidget(e.widget), line);
      }
      // The info row: one line of its 13 px type.
      expect(tester.getSize(find.byType(KvRow).last).height,
          closeTo(13 * 1.43 * scale, 1.0),
          reason: 'the info row too');

      // Section title: the same one-line height as a row.
      final title = tester.getSize(find.text('First')).height;
      expect(title, closeTo(line, 0.5));

      // Card: exact compact geometry, and 4 px between neighbours.
      final a = tester.getRect(find.byType(SectionCard).first);
      final b = tester.getRect(find.byType(SectionCard).last);
      expect(a.height, closeTo(cardHeight(title, line, 3), 0.5));
      expect(b.height, closeTo(cardHeight(title, line, 1), 0.5));
      final aCard = tester.getRect(find
          .descendant(
              of: find.byType(SectionCard).first,
              matching: find.byType(Material))
          .first);
      final bCard = tester.getRect(find
          .descendant(
              of: find.byType(SectionCard).last,
              matching: find.byType(Material))
          .first);
      expect(bCard.top - aCard.bottom, 4, reason: '4 px between cards');
      expect(tester.getTopLeft(find.text('First')).dy - aCard.top, 4,
          reason: '4 px above the title');

      // Sparkline row: exactly one line tall.
      expect(tester.getSize(find.byType(SparkRow)).height,
          closeTo(SparkRow.lineHeight * scale, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  for (final desktop in [false, true]) {
    testWidgets(
        'the ${desktop ? 'desktop grid (1280 px)' : 'phone page (360 px)'}: '
        'one-line rows, exact card heights, no spacer rows', (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: SharedPreferences.getInstance);
      final conn = manager.batteries.first;
      await tester.pumpWidget(const SizedBox());
      await pumpFor(tester, const Duration(seconds: 2));
      await view(tester, desktop ? 1280 : 360, 5000);
      await tester.pumpWidget(app(Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Ag', key: refKey),
            Expanded(
              child: desktop
                  ? BatteryDetailView(
                      conn: conn,
                      manager: manager,
                      aliases: aliases,
                      arrangement: DetailArrangement.grid,
                      dense: true)
                  : BatteryDetailView(
                      conn: conn, manager: manager, aliases: aliases),
            ),
          ],
        ),
      )));
      await tester.pump();
      await tester.pump();
      final line = refLine(tester);
      final title = tester.getSize(find.text('Pack')).height;
      expect(title, closeTo(line, 0.5));

      for (final s in DetailSection.values) {
        final f = find.ancestor(
            of: find.text(switch (s) {
              DetailSection.pack => 'Pack',
              DetailSection.capacity => 'Capacity',
              DetailSection.cells => 'Cells',
              DetailSection.temperature => 'Temperature',
              DetailSection.gates => 'Gates & status',
            }),
            matching: find.byType(SectionCard));
        expectOneLineRows(tester, f, line);
      }
      // The Pack card is exactly title + rule + its rows (unless the grid
      // stretches it to its neighbour's height).
      final packRows = detailRows(DetailSection.pack).length;
      final pack = tester.getRect(find.byType(PackSection));
      if (desktop) {
        expect(pack.height,
            greaterThanOrEqualTo(cardHeight(title, line, packRows) - 0.5));
      } else {
        expect(pack.height, closeTo(cardHeight(title, line, packRows), 0.5));
      }
      // Every spark row is one line.
      for (final e in find.byType(SparkRow).evaluate()) {
        expect(rectOf(e).height, closeTo(SparkRow.lineHeight * kScale, 0.01));
      }
      // No spacer rows: on the phone the Trends card follows the header
      // directly; the page padding is the one compact [kPagePadding].
      if (!desktop) {
        expect(tester.getTopLeft(find.byType(TrendsSection)).dy,
            tester.getBottomLeft(find.byType(BatteryHeaderLine)).dy);
      }
      final list = tester.widget<ListView>(find.descendant(
          of: find.byType(BatteryDetailView), matching: find.byType(ListView)));
      expect(list.padding, kPagePadding);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      manager.disposeAll();
      await tester.pump();
    });
  }

  for (final w in [320.0, 360.0, 412.0]) {
    testWidgets(
        '$w px: the detail page and a stale Trends title row do not '
        'overflow', (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: SharedPreferences.getInstance);
      final conn = manager.batteries.first;
      await tester.pumpWidget(const SizedBox());
      await pumpFor(tester, const Duration(seconds: 2));
      await view(tester, w, 5000);
      await tester.pumpWidget(app(
          BatteryDetailPage(conn: conn, manager: manager, aliases: aliases)));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TrendsSection), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The window selector shares the title line with a last-known caption.
      final now = DateTime.now();
      await tester.pumpWidget(app(Scaffold(
        body: TrendsSection(
          window: LookbackWindow.h24,
          onWindow: (_) {},
          series: const {},
          fromMs: 0,
          toMs: 1000,
          conn: conn,
          logging: 'Logging off — database not open',
          stale: Staleness(
              lastDataMs: now.millisecondsSinceEpoch - 3600 * 1000,
              now: () => now),
        ),
      )));
      await tester.pump();
      expect(find.textContaining('last known'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      manager.disposeAll();
      await tester.pump();
    });
  }

  for (final w in [320.0, 360.0, 412.0, 1280.0]) {
    testWidgets(
        '$w px: the app shell (list cards 4 px apart) does not '
        'overflow', (tester) async {
      SharedPreferences.setMockInitialValues({'demo_mode_v1': true});
      await view(tester, w, 800);
      await tester.pumpWidget(app(const AdaptiveScaffold(), shell: true));
      await pumpFor(tester, const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
      final cards = find.byType(SummaryCard);
      expect(cards, findsWidgets);
      final card = tester.widget<Card>(
          find.descendant(of: cards.first, matching: find.byType(Card)));
      expect(card.margin, kCardMargin);
      if (w >= 900) {
        // The desktop pane shows the selected pack's detail: no overflow.
        expect(find.byType(BatteryDetailView), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
