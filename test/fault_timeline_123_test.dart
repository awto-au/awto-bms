/// GitHub #123: the fault / alarm timeline shows every entry to the
/// millisecond (start → end · duration, in the raw log's stamp format) and
/// lives on the battery DETAIL page — merged into the shared Alarm events
/// section, phone and desktop alike — not on the Charts page.
library;

import 'package:battery_reader/alarm_events.dart';
import 'package:battery_reader/alarm_events_view.dart';
import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_charts.dart';
import 'package:battery_reader/battery_detail.dart';
import 'package:battery_reader/battery_log.dart' show Flags;
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/fmt.dart';
import 'package:battery_reader/intervals.dart';
import 'package:battery_reader/nav.dart' show gNavKey;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

int at(int d, int h, int m, int s, int ms) =>
    DateTime(2026, 9, d, h, m, s, ms).millisecondsSinceEpoch;

AlarmEvent ev(int atMs, String transition,
        {int? durationMs, int byte = 2, int? id}) =>
    AlarmEvent(
      id: id,
      serial: 'JS-2C14B8',
      atMs: atMs,
      frame: 'current',
      byteIndex: byte,
      bitName: alarmBitName('current', byte),
      transition: transition,
      fromValue: transition == AlarmEvent.set ? 0 : 1,
      toValue: transition == AlarmEvent.set ? 1 : 0,
      durationMs: durationMs,
      packI: 0.0,
      packV: 13.2,
      chgMos: 0,
      disMos: 0,
      lastTxLabel: 'Output ON',
      sinceLastTxMs: 500,
    );

Future<void> pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
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

/// Text scaled like the #68 layout tests (the test font is ~2x Roboto).
Widget app(Widget home) => MaterialApp(
      navigatorKey: gNavKey,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.5)),
        child: child!,
      ),
      home: home,
    );

void main() {
  group('#123 formatter', () {
    test('same day: full start, time-only end, duration to the ms', () {
      expect(fmtWindowMs(at(21, 15, 6, 59, 329), at(21, 15, 7, 1, 42)),
          '2026-09-21 15:06:59.329 → 15:07:01.042 · 1.713 s');
    });

    test('crossing midnight: both stamps carry the date', () {
      expect(fmtWindowMs(at(21, 23, 59, 59, 500), at(22, 0, 0, 1, 250)),
          '2026-09-21 23:59:59.500 → 2026-09-22 00:00:01.250 · 1.750 s');
    });

    test('durations keep three decimals at every magnitude', () {
      expect(fmtDurationMs(0), '0.000 s');
      expect(fmtDurationMs(7), '0.007 s');
      expect(fmtDurationMs(59999), '59.999 s');
      expect(fmtDurationMs(60000), '1 min 00.000 s');
      expect(fmtDurationMs(3723456), '1 h 02 min 03.456 s');
      expect(fmtDurationMs(-5), '0.000 s');
    });

    test('sub-millisecond time truncates exactly as the raw log stamps it', () {
      final d = DateTime(2026, 9, 21, 15, 6, 59, 329, 999);
      expect(fmtStamp(d), '2026-09-21 15:06:59.329');
      // The window uses the same stamp, so the two always match.
      expect(fmtWindowMs(d.millisecondsSinceEpoch, at(21, 15, 7, 1, 42)),
          startsWith('${fmtStamp(d)} → '));
    });
  });

  group('#123 alarm windows (set paired with its clear)', () {
    test('a set and its clear make ONE window with the set snapshot', () {
      final set =
          ev(at(21, 15, 6, 59, 329), AlarmEvent.set, durationMs: 1713, id: 1);
      final clr =
          ev(at(21, 15, 7, 1, 42), AlarmEvent.cleared, durationMs: 1713, id: 2);
      final w = alarmWindows([clr, set]).single;
      expect(w.startMs, set.atMs);
      expect(w.endMs, clr.atMs);
      expect(w.open, isFalse);
      expect(
          w.describe(),
          '2026-09-21 15:06:59.329 → 15:07:01.042 · 1.713 s  Short circuit '
          "protection — 0.0 A · 13.2 V · MOS off · 0.5 s after 'Output ON'");
      expect(w.snapshotText().split('\n'), hasLength(2));
    });

    test('a bit still set, and a clear whose set is not loaded', () {
      final open = ev(at(21, 16, 0, 0, 5), AlarmEvent.set, byte: 3);
      final orphan =
          ev(at(21, 14, 0, 0, 100), AlarmEvent.cleared, durationMs: 2100);
      final lost = ev(at(21, 13, 0, 0, 0), AlarmEvent.cleared, byte: 4);
      final ws = alarmWindows([open, orphan, lost]);
      expect(ws.map((w) => w.sortMs), [
        open.atMs, orphan.atMs - 2100, lost.atMs, // newest first
      ]);
      expect(ws[0].open, isTrue);
      expect(ws[0].describe(),
          startsWith('2026-09-21 16:00:00.005 → no clear recorded  '));
      expect(ws[1].describe(),
          startsWith('2026-09-21 13:59:58.000 → 14:00:00.100 · 2.100 s  '));
      expect(ws[2].describe(),
          startsWith('set before the record → 2026-09-21 13:00:00.000  '));
    });

    test('bytes pair independently; newest window first', () {
      final ws = alarmWindows([
        ev(at(21, 10, 0, 3, 0), AlarmEvent.cleared, byte: 2),
        ev(at(21, 10, 0, 2, 0), AlarmEvent.cleared, byte: 3),
        ev(at(21, 10, 0, 1, 0), AlarmEvent.set, byte: 3),
        ev(at(21, 10, 0, 0, 0), AlarmEvent.set, byte: 2),
      ]);
      expect(ws, hasLength(2));
      expect(ws[0].bitName, alarmBitName('current', 3));
      expect(ws[0].endMs! - ws[0].startMs!, 1000);
      expect(ws[1].endMs! - ws[1].startMs!, 3000);
    });
  });

  group('#123 section: band + ms list, phone and desktop', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('the Alarm events section draws the band and the window rows',
        (tester) async {
      final from = at(21, 15, 0, 0, 0), to = at(21, 16, 0, 0, 0);
      final set = ev(at(21, 15, 6, 59, 329), AlarmEvent.set, durationMs: 1713);
      final clr =
          ev(at(21, 15, 7, 1, 42), AlarmEvent.cleared, durationMs: 1713);
      final flags = [
        ReadingInterval(
            serial: 'JS-2C14B8',
            metric: 'flags',
            startMs: from,
            endMs: at(21, 15, 30, 0, 0),
            valueNum: 0),
        ReadingInterval(
            serial: 'JS-2C14B8',
            metric: 'flags',
            startMs: at(21, 15, 30, 0, 0),
            endMs: at(21, 15, 31, 0, 0),
            valueNum: Flags.faultCurrent.toDouble()),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            AlarmEventsSection(
              serial: 'JS-2C14B8',
              events: [clr, set],
              total: 2,
              timeline: FaultTimeline(
                  fromMs: from, toMs: to, flags: flags, windowLabel: '1 h'),
            ),
          ]),
        ),
      ));
      expect(find.byType(FaultTimelineStrip), findsOneWidget);
      expect(
          find.text('2026-09-21 15:06:59.329 → 15:07:01.042 · 1.713 s  '
              'Short circuit protection — 0.0 A · 13.2 V · MOS off · '
              "0.5 s after 'Output ON'"),
          findsOneWidget);
      expect(find.textContaining('1 h · red alarm · grey offline'),
          findsOneWidget);
      final painter = tester
          .widgetList<CustomPaint>(find.descendant(
              of: find.byType(FaultTimelineStrip),
              matching: find.byType(CustomPaint)))
          .map((c) => c.painter)
          .whereType<FaultTimelinePainter>()
          .single;
      // The logged flags fault AND the event window are both drawn red; the
      // uncovered tail (15:31 -> 16:00) is grey offline.
      expect(
          painter.active,
          containsAll(
              [(flags[1].startMs, flags[1].endMs), (set.atMs, clr.atMs)]));
      expect(painter.offline, [(at(21, 15, 31, 0, 0), to)]);
    });

    testWidgets(
        'phone page and desktop pane both carry the band inside '
        'Alarm events', (tester) async {
      final manager = demoManager();
      final aliases = AliasStore(prefs: SharedPreferences.getInstance);
      final conn = manager.batteries.first;
      await tester.pumpWidget(const SizedBox());
      await pumpFor(tester, const Duration(seconds: 2));

      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(360, 8000);
      await tester.pumpWidget(app(
          BatteryDetailPage(conn: conn, manager: manager, aliases: aliases)));
      await tester.pump();
      await tester.pump();
      expect(
          find.descendant(
              of: find.byType(AlarmEventsSection),
              matching: find.byType(FaultTimelineStrip)),
          findsOneWidget);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(1280, 8000);
      await tester.pumpWidget(app(Scaffold(
          body: BatteryDetailView(
              conn: conn,
              manager: manager,
              aliases: aliases,
              arrangement: DetailArrangement.grid,
              dense: true))));
      await tester.pump();
      await tester.pump();
      expect(
          find.descendant(
              of: find.byType(AlarmEventsSection),
              matching: find.byType(FaultTimelineStrip)),
          findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      manager.disposeAll();
      await tester.pump();
    });

    testWidgets('the Charts page no longer has a fault timeline card',
        (tester) async {
      final manager = demoManager();
      final conn = manager.batteries.first;
      await tester.pumpWidget(const SizedBox());
      await pumpFor(tester, const Duration(seconds: 3));
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(400, 12000); // every card built
      await tester
          .pumpWidget(app(BatteryChartsPage(serial: conn.state.serial!)));
      await pumpFor(tester, const Duration(seconds: 2));
      expect(find.text('Cell voltages'), findsOneWidget);
      expect(find.text('Charge state / load'), findsOneWidget);
      expect(find.text('Fault / alarm timeline'), findsNothing);
      expect(find.byType(FaultTimelineStrip), findsNothing);

      await tester.pumpWidget(const SizedBox());
      manager.disposeAll();
      await tester.pump();
    });
  });
}
