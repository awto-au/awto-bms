/// GitHub #71: a silent / offline pack shows its LAST-KNOWN values in the
/// stale style (red, dimmed, tabular) with ONE "last known · … ago" caption
/// per card / row group — never a wall of dashes. Values that were never
/// known still read "—". The status line keeps its red "No data · <reason>"
/// / "Offline · last seen …" text.
///
///  * [staleFor] / [Staleness] — the pure decision and caption;
///  * [LastKnownState] — capture / JSON round trip / apply, and a FleetRecord
///    carrying it survives the store (restart);
///  * a card whose connection streamed then went silent keeps its values in
///    the stale style with the age caption; a never-seen placeholder shows
///    dashes and no caption;
///  * a restart restores the snapshot into the remembered placeholder
///    (manager -> store -> new manager) and the placeholder renders stale;
///  * the fleet panel's Status / Switches come from last-known values in the
///    stale style when nothing is live.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/health_palette.dart';
import 'package:battery_reader/last_known.dart';
import 'package:battery_reader/live_indicator.dart';
import 'package:battery_reader/main.dart';
import 'package:battery_reader/sections/cells_section.dart';
import 'package:battery_reader/sections/gates_status_section.dart';
import 'package:battery_reader/sections/pack_section.dart';
import 'package:battery_reader/sections/section_card.dart';
import 'package:battery_reader/stale.dart';
import 'package:battery_reader/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'crash_57_test.dart' show pumpFor;
import 'fakes.dart';

const bal = [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21];

/// A fully populated decoded state (what the sections show).
void fill(BatteryState s) {
  s
    ..serial = 'JS-TEST01'
    ..socPercent = 80
    ..remainingAh = 80
    ..fullAh = 100
    ..packVoltage = 53.21
    ..packCurrent = 12.3
    ..power = 654
    ..chargeState = ChargeState.charging
    ..loadConnected = false
    ..chargerConnected = true
    ..cellsMv = [3312, 3320, 3305, 3318]
    ..cellSum = 13.255
    ..cellMax = 3.320
    ..cellMin = 3.305
    ..cellDiff = 0.015
    ..cellAvg = 3.314
    ..temp0 = 21
    ..temp1 = 22
    ..temp2 = 23
    ..temp3 = 24
    ..chipTemperature = 0
    ..cycleCount = 7
    ..timeToFullSec = 3600
    ..timeToEmptySec = 7200
    ..mosOn = true
    ..chargeMos = true
    ..dischargeMos = false
    ..passiveBalancing = false
    ..tempControlGate = 1
    ..smokeGate = 0
    ..heatGate = 0
    ..overTempLatched = true
    ..temperatureAlarmSeen = true
    ..currentAlarmSeen = true
    ..voltageAlarmSeen = true
    ..voltageWarnings = ['Voltage difference alarm']
    ..faultVoltage = true
    ..sleepModeOn = true
    ..firmwareVersion = '1.0.1';
}

/// Every Text on screen whose colour is the stale token.
List<Text> staleTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .where((t) => t.style?.color == kStale)
    .toList();

Widget app(Widget home) => MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(body: home),
    );

void main() {
  group('staleFor / Staleness — the pure decision and caption', () {
    final clock = DateTime.utc(2026, 9, 21, 12);
    DateTime now() => clock;
    final nowMs = clock.millisecondsSinceEpoch;

    test('live (data, not offline) is never stale', () {
      expect(
          staleFor(
              hasData: true, offline: false, lastDataMs: nowMs - 500, now: now),
          isNull);
    });

    test('no data / offline: stale with the age of the last data', () {
      final s = staleFor(
          hasData: false, offline: false, lastDataMs: nowMs - 12000, now: now)!;
      expect(s.ageMs, 12000);
      expect(s.caption, 'last known · 12 s ago');
      final o = staleFor(
          hasData: true,
          offline: true,
          lastDataMs: nowMs - 3 * 24 * 3600 * 1000,
          now: now)!;
      expect(o.caption, 'last known · 3 d ago');
      // No stamp: no age.
      final u = staleFor(
          hasData: false, offline: false, lastDataMs: null, now: now)!;
      expect(u.ageMs, isNull);
      expect(u.caption, 'last known');
    });

    test('the stale token is the fault red at ~75 % opacity', () {
      expect(kStale.toARGB32() & 0xFFFFFF,
          HealthPalette.faultRed.toARGB32() & 0xFFFFFF);
      expect((kStale.a * 100).round(), 75);
      final st = staleFigure(const TextStyle(fontSize: 20, color: Colors.white));
      expect(st.color, kStale);
      expect(st.fontSize, 20);
      expect(st.fontFeatures, contains(const FontFeature.tabularFigures()));
    });
  });

  group('LastKnownState — capture, JSON, apply', () {
    test('captures every section value and round-trips through JSON', () {
      final s = BatteryState();
      fill(s);
      final k = LastKnownState.capture(s, signedCurrent: 12.3);
      expect(k.hasAnyValue, isTrue);
      expect(k.packCurrent, 12.3);
      expect(k.chargeState, ChargeState.charging);
      expect(k.cellsMv, [3312, 3320, 3305, 3318]);
      expect(k.temp3, 24);
      expect(k.chargeMos, isTrue);
      expect(k.dischargeMos, isFalse);
      expect(k.tempControlGate, 1);
      expect(k.overTempLatched, isTrue);
      expect(k.sleepModeOn, isTrue);
      expect(k.firmwareVersion, '1.0.1');
      expect(k.cycleCount, 7);
      expect(k.voltageWarnings, ['Voltage difference alarm']);
      expect(k.faultVoltage, isTrue);
      expect(LastKnownState.fromJson(k.toJson()), k);
      // An all-null capture has no value and restores nothing.
      final empty = LastKnownState.capture(BatteryState());
      expect(empty.hasAnyValue, isFalse);
      expect(LastKnownState.fromJson(empty.toJson()), empty);
    });

    test('applyTo restores into an empty state; never-known stays null', () {
      final src = BatteryState();
      fill(src);
      final k = LastKnownState.capture(src, signedCurrent: -12.3);
      final dst = BatteryState();
      k.applyTo(dst);
      expect(dst.socPercent, 80);
      expect(dst.packVoltage, 53.21);
      expect(dst.packCurrent, 12.3, reason: 'magnitude; the sign is the state');
      expect(dst.chargeState, ChargeState.charging);
      expect(dst.cellsMv, [3312, 3320, 3305, 3318]);
      expect(dst.temp1, 22);
      expect(dst.chargeMos, isTrue);
      expect(dst.dischargeMos, isFalse);
      expect(dst.heatGate, 0);
      expect(dst.overTempLatched, isTrue);
      expect(dst.temperatureAlarmSeen, isTrue);
      expect(dst.voltageWarnings, ['Voltage difference alarm']);
      expect(dst.firmwareVersion, '1.0.1');
      expect(dst.rssi, isNull, reason: 'signal is per link, not restored');
      // A partial snapshot leaves the rest null.
      const partial = LastKnownState(soc: 50, packVoltage: 52.0);
      final d2 = BatteryState();
      partial.applyTo(d2);
      expect(d2.socPercent, 50);
      expect(d2.packVoltage, 52.0);
      expect(d2.packCurrent, isNull);
      expect(d2.cellsMv, isEmpty);
      expect(d2.chargeMos, isNull);
      expect(d2.chargeState, ChargeState.unknown);
    });

    test('FleetRecord carries the snapshot and its stamp through JSON; an '
        'older record without them still loads', () {
      final s = BatteryState();
      fill(s);
      final r = FleetRecord(
        serial: 'JS-TEST01',
        soc: 80,
        fullAh: 100,
        lastSeenMs: 1710000000000,
        last: LastKnownState.capture(s, signedCurrent: 12.3),
        lastDataMs: 1709999990000,
      );
      final back = FleetRecord.fromJson(r.toJson());
      expect(back, r);
      expect(back.last!.cellsMv, [3312, 3320, 3305, 3318]);
      expect(back.lastDataMs, 1709999990000);
      final old = FleetRecord.fromJson(
          const {'serial': 'JS-OLD', 'profile': 'JS', 'soc': 64});
      expect(old.last, isNull);
      expect(old.lastDataMs, isNull);
    });
  });

  group('restart: the snapshot is persisted and restored into the placeholder',
      () {
    test('manager -> store -> new manager: the placeholder holds every value '
        'and its data stamp; a never-seen favourite restores nothing', () async {
      var clock = DateTime.utc(2026, 9, 21, 12);
      final store = FakeFleetStore();
      final m1 = BatteryManager(
          transport: NoopTransport(), fleetStore: store, now: () => clock);
      final c = BatteryConnection(
          profile: DeviceProfile.sphere,
          transport: FakeTransport(),
          now: () => clock);
      fill(c.state);
      c.connState = ConnState.connected;
      c.lastDataMs = clock.millisecondsSinceEpoch;
      m1.batteries.add(c);
      m1.setInFleet(c, true);
      await Future<void>.delayed(Duration.zero);
      final saved = store.saved['JS-TEST01']!;
      expect(saved.last, isNotNull, reason: 'the full snapshot is persisted');
      expect(saved.lastDataMs, clock.millisecondsSinceEpoch);
      expect(saved.last!.temp2, 23);
      expect(saved.last!.firmwareVersion, '1.0.1');
      // A favourite that never decoded a frame: no snapshot.
      final never = BatteryConnection(
          profile: DeviceProfile.sphere, transport: FakeTransport());
      never.state.serial = 'JS-NEVER';
      m1.batteries.add(never);
      m1.setInFleet(never, true);
      await Future<void>.delayed(Duration.zero);
      expect(store.saved['JS-NEVER']!.last, isNull);
      m1.disposeAll();

      // "Restart": a fresh manager loads the store and materialises.
      clock = clock.add(const Duration(days: 3));
      final m2 = BatteryManager(
          transport: NoopTransport(), fleetStore: store, now: () => clock);
      await m2.loadFleetMembership();
      m2.materialiseRememberedFleet();
      final p = m2.batteries.firstWhere((b) => b.state.serial == 'JS-TEST01');
      expect(p.isOffline, isTrue);
      expect(p.lastDataMs, saved.lastDataMs);
      expect(p.state.packVoltage, 53.21);
      expect(p.state.packCurrent, 12.3);
      expect(p.state.chargeState, ChargeState.charging);
      expect(p.signedCurrent, 12.3);
      expect(p.state.cellsMv, [3312, 3320, 3305, 3318]);
      expect(p.state.temp0, 21);
      expect(p.state.chargeMos, isTrue);
      expect(p.state.dischargeMos, isFalse);
      expect(p.state.smokeGate, 0);
      expect(p.state.overTempLatched, isTrue);
      expect(p.state.sleepModeOn, isTrue);
      expect(p.state.firmwareVersion, '1.0.1');
      expect(p.state.cycleCount, 7);
      expect(p.state.voltageWarnings, ['Voltage difference alarm']);
      expect(p.alarmActive, isFalse, reason: 'a restored fault never alarms');
      final st = stalenessOf(p)!;
      expect(st.caption, 'last known · 3 d ago');
      // The never-seen one: dashes, no stamp, no caption.
      final n = m2.batteries.firstWhere((b) => b.state.serial == 'JS-NEVER');
      expect(n.lastDataMs, isNull);
      expect(n.state.packVoltage, isNull);
      expect(stalenessOf(n)!.lastDataMs, isNull);
      // A pre-#71 record (summary only) dates its values from last-seen.
      store.saved = {
        'JS-OLD': FleetRecord(
            serial: 'JS-OLD',
            soc: 64,
            packVoltage: 52.5,
            lastSeenMs: clock.millisecondsSinceEpoch - 60000),
      };
      final m3 = BatteryManager(
          transport: NoopTransport(), fleetStore: store, now: () => clock);
      await m3.loadFleetMembership();
      m3.materialiseRememberedFleet();
      final o = m3.batteries.single;
      expect(o.state.packVoltage, 52.5);
      expect(stalenessOf(o)!.caption, 'last known · 1 min ago');
      m2.disposeAll();
      m3.disposeAll();
    });

    test('persistFleetSnapshot refreshes the snapshot from live telemetry, '
        'throttled', () async {
      var clock = DateTime.utc(2026, 9, 21, 12);
      final store = FakeFleetStore();
      final m = BatteryManager(
          transport: NoopTransport(),
          fleetStore: store,
          now: () => clock,
          recordSaveInterval: const Duration(seconds: 60));
      final c = BatteryConnection(
          profile: DeviceProfile.sphere,
          transport: FakeTransport(),
          now: () => clock);
      fill(c.state);
      c.connState = ConnState.connected;
      c.lastDataMs = clock.millisecondsSinceEpoch;
      m.batteries.add(c);
      m.setInFleet(c, true);
      await Future<void>.delayed(Duration.zero);
      // Nothing changed since the star: no write.
      final saves = store.saveCount;
      m.persistFleetSnapshot();
      await Future<void>.delayed(Duration.zero);
      expect(store.saveCount, saves, reason: 'unchanged');
      // A value changes: written (the first snapshot save is never late).
      c.state.packVoltage = 53.5;
      m.persistFleetSnapshot();
      await Future<void>.delayed(Duration.zero);
      expect(store.saveCount, saves + 1);
      expect(store.saved['JS-TEST01']!.last!.packVoltage, 53.5);
      // Another change within the interval: the in-memory record follows
      // at once, the store only after the throttle.
      clock = clock.add(const Duration(seconds: 10));
      c.state.temp1 = 30;
      m.persistFleetSnapshot();
      expect(m.fleetRecords['JS-TEST01']!.last!.temp1, 30);
      await Future<void>.delayed(Duration.zero);
      expect(store.saveCount, saves + 1, reason: 'throttled');
      expect(store.saved['JS-TEST01']!.last!.temp1, 22);
      clock = clock.add(const Duration(seconds: 61));
      m.persistFleetSnapshot();
      await Future<void>.delayed(Duration.zero);
      expect(store.saveCount, saves + 2);
      expect(store.saved['JS-TEST01']!.last!.temp1, 30);
      expect(store.saved['JS-TEST01']!.last!.packVoltage, 53.5);
      m.disposeAll();
    });
  });

  group('the card: last-known values in the stale style, one caption', () {
    var clock = DateTime.utc(2026, 9, 21, 12);

    BatteryManager manager() =>
        BatteryManager(transport: NoopTransport(), fleetStore: FakeFleetStore());

    /// A connected pack that streamed one cycle with a full state.
    Future<BatteryConnection> streamed(WidgetTester tester) async {
      clock = DateTime.utc(2026, 9, 21, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await tester.runAsync(() => c.connectTo('dev-1', name: 'dev-1'));
      c.parser.addBytes(bal);
      fill(c.state);
      return c;
    }

    Future<void> pumpCard(
            WidgetTester tester, BatteryConnection c, BatteryManager m) =>
        tester.pumpWidget(app(SummaryCard(
          conn: c,
          manager: m,
          onTap: () {},
          onToggleFleet: () {},
        )));

    testWidgets('streams, then goes silent: the values stay, turn stale red, '
        'one "last known · 15 s ago" caption; the status line keeps its '
        'red reason', (tester) async {
      final c = await streamed(tester);
      final m = manager();
      await pumpCard(tester, c, m);
      expect(find.text('53.21 V'), findsOneWidget);
      expect(find.text('+12.3 A in'), findsWidgets);
      expect(staleTexts(tester), isEmpty, reason: 'live: normal colours');
      expect(find.byType(StaleCaption), findsNothing);

      // 15 s of silence, the probe says dormant.
      clock = clock.add(const Duration(seconds: 15));
      c.streamClass = StreamClass.dormant;
      await pumpCard(tester, c, m);
      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(find.text('No data · not streaming — BMS not running'),
          findsOneWidget);
      expect(tester.widget<LiveDot>(find.byType(LiveDot)).color,
          HealthPalette.faultRed);
      // The figures are still there — in the stale style.
      expect(find.text('53.21 V'), findsOneWidget);
      expect(find.text('80%'), findsOneWidget);
      expect(find.text('+12.3 A in'), findsWidgets);
      expect(find.text('+12.3 A in  ·  80.0 Ah'), findsOneWidget);
      final stale = staleTexts(tester).map((t) => t.data).toList();
      expect(stale, containsAll(['53.21 V', '80%', '+12.3 A in  ·  80.0 Ah']));
      expect(stale.where((t) => t == '+12.3 A in').length, 1);
      for (final t in staleTexts(tester)) {
        expect(t.style!.fontFeatures,
            contains(const FontFeature.tabularFigures()),
            reason: 'tabular: ${t.data}');
      }
      // The switch badges: same glyph, stale red.
      final badges =
          tester.widgetList<SwitchBadge>(find.byType(SwitchBadge)).toList();
      expect(badges.length, 2);
      expect(badges.every((b) => b.stale), isTrue);
      expect(find.text('Charge on'), findsOneWidget);
      expect(find.text('Output off'), findsOneWidget);
      // ONE caption on the card.
      expect(find.byType(StaleCaption), findsOneWidget);
      expect(find.text('last known · 15 s ago'), findsOneWidget);
      // The only "—" left is the 12 px RSSI chip (no live signal), never a
      // figure.
      expect(
          tester
              .widgetList<Text>(find.text('—'))
              .where((t) => t.style?.fontSize != 12)
              .length,
          0,
          reason: 'no dashes for known values');

      // Frames resume: everything back to live.
      clock = clock.add(const Duration(seconds: 1));
      c.parser.addBytes(bal);
      await pumpCard(tester, c, m);
      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(staleTexts(tester), isEmpty);
      expect(find.byType(StaleCaption), findsNothing);
      expect(find.text('Charging'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.dispose);
    });

    testWidgets('a never-seen placeholder: dashes, no caption, the offline '
        'status line', (tester) async {
      final m = manager();
      final c = BatteryConnection(profile: DeviceProfile.sphere);
      c.state.serial = 'JS-NEVER';
      c.isRemembered = true;
      await pumpCard(tester, c, m);
      expect(find.text('Offline · last seen unknown'), findsOneWidget);
      expect(find.text('—'), findsWidgets, reason: 'V and A never known');
      expect(find.text('—  ·  —'), findsOneWidget, reason: 'A · Ah');
      expect(find.byType(StaleCaption), findsOneWidget);
      expect(find.textContaining('last known'), findsNothing,
          reason: 'no stamp: the caption renders nothing');
      expect(find.text('Charge —'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a restored offline placeholder renders its snapshot stale '
        'with "Offline · last seen …" and the age', (tester) async {
      final m = manager();
      final c = BatteryConnection(profile: DeviceProfile.sphere);
      fill(c.state);
      c.state.serial = 'JS-OFF';
      c.isRemembered = true;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      c.lastSeenMs = nowMs - 5 * 60 * 1000;
      c.lastDataMs = nowMs - 3 * 24 * 3600 * 1000;
      await pumpCard(tester, c, m);
      expect(find.text('Offline · last seen 5 min ago'), findsOneWidget);
      expect(find.text('53.21 V'), findsOneWidget);
      expect(find.text('last known · 3 d ago'), findsOneWidget);
      expect(staleTexts(tester).map((t) => t.data), contains('53.21 V'));
      expect(find.text('—'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the catalogue sections: stale rows + one caption per card; '
        'never-known rows keep their plain "—"', (tester) async {
      final c = BatteryConnection(profile: DeviceProfile.sphere);
      fill(c.state);
      c.state.serial = 'JS-OFF';
      c.state.temp3 = null; // never known
      c.isRemembered = true;
      c.lastDataMs = DateTime.now().millisecondsSinceEpoch - 90000;
      final stale = stalenessOf(c);
      expect(stale, isNotNull);
      // Tall surface so every (lazy) section is built.
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(ListView(children: [
        PackSection(conn: c, stale: stale),
        CellsSection(conn: c, stale: stale),
        GatesStatusSection(conn: c, stale: stale),
      ])));
      expect(find.byType(StaleCaption), findsNWidgets(3),
          reason: 'one caption per card');
      expect(find.text('last known · 1 min ago'), findsNWidgets(3));
      final rows = tester.widgetList<KvRow>(find.byType(KvRow)).toList();
      expect(rows.every((r) => r.stale), isTrue);
      // Values in the stale style, never-known "—" plain.
      final v = tester.widget<Text>(find.text('53.21 V'));
      expect(v.style!.color, kStale);
      final fw = tester.widget<Text>(find.text('1.0.1'));
      expect(fw.style!.color, kStale);
      final cell = tester.widget<Text>(find.text('3.312 V'));
      expect(cell.style!.color, kStale);
      for (final d in tester.widgetList<Text>(find.text('—'))) {
        expect(d.style?.color, isNot(kStale), reason: 'never-known stays plain');
      }
      // Live: nothing stale.
      await tester.pumpWidget(app(ListView(children: [
        PackSection(conn: c),
        const SectionCard('X', [KvRow('k', 'v')]),
      ])));
      expect(find.byType(StaleCaption), findsNothing);
      expect(staleTexts(tester), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('fleet panel: Status / Switches from last-known when nothing is live',
      () {
    BatteryConnection member(String serial,
        {bool streaming = true,
        double current = 0,
        ChargeState cs = ChargeState.idle,
        int? dataAgeMs}) {
      final c = BatteryConnection(profile: DeviceProfile.sphere);
      c.state
        ..serial = serial
        ..fullAh = 100
        ..remainingAh = 50
        ..packVoltage = 52
        ..packCurrent = current
        ..power = current * 52
        ..chargeState = cs
        ..chargeMos = true
        ..dischargeMos = false;
      c.connState = ConnState.connected;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (streaming) c.lastTelemetryMs = now;
      c.lastDataMs = now - (dataAgeMs ?? 0);
      return c;
    }

    test('fleetLastKnownState nets every member; null when none ever known',
        () {
      final m = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      final a = member('JS-A',
          streaming: false, current: 20, cs: ChargeState.charging, dataAgeMs: 5000);
      final b = member('JS-B',
          streaming: false, current: 5, cs: ChargeState.discharging, dataAgeMs: 90000);
      m.batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      expect(m.fleetStreamingState, isNull);
      expect(m.fleetLastKnownState, ChargeState.charging);
      expect(m.fleetLastDataMs, a.lastDataMs, reason: 'the most recent');
      final never = BatteryConnection(profile: DeviceProfile.sphere);
      never.state.serial = 'JS-N';
      final m2 = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      m2.batteries.add(never);
      m2.setInFleet(never, true);
      expect(m2.fleetLastKnownState, isNull);
      expect(m2.fleetLastDataMs, isNull);
      m.disposeAll();
      m2.disposeAll();
    });

    testWidgets('Status and Switches read last-known in the stale style with '
        'one caption; live again -> normal; never-known -> "No data"',
        (tester) async {
      final m = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      final c = member('JS-SILENT',
          streaming: false, current: 20, cs: ChargeState.charging, dataAgeMs: 15000);
      m.batteries.add(c);
      m.setInFleet(c, true);
      Widget panel() => app(FleetTotal(manager: m));
      await tester.pumpWidget(panel());
      expect(find.text('No data'), findsNothing);
      expect(find.text('Charging'), findsOneWidget);
      final status = tester.widget<KvRow>(
          find.byWidgetPredicate((w) => w is KvRow && w.k == 'Status'));
      expect(status.stale, isTrue);
      final switches = tester.widget<KvRow>(
          find.byWidgetPredicate((w) => w is KvRow && w.k == 'Switches'));
      expect(switches.stale, isTrue);
      expect(switches.v, 'Charge 1/1 on  ·  Output 0/1 on');
      expect(tester.widget<Text>(find.text('Charging')).style!.color, kStale);
      expect(find.byType(StaleCaption), findsOneWidget);
      expect(find.text('last known · 15 s ago'), findsOneWidget);

      // The pack streams: normal colours, no caption.
      c.lastTelemetryMs = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(panel());
      expect(find.text('Charging'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Charging')).style!.color,
          isNot(kStale));
      expect(find.byType(StaleCaption), findsNothing);
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();

      // Only a never-seen placeholder: "No data", no caption.
      final m2 = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      final never = BatteryConnection(profile: DeviceProfile.sphere);
      never.state.serial = 'JS-N';
      never.isRemembered = true;
      m2.batteries.add(never);
      m2.setInFleet(never, true);
      await tester.pumpWidget(app(FleetTotal(manager: m2)));
      expect(find.text('No data'), findsOneWidget);
      expect(find.byType(StaleCaption), findsNothing);
      await tester.pumpWidget(const SizedBox());
      m2.disposeAll();
    });
  });
}
