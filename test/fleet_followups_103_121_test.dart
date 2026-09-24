/// GitHub #103 follow-ups (after sign-off) and #121, in the fleet-total
/// panel shared by the phone list and the desktop left pane:
///
///  * with no fleet pack live, the bar hides W and A (never "0 W  0.0 A");
///  * the stale rule is ONE manager rule ([BatteryManager.fleetShowsLastKnown])
///    that no longer needs a known charge state, so packs restored from their
///    records without one (the Windows case) turn the bar stale red too;
///  * the figure bars (fleet and per-pack) are shorter and their figures are
///    centred vertically;
///  * right after start the Lifetime line is a neutral "Lifetime …" until the
///    totals have loaded, never 0.0 Ah (#121).
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart' show AggregateTotals;
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/desktop_shell.dart' show kLeftPaneWidth;
import 'package:battery_reader/last_known.dart';
import 'package:battery_reader/main.dart';
import 'package:battery_reader/stale.dart';
import 'package:battery_reader/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_layout_68_test.dart' show view;
import 'fleet_bar_103_test.dart' show fleet, member, panel;
import 'fakes.dart';

/// Four remembered packs restored from their records the way a restart
/// does, each with a last-known SOC / Ah but NO charge state (BAL_STATUS was
/// never decoded) — what the Windows app showed white with "No data".
Future<BatteryManager> restoredWithoutChargeState() async {
  final store = FakeFleetStore();
  final stamp = DateTime.now().millisecondsSinceEpoch - 8 * 60 * 1000;
  for (final serial in const ['JS-A', 'JS-B', 'JS-C', 'JS-D']) {
    store.saved[serial] = FleetRecord(
      serial: serial,
      soc: 93,
      packVoltage: 52,
      remainingAh: 46.5,
      fullAh: 50,
      lastSeenMs: stamp,
      last: const LastKnownState(soc: 93, remainingAh: 46.5, fullAh: 50),
      lastDataMs: stamp,
    );
  }
  final m = BatteryManager(transport: NoopTransport(), fleetStore: store);
  await m.loadFleetMembership();
  m.materialiseRememberedFleet();
  return m;
}

Rect rectOf(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

void main() {
  group('#103: W and A hidden while nothing is live', () {
    for (final dense in const [false, true]) {
      testWidgets('${dense ? 'desktop' : 'phone'}: Ah only, no W / A',
          (tester) async {
        await view(tester, dense ? 1280 : 360, 800);
        final m = fleet(live: false);
        await tester.pumpWidget(
            panel(m, dense: dense, width: dense ? kLeftPaneWidth : null));
        expect(tester.takeException(), isNull);
        final figures = tester
            .widget<Text>(find.byKey(const Key('fleet-bar-figures')))
            .data!;
        expect(figures, '186.0 / 200.0 Ah');
        expect(figures, isNot(contains(' W')));
        expect(figures, isNot(contains(' A ')));
        expect(find.textContaining(RegExp(r'\d W')), findsNothing);
        expect(find.textContaining(RegExp(r'\d A(?!h)')), findsNothing);
        await tester.pumpWidget(const SizedBox());
        m.disposeAll();
      });
    }

    testWidgets('live again: W and A come back', (tester) async {
      await view(tester, 360, 800);
      final m = fleet();
      await tester.pumpWidget(panel(m));
      expect(
          tester.widget<Text>(find.byKey(const Key('fleet-bar-figures'))).data,
          '186.0 / 200.0 Ah  ·  780 W in  15.0 A');
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });
  });

  group('#103: one stale rule for phone and desktop', () {
    test('restored packs with no charge state count as last-known', () async {
      final m = await restoredWithoutChargeState();
      expect(m.fleetMembers, hasLength(4));
      expect(m.fleetStreamingState, isNull);
      expect(m.fleetLastKnownState, isNull,
          reason: 'the old gate: this was why the bar stayed white');
      expect(m.fleetShowsLastKnown, isTrue);
      m.disposeAll();
    });

    test('a live member means not stale; never-known means not stale', () {
      final live = fleet();
      expect(live.fleetShowsLastKnown, isFalse);
      live.disposeAll();

      final m = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      final never = BatteryConnection(profile: DeviceProfile.sphere)
        ..state.serial = 'JS-N'
        ..isRemembered = true;
      m.batteries.add(never);
      m.setInFleet(never, true);
      expect(m.fleetShowsLastKnown, isFalse);
      m.disposeAll();
    });

    for (final dense in const [true, false]) {
      testWidgets(
          '${dense ? 'desktop pane (dense)' : 'phone'}: restored, all '
          'offline -> stale red bar, dimmed fill, one caption', (tester) async {
        await view(tester, dense ? 1280 : 360, 800);
        final m = await tester.runAsync(restoredWithoutChargeState);
        await tester.pumpWidget(
            panel(m!, dense: dense, width: dense ? kLeftPaneWidth : null));
        expect(tester.takeException(), isNull);
        final soc = tester.widget<Text>(find.byKey(const Key('fleet-bar-soc')));
        expect(soc.data, '93%');
        expect(soc.style!.color, kStale);
        final figures =
            tester.widget<Text>(find.byKey(const Key('fleet-bar-figures')));
        expect(figures.data, '186.0 / 200.0 Ah');
        expect(figures.style!.color, kStale);
        expect(
            tester.widget<SocBar>(find.byType(SocBar)).fill.a, lessThan(0.5));
        expect(find.byType(StaleCaption), findsOneWidget);
        expect(find.text('last known · 8 min ago'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        m.disposeAll();
      });
    }
  });

  group('#103: shorter bars, figures centred vertically', () {
    test('the shared figure-bar geometry is shorter than before', () {
      expect(kSocBarHeight, lessThan(46));
      expect(kSocBarHeightDense, lessThan(26));
    });

    for (final dense in const [false, true]) {
      for (final live in const [true, false]) {
        testWidgets(
            'fleet bar ${dense ? 'dense' : 'phone'} live=$live: SOC and '
            'figures centred', (tester) async {
          await view(tester, dense ? 1280 : 360, 800);
          final m = fleet(live: live);
          await tester.pumpWidget(
              panel(m, dense: dense, width: dense ? kLeftPaneWidth : null));
          expect(tester.takeException(), isNull);
          final bar = tester.getRect(find.byType(SocBar));
          expect(bar.height, dense ? kSocBarHeightDense : kSocBarHeight);
          for (final k in const [
            Key('fleet-bar-soc'),
            Key('fleet-bar-figures'),
          ]) {
            final r = rectOf(tester, k);
            expect((r.center.dy - bar.center.dy).abs(), lessThan(1),
                reason: '$k is vertically centred');
            expect(r.top, greaterThanOrEqualTo(bar.top - 0.5));
            expect(r.bottom, lessThanOrEqualTo(bar.bottom + 0.5));
          }
          await tester.pumpWidget(const SizedBox());
          m.disposeAll();
        });
      }
    }

    for (final dense in const [false, true]) {
      testWidgets(
          'per-pack bar ${dense ? 'dense' : 'phone'}: same height as the '
          'fleet bar, figures centred', (tester) async {
        await view(tester, dense ? 1280 : 360, 800);
        final m = BatteryManager(
            transport: NoopTransport(), fleetStore: FakeFleetStore());
        final c = member('JS-A', current: 10, cs: ChargeState.charging);
        m.batteries.add(c);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(0.5)),
            child: child!,
          ),
          home: Scaffold(
            body: SizedBox(
              width: dense ? kLeftPaneWidth : 360,
              child: SummaryCard(
                conn: c,
                manager: m,
                dense: dense,
                onTap: () {},
                onToggleFleet: () {},
              ),
            ),
          ),
        ));
        expect(tester.takeException(), isNull);
        final barFinder = find.byType(SocBar);
        final bar = tester.getRect(barFinder);
        expect(bar.height, dense ? kSocBarHeightDense : kSocBarHeight);
        final texts =
            find.descendant(of: barFinder, matching: find.byType(Text));
        expect(texts, findsNWidgets(2));
        for (var i = 0; i < 2; i++) {
          final r = tester.getRect(texts.at(i));
          expect((r.center.dy - bar.center.dy).abs(), lessThan(1),
              reason: 'bar text $i is vertically centred');
        }
        await tester.pumpWidget(const SizedBox());
        m.disposeAll();
      });
    }
  });

  group('#121: Lifetime never reads zeros before the totals load', () {
    testWidgets('at start: a neutral "Lifetime …", no 0.0 Ah / EFC',
        (tester) async {
      await view(tester, 360, 800);
      final m = fleet();
      expect(m.fleetAggregateLoaded, isFalse);
      await tester.pumpWidget(panel(m));
      expect(tester.takeException(), isNull);
      final line = find.byKey(const Key('fleet-lifetime'));
      expect(find.descendant(of: line, matching: find.text('Lifetime')),
          findsOneWidget);
      expect(find.byKey(const Key('fleet-lifetime-loading')), findsOneWidget);
      expect(find.textContaining('Ah in'), findsNothing);
      expect(find.textContaining('Ah out'), findsNothing);
      expect(find.textContaining('EFC'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });

    testWidgets('partly loaded is still loading; all loaded shows the sum',
        (tester) async {
      await view(tester, 360, 800);
      final m = fleet();
      m.debugCacheLifetimeTotals('JS-A',
          const AggregateTotals(chargeAh: 2.6, dischargeAh: 1.9, efc: 0.05));
      expect(m.fleetAggregateLoaded, isFalse,
          reason: 'a partial sum would read low');
      for (final s in const ['JS-B', 'JS-C', 'JS-D']) {
        m.debugCacheLifetimeTotals(s,
            const AggregateTotals(chargeAh: 1.0, dischargeAh: 0.63, efc: 0.01));
      }
      expect(m.fleetAggregateLoaded, isTrue);
      await tester.pumpWidget(panel(m));
      expect(find.byKey(const Key('fleet-lifetime-loading')), findsNothing);
      expect(find.text('5.6 Ah in'), findsOneWidget);
      expect(find.text('3.8 Ah out'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });
  });
}
