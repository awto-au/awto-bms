/// GitHub #107: the Cells section shows its aggregates as TWO one-line rows —
/// `Sum / Average` and `Min / Max / Delta` — instead of five, on the phone
/// page and the desktop pane alike (one shared [CellsSection]). Last-known
/// values stay in the stale red; never-known ones stay a plain dash; the
/// rows fit a 360 px phone and the dense desktop card without overflow.
library;

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/main.dart';
import 'package:battery_reader/sections/cells_section.dart';
import 'package:battery_reader/stale.dart';
import 'package:battery_reader/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_layout_68_test.dart' show app, demoManager, pumpFor, view;

BatteryConnection pack() {
  final c = BatteryConnection(profile: DeviceProfile.sphere);
  c.state
    ..serial = 'JS-107'
    ..cellsMv = [3312, 3320, 3338, 3318]
    ..cellSum = 13.288
    ..cellMax = 3.338
    ..cellMin = 3.312
    ..cellDiff = 0.026
    ..cellAvg = 3.322;
  return c;
}

List<KvRow> kvRows(WidgetTester tester) =>
    tester.widgetList<KvRow>(find.byType(KvRow)).toList();

/// The KvRow holding [value] is one text line: its height is no taller than
/// a plain single-value row's.
void expectOneLine(WidgetTester tester, String label) {
  final row = find.ancestor(of: find.text(label), matching: find.byType(KvRow));
  final labelH = tester.getSize(find.text(label)).height;
  expect(tester.getSize(row).height, lessThan(labelH * 2 + 8),
      reason: '"$label" is one line');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'demo_mode_v1': true});
  });

  testWidgets('live: two rows, three values on one line', (tester) async {
    await view(tester, 360, 1200);
    await tester.pumpWidget(
        app(Scaffold(body: ListView(children: [CellsSection(conn: pack())]))));
    final rows = kvRows(tester);
    expect(rows.map((r) => r.k), ['Sum / Average', 'Min / Max / Delta']);
    expect(
        rows.map((r) => r.v), ['13.29 / 3.322 V', '3.312 / 3.338 / 0.026 V']);
    expect(find.text('Min'), findsNothing);
    expect(find.text('Max'), findsNothing);
    expect(find.text('Delta'), findsNothing);
    expect(find.text('Sum of cells'), findsNothing);
    final v = tester.widget<Text>(find.text('3.312 / 3.338 / 0.026 V'));
    expect(v.style?.color, isNot(kStale));
    expectOneLine(tester, 'Min / Max / Delta');
    expectOneLine(tester, 'Sum / Average');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale: last-known values in stale red, never dashes',
      (tester) async {
    final c = pack()
      ..isRemembered = true
      ..lastDataMs = DateTime.now().millisecondsSinceEpoch - 90000;
    final stale = stalenessOf(c);
    expect(stale, isNotNull);
    await view(tester, 360, 1200);
    await tester.pumpWidget(app(Scaffold(
        body: ListView(children: [CellsSection(conn: c, stale: stale)]))));
    expect(kvRows(tester).every((r) => r.stale), isTrue);
    for (final t in ['13.29 / 3.322 V', '3.312 / 3.338 / 0.026 V']) {
      expect(tester.widget<Text>(find.text(t)).style!.color, kStale, reason: t);
    }
    expect(find.text('—'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('never known: one plain dash, not a stale one', (tester) async {
    final c = BatteryConnection(profile: DeviceProfile.sphere)
      ..isRemembered = true
      ..lastDataMs = DateTime.now().millisecondsSinceEpoch - 90000;
    final stale = stalenessOf(c);
    await view(tester, 360, 1200);
    await tester.pumpWidget(app(Scaffold(
        body: ListView(children: [CellsSection(conn: c, stale: stale)]))));
    expect(kvRows(tester).map((r) => r.v), ['—', '—']);
    for (final d in tester.widgetList<Text>(find.text('—'))) {
      expect(d.style?.color, isNot(kStale));
    }
  });

  testWidgets('narrow: no overflow at 360 px, phone and dense', (tester) async {
    for (final dense in [false, true]) {
      await view(tester, 360, 1200);
      await tester.pumpWidget(app(Scaffold(
          body:
              ListView(children: [CellsSection(conn: pack(), dense: dense)]))));
      expect(tester.takeException(), isNull, reason: 'dense=$dense');
      expectOneLine(tester, 'Min / Max / Delta');
    }
  });

  testWidgets(
      'the whole detail page at 360 px and the desktop pane at '
      '1280 px carry the one-line row without overflow', (tester) async {
    final manager = demoManager();
    await tester.pumpWidget(const SizedBox());
    await pumpFor(tester, const Duration(seconds: 2));
    final conn = manager.batteries.first;
    for (final (w, arrangement, dense) in [
      (360.0, DetailArrangement.stacked, false),
      (1280.0, DetailArrangement.grid, true),
    ]) {
      await view(tester, w, 6000);
      await tester.pumpWidget(app(Scaffold(
          body: BatteryDetailView(
              conn: conn,
              manager: manager,
              aliases: AliasStore(prefs: SharedPreferences.getInstance),
              arrangement: arrangement,
              dense: dense))));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$w px');
      expect(find.text('Min / Max / Delta'), findsOneWidget, reason: '$w px');
      expectOneLine(tester, 'Min / Max / Delta');
    }
    await tester.pumpWidget(const SizedBox());
    manager.disposeAll();
    await tester.pump();
  });
}
