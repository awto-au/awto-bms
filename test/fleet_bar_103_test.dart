/// GitHub #103: the fleet-total panel puts its key figures INSIDE the SOC
/// bar on one line — "93%  ·  186.0 / 200.0 Ah  ·  0 W  0.0 A" — and folds
/// Status, Switches and Offline members into one line under it, so the
/// panel is as short as possible (phone list and desktop left pane alike).
///
///  * the SOC and the Ah / W / A figures are drawn inside the [SocBar], which
///    has the per-pack bar's geometry ([kSocBarHeight] phone,
///    [kSocBarHeightDense] dense);
///  * Total capacity / Total remaining / Status / Switches / Offline members
///    are no longer rows of their own, and the lifetime totals are one
///    "Lifetime" line instead of a sub-header plus three rows;
///  * with nothing live the bar figures are last-known, in the stale style
///    (#71), with a dimmed fill; live again -> normal colours;
///  * no overflow at 320 / 360 / 412 px (phone) or in the 340 px desktop
///    pane of a 1280 px window, and the figures stay inside the bar.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart' show AggregateTotals;
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/desktop_shell.dart' show kLeftPaneWidth;
import 'package:battery_reader/main.dart';
import 'package:battery_reader/stale.dart';
import 'package:battery_reader/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_layout_68_test.dart' show kTestFontScale, view;
import 'fakes.dart';

BatteryConnection member(String serial,
    {bool streaming = true,
    bool connected = true,
    double current = 0,
    ChargeState cs = ChargeState.idle,
    double full = 50,
    double remaining = 46.5,
    int dataAgeMs = 15000}) {
  final c = BatteryConnection(profile: DeviceProfile.sphere);
  c.state
    ..serial = serial
    ..fullAh = full
    ..remainingAh = remaining
    ..packVoltage = 52
    ..packCurrent = current
    ..power = current * 52
    ..chargeState = cs
    ..chargeMos = true
    ..dischargeMos = true;
  c.connState = connected ? ConnState.connected : ConnState.disconnected;
  c.isRemembered = true;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (streaming && connected) c.lastTelemetryMs = now;
  c.lastDataMs = now - dataAgeMs;
  return c;
}

/// Four 50 Ah packs at 46.5 Ah (186.0 / 200.0 Ah, 93 %); JS-D offline.
BatteryManager fleet({bool live = true}) {
  final m =
      BatteryManager(transport: NoopTransport(), fleetStore: FakeFleetStore());
  for (final c in [
    member('JS-A', streaming: live, current: 10, cs: ChargeState.charging),
    member('JS-B', streaming: live, current: 5, cs: ChargeState.charging),
    member('JS-C', streaming: live),
    member('JS-D', connected: false),
  ]) {
    m.batteries.add(c);
    m.setInFleet(c, true);
  }
  return m;
}

Widget panel(BatteryManager m,
        {bool dense = false,
        double? width,
        double textScale = kTestFontScale}) =>
    MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: FleetTotal(manager: m, dense: dense),
          ),
        ),
      ),
    );

Finder inBar(Finder f) => find.descendant(of: find.byType(SocBar), matching: f);

void main() {
  group('#103 fleet bar: figures inside the bar, one line', () {
    testWidgets('SOC and Ah / W / A sit inside the bar; the old rows are gone',
        (tester) async {
      await view(tester, 360, 800);
      final m = fleet();
      await tester.pumpWidget(panel(m));
      expect(tester.takeException(), isNull);

      expect(find.byType(SocBar), findsOneWidget);
      final soc =
          tester.widget<Text>(inBar(find.byKey(const Key('fleet-bar-soc'))));
      expect(soc.data, '93%');
      final figures = tester
          .widget<Text>(inBar(find.byKey(const Key('fleet-bar-figures'))));
      expect(figures.data, '186.0 / 200.0 Ah  ·  780 W in  15.0 A');
      expect(figures.maxLines, 1);
      // ONE line: the SOC and the figures share a baseline row in the bar.
      final socBox = tester.getRect(find.byKey(const Key('fleet-bar-soc')));
      final figBox = tester.getRect(find.byKey(const Key('fleet-bar-figures')));
      expect((socBox.center.dy - figBox.center.dy).abs(), lessThan(2));
      expect(figBox.left, greaterThan(socBox.right));

      // Folded: none of the old KvRows remain in the live part of the panel.
      for (final k in const [
        'Status',
        'Switches',
        'Total capacity',
        'Total remaining',
        'Offline members',
      ]) {
        expect(
            find.byWidgetPredicate((w) => w is KvRow && w.k == k), findsNothing,
            reason: '"$k" is folded into the bar / status line');
      }
      // The folded status line: status, switch counts, offline count.
      expect(tester.widget<Text>(find.byKey(const Key('fleet-status'))).data,
          'Charging');
      expect(tester.widget<Text>(find.byKey(const Key('fleet-switches'))).data,
          'Charge 4/4 on  ·  Output 4/4 on');
      expect(tester.widget<Text>(find.byKey(const Key('fleet-offline'))).data,
          '1 of 4 offline');
      expect(
          find.byWidgetPredicate((w) =>
              w is Tooltip &&
              w.message == 'Offline members are excluded from live power'),
          findsOneWidget);
      // Status, switches and offline sit on the bar's next line(s), directly
      // under it — no row labels, no extra gaps.
      final bar = tester.getRect(find.byType(SocBar));
      final status = tester.getRect(find.byKey(const Key('fleet-status')));
      expect(status.top - bar.bottom, lessThanOrEqualTo(6));
      // Live: normal colours, no caption.
      expect(soc.style!.color, isNot(kStale));
      expect(figures.style!.color, isNot(kStale));
      expect(find.byType(StaleCaption), findsNothing);

      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });

    testWidgets('the bar has the per-pack geometry (shared constants)',
        (tester) async {
      await view(tester, 1280, 800);
      final m = fleet();
      await tester.pumpWidget(panel(m, width: 360));
      expect(tester.widget<SocBar>(find.byType(SocBar)).height, kSocBarHeight);
      expect(tester.getSize(find.byType(SocBar)).height, kSocBarHeight);
      await tester.pumpWidget(panel(m, width: kLeftPaneWidth, dense: true));
      expect(tester.widget<SocBar>(find.byType(SocBar)).height,
          kSocBarHeightDense);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });

    testWidgets(
        'nothing live: the bar figures are last-known in the stale '
        'style, fill dimmed, one caption; never dashes', (tester) async {
      await view(tester, 360, 800);
      final m = fleet(live: false);
      await tester.pumpWidget(panel(m));
      expect(tester.takeException(), isNull);
      final soc = tester.widget<Text>(find.byKey(const Key('fleet-bar-soc')));
      final figures =
          tester.widget<Text>(find.byKey(const Key('fleet-bar-figures')));
      expect(soc.data, '93%');
      expect(figures.data, '186.0 / 200.0 Ah');
      expect(soc.style!.color, kStale);
      expect(figures.style!.color, kStale);
      expect(
          tester
              .widget<Text>(find.byKey(const Key('fleet-status')))
              .style!
              .color,
          kStale);
      expect(
          tester
              .widget<Text>(find.byKey(const Key('fleet-switches')))
              .style!
              .color,
          kStale);
      final bar = tester.widget<SocBar>(find.byType(SocBar));
      expect(bar.fill.a, lessThan(0.5), reason: 'dimmed like a silent card');
      expect(find.byType(StaleCaption), findsOneWidget);
      expect(find.text('—'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();

      // Live again: normal colours, full fill.
      final m2 = fleet();
      await tester.pumpWidget(panel(m2));
      expect(
          tester
              .widget<Text>(find.byKey(const Key('fleet-bar-soc')))
              .style!
              .color,
          isNot(kStale));
      expect(tester.widget<SocBar>(find.byType(SocBar)).fill.a, 1.0);
      await tester.pumpWidget(const SizedBox());
      m2.disposeAll();
    });

    testWidgets('never-known capacity reads a plain dash, not a stale one',
        (tester) async {
      await view(tester, 360, 800);
      final m = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      final never = BatteryConnection(profile: DeviceProfile.sphere);
      never.state.serial = 'JS-N';
      never.isRemembered = true;
      m.batteries.add(never);
      m.setInFleet(never, true);
      await tester.pumpWidget(panel(m));
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.byKey(const Key('fleet-bar-soc'))).data,
          '—');
      expect(
          tester.widget<Text>(find.byKey(const Key('fleet-bar-figures'))).data,
          '—');
      expect(find.text('No data'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });

    testWidgets(
        'lifetime totals are ONE line headed "Lifetime", not four '
        'rows', (tester) async {
      await view(tester, 412, 800);
      final m = fleet();
      // #121: the totals have loaded (all zero here) — the real line shows.
      for (final c in m.fleetMembers) {
        m.debugCacheLifetimeTotals(c.state.serial!, const AggregateTotals());
      }
      await tester.pumpWidget(panel(m));
      expect(tester.takeException(), isNull);
      expect(find.byType(KvRow), findsNothing,
          reason: 'no label/value rows left in the fleet panel');
      expect(find.text('Lifetime totals'), findsNothing);
      final line = find.byKey(const Key('fleet-lifetime'));
      expect(find.descendant(of: line, matching: find.text('Lifetime')),
          findsOneWidget);
      expect(find.descendant(of: line, matching: find.text('0.0 Ah in')),
          findsOneWidget);
      expect(find.descendant(of: line, matching: find.text('0.0 Ah out')),
          findsOneWidget);
      expect(find.descendant(of: line, matching: find.text('0.00 EFC')),
          findsOneWidget);
      // One line at 412 px: every item shares the label's row.
      final label = tester
          .getRect(find.descendant(of: line, matching: find.text('Lifetime')));
      final last = tester.getRect(
          find.descendant(of: line, matching: find.text('0.00 EFC')));
      expect((label.center.dy - last.center.dy).abs(), lessThan(2));
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });

    for (final w in const [320.0, 360.0, 412.0]) {
      testWidgets(
          'phone ${w.toInt()} px: no overflow, the figures stay '
          'inside the bar', (tester) async {
        await view(tester, w, 800);
        for (final live in const [true, false]) {
          final m = fleet(live: live);
          // Both the proportional-font approximation and the (twice as wide)
          // raw test font: the bar line scales down, the rest wraps.
          for (final scale in const [kTestFontScale, 1.0]) {
            await tester.pumpWidget(panel(m, textScale: scale));
            expect(tester.takeException(), isNull,
                reason: 'live=$live scale=$scale');
            final bar = tester.getRect(find.byType(SocBar));
            final fig =
                tester.getRect(find.byKey(const Key('fleet-bar-figures')));
            final soc = tester.getRect(find.byKey(const Key('fleet-bar-soc')));
            expect(fig.right, lessThanOrEqualTo(bar.right + 0.5));
            expect(soc.left, greaterThanOrEqualTo(bar.left));
            expect(fig.left, greaterThanOrEqualTo(soc.right));
            expect(fig.top, greaterThanOrEqualTo(bar.top - 0.5));
            expect(fig.bottom, lessThanOrEqualTo(bar.bottom + 0.5));
          }
          await tester.pumpWidget(const SizedBox());
          m.disposeAll();
        }
      });
    }

    testWidgets(
        'desktop 1280 px: the dense panel in the 340 px left pane, '
        'no overflow', (tester) async {
      await view(tester, 1280, 800);
      final m = fleet(live: false);
      await tester.pumpWidget(panel(m,
          dense: true, width: kLeftPaneWidth, textScale: kTestFontScale));
      expect(tester.takeException(), isNull);
      final bar = tester.getRect(find.byType(SocBar));
      final fig = tester.getRect(find.byKey(const Key('fleet-bar-figures')));
      expect(bar.width, lessThanOrEqualTo(kLeftPaneWidth));
      expect(fig.right, lessThanOrEqualTo(bar.right + 0.5));
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });
  });
}
