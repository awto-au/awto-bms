/// #110: the list shows every battery ever found. The star is only the fleet
/// flag (un-starring keeps the row, its last-known values and its history);
/// the list is grouped fleet → other known → new; the known list is seeded
/// once from history without demo serials; "Forget battery" hides a row
/// behind a confirmation and never deletes a reading; the list persists
/// across a restart and travels in the data export (#104).
library;

import 'dart:io';

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/app_session.dart';
import 'package:battery_reader/app_theme.dart' show kStale;
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_list_page.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart' show DeviceProfile;
import 'package:battery_reader/data_export.dart';
import 'package:battery_reader/desktop_shell.dart';
import 'package:battery_reader/known_store.dart';
import 'package:battery_reader/last_known.dart';
import 'package:battery_reader/sections/known_row.dart';
import 'package:battery_reader/sections/summary_card.dart';
import 'package:battery_reader/nav.dart' show gNavKey;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'fakes.dart';

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('known110_');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  var n = 0;
  Future<Database> ffiOpen(String path, OpenDatabaseOptions o) =>
      databaseFactoryFfi.openDatabase(path, options: o);

  /// A real history store with [rows] (serial, metric, value, endMs) and
  /// lifetime totals for [lifetime].
  Future<BatteryLogger> history(List<(String, String, double, int)> rows,
      {List<String> lifetime = const []}) async {
    final log = BatteryLogger.custom(
        path: p.join(tmp.path, 'h${n++}.db'), opener: ffiOpen);
    await log.init();
    final db = log.debugDb!;
    var id = 1000;
    for (final (serial, metric, v, endMs) in rows) {
      await db.insert('readings', {
        'id': id++,
        'serial': serial,
        'metric': metric,
        'value_num': v,
        'start_time': BatteryLogger.fmtTime(endMs - 60000),
        'end_time': BatteryLogger.fmtTime(endMs),
        'start_ms': endMs - 60000,
        'end_ms': endMs,
      });
    }
    for (final s in lifetime) {
      await db.insert('lifetime_totals', {
        'serial': s,
        'total_charge_ah': 1.0,
        'total_discharge_ah': 2.0,
        'total_efc': 0.1,
        'aggregated_up_to': '2026-09-01 00:00:00.000',
        'aggregated_up_to_ms': 1788220800000,
      });
    }
    return log;
  }

  final t0 = DateTime(2026, 9, 20, 12).millisecondsSinceEpoch;
  const day = 24 * 3600 * 1000;

  /// A favourite record with a full last-known snapshot.
  FleetRecord favourite(String serial, {int soc = 64, int? lastMs}) {
    final c = BatteryConnection(profile: DeviceProfile.sphere);
    c.state
      ..serial = serial
      ..socPercent = soc
      ..packVoltage = 52.4
      ..remainingAh = 32
      ..fullAh = 50;
    return FleetRecord(
      serial: serial,
      soc: soc,
      packVoltage: 52.4,
      remainingAh: 32,
      fullAh: 50,
      lastSeenMs: lastMs ?? t0,
      last: LastKnownState.capture(c.state, signedCurrent: 0),
      lastDataMs: lastMs ?? t0,
    );
  }

  BatteryManager manager(FakeFleetStore fleet, FakeKnownStore known) =>
      BatteryManager(
          transport: NoopTransport(), fleetStore: fleet, knownStore: known);

  /// Load + materialise, as startLive does before its first scan.
  Future<BatteryManager> launch(
      FakeFleetStore fleet, FakeKnownStore known) async {
    final m = manager(fleet, known);
    await m.loadFleetMembership();
    m.materialiseRememberedFleet();
    return m;
  }

  group('the star is only the fleet flag', () {
    test('un-starring keeps the row, its last-known values and its history',
        () async {
      final log = await history([
        ('JS-A', 'soc', 64, t0),
        ('JS-A', 'packV', 52.4, t0),
      ]);
      final before = await log.readingCount('JS-A');
      final fleet = FakeFleetStore()..saved = {'JS-A': favourite('JS-A')};
      final known = FakeKnownStore();
      final m = await launch(fleet, known);
      final row = m.batteries.single;
      expect(row.inFleet, isTrue);

      m.setInFleet(row, false);
      await Future<void>.delayed(Duration.zero);

      expect(m.batteries, [row], reason: 'the row stays');
      expect(row.inFleet, isFalse);
      expect(row.isOffline, isTrue);
      expect(row.state.socPercent, 64, reason: 'last-known kept');
      expect(row.state.packVoltage, 52.4);
      expect(m.fleetMembers, isEmpty, reason: 'out of the fleet totals');
      expect(fleet.saved, isEmpty);
      expect(known.saved.batteries['JS-A']?.record.soc, 64);
      expect(known.saved.batteries['JS-A']?.forgotten, isFalse);
      expect(await log.readingCount('JS-A'), before, reason: 'history kept');
      await log.dispose();
    });

    test(
        'an un-starred battery is back after a restart, offline, with its '
        'last-known values', () async {
      final fleet = FakeFleetStore()..saved = {'JS-A': favourite('JS-A')};
      final known = FakeKnownStore();
      final m1 = await launch(fleet, known);
      m1.setInFleet(m1.batteries.single, false);
      await Future<void>.delayed(Duration.zero);

      final m2 = await launch(fleet, known); // "restart"
      final row = m2.batteries.single;
      expect(row.state.serial, 'JS-A');
      expect(row.inFleet, isFalse);
      expect(row.isOffline, isTrue);
      expect(row.state.socPercent, 64);
      expect(row.state.remainingAh, 32);
      expect(row.lastDataMs, t0);
      expect(m2.listGroups.known, [row]);
    });

    test('starring a known battery again puts it back in the fleet', () async {
      final known = FakeKnownStore()
        ..saved = KnownBatteries(
            seeded: true, batteries: {'JS-K': KnownBattery(favourite('JS-K'))});
      final fleet = FakeFleetStore();
      final m = await launch(fleet, known);
      final row = m.batteries.single;
      expect(row.inFleet, isFalse);
      m.setInFleet(row, true);
      expect(m.fleetMembers, [row]);
      expect(fleet.saved.keys, ['JS-K']);
      expect(m.totalCapacityAh, 50, reason: 'offline member counts (#36)');
    });

    test('a live battery that drops stays listed as offline (known)', () {
      final m = manager(FakeFleetStore(), FakeKnownStore());
      final c = m.resolveDiscovered(
          serial: 'JS-NEW', deviceId: 'AA:01', profile: DeviceProfile.sphere);
      expect(m.knownBatteries.containsKey('JS-NEW'), isTrue);
      expect(m.isNewThisSession('JS-NEW'), isTrue);
      c.connState = ConnState.disconnected;
      expect(c.isOffline, isTrue);
    });
  });

  group('list order', () {
    test('fleet, then other known (live, then offline newest first), then new',
        () async {
      final fleet = FakeFleetStore()..saved = {'JS-FAV': favourite('JS-FAV')};
      final known = FakeKnownStore()
        ..saved = KnownBatteries(seeded: true, batteries: {
          'JS-OLD': KnownBattery(favourite('JS-OLD', lastMs: t0 - 5 * day)),
          'JS-MID': KnownBattery(favourite('JS-MID', lastMs: t0 - day)),
          'JS-LIVE': KnownBattery(favourite('JS-LIVE', lastMs: t0 - 9 * day)),
        });
      final m = await launch(fleet, known);
      // JS-LIVE comes into range (binds to its row); JS-NEW is first found.
      final live = m.resolveDiscovered(
          serial: 'JS-LIVE', deviceId: 'AA:02', profile: DeviceProfile.sphere);
      live.connState = ConnState.connected;
      final fresh = m.resolveDiscovered(
          serial: 'JS-NEW', deviceId: 'AA:03', profile: DeviceProfile.sphere);

      final g = m.listGroups;
      String s(BatteryConnection b) => b.state.serial!;
      expect(g.fleet.map(s), ['JS-FAV']);
      expect(g.known.map(s), ['JS-LIVE', 'JS-MID', 'JS-OLD']);
      expect(g.fresh, [fresh]);
      expect(g.all.map(s), ['JS-FAV', 'JS-LIVE', 'JS-MID', 'JS-OLD', 'JS-NEW']);
      expect(g.nonEmptyCount, 3);
    });

    test('demo packs are never known batteries', () {
      final known = FakeKnownStore();
      final m = manager(FakeFleetStore(), known)..startDemoFleet();
      addTearDown(m.disposeAll);
      m.setInFleet(m.batteries.first, true);
      m.setInFleet(m.batteries.first, false);
      expect(m.knownBatteries, isEmpty);
      expect(known.saved.batteries, isEmpty);
    });
  });

  group('seeding from history', () {
    test(
        'every real serial in the store (readings or lifetime totals), '
        'with its latest values; demo serials excluded', () async {
      final log = await history([
        ('JS-REAL', 'soc', 40, t0 - day),
        ('JS-REAL', 'soc', 71, t0), // the latest wins
        ('JS-REAL', 'packV', 53.1, t0),
        ('JS-REAL', 'remAh', 35.5, t0),
        ('DEMO-1', 'soc', 64, t0),
        ('JS-9F031B', 'soc', 9, t0),
        ('JS-5A77C0', 'soc', 50, t0),
        ('RV-1180E2', 'soc', 47, t0),
      ], lifetime: [
        'RV-ONLYTOTALS',
        'JS-9F031B',
      ]);
      final fleet = FakeFleetStore()
        ..saved = {
          'JS-FAV': favourite('JS-FAV'),
          'DEMO-2': const FleetRecord(serial: 'DEMO-2'),
        };
      final known = FakeKnownStore();
      final m = manager(fleet, known);
      await m.loadFleetMembership();
      await m.seedKnownFromHistory(from: log);

      expect(m.knownSeeded, isTrue);
      expect(m.knownBatteries.keys.toSet(),
          {'JS-REAL', 'RV-ONLYTOTALS', 'JS-FAV'});
      final real = m.knownBatteries['JS-REAL']!.record;
      expect(real.soc, 71);
      expect(real.packVoltage, 53.1);
      expect(real.remainingAh, 35.5);
      expect(real.lastSeenMs, t0);
      expect(m.knownBatteries['RV-ONLYTOTALS']!.record.profile, 'RV');
      expect(known.saved.seeded, isTrue);
      expect(known.saved.batteries.keys.toSet(),
          {'JS-REAL', 'RV-ONLYTOTALS', 'JS-FAV'});

      // The seeded rows show as offline known batteries, in stale values.
      m.materialiseRememberedFleet();
      final row = m.batteries.firstWhere((b) => b.state.serial == 'JS-REAL');
      expect(row.isOffline, isTrue);
      expect(row.state.socPercent, 71);
      expect(row.lastDataMs, t0);

      // Seeding runs once: a later pass never re-adds a forgotten battery.
      m.forgetBattery(row);
      await m.seedKnownFromHistory(from: log);
      expect(m.knownBatteries['JS-REAL']!.forgotten, isTrue);
      await log.dispose();
    });

    test('a closed history store seeds nothing and leaves it for later',
        () async {
      final log = BatteryLogger.custom(
          path: p.join(tmp.path, 'closed.db'), opener: ffiOpen);
      final m = manager(FakeFleetStore(), FakeKnownStore());
      await m.seedKnownFromHistory(from: log); // never init()ed
      expect(m.knownSeeded, isFalse);
    });
  });

  group('forget battery', () {
    test('hides the row and keeps every reading; it returns if found again',
        () async {
      final log = await history([
        ('JS-F', 'soc', 55, t0),
        ('JS-F', 'packV', 52.0, t0),
      ], lifetime: [
        'JS-F'
      ]);
      final readings = await log.readingCount('JS-F');
      final totals = await log.lifetimeTotals('JS-F');
      final fleet = FakeFleetStore()..saved = {'JS-F': favourite('JS-F')};
      final known = FakeKnownStore();
      final m = await launch(fleet, known);
      final row = m.batteries.single;

      m.forgetBattery(row);
      await Future<void>.delayed(Duration.zero);

      expect(m.batteries, isEmpty, reason: 'row hidden');
      expect(fleet.saved, isEmpty, reason: 'left the fleet');
      final k = known.saved.batteries['JS-F']!;
      expect(k.forgotten, isTrue);
      expect(k.record.soc, 64, reason: 'last-known kept with the record');
      expect(await log.readingCount('JS-F'), readings, reason: 'no deletion');
      expect((await log.lifetimeTotals('JS-F')).chargeAh, totals.chargeAh);

      // Restart: still hidden.
      final m2 = await launch(fleet, known);
      expect(m2.batteries, isEmpty);

      // Found again: back, as a new battery this session.
      final again = m2.resolveDiscovered(
          serial: 'JS-F', deviceId: 'AA:09', profile: DeviceProfile.sphere);
      expect(m2.batteries, [again]);
      expect(m2.knownBatteries['JS-F']!.forgotten, isFalse);
      expect(m2.listGroups.fresh, [again]);
      await log.dispose();
    });

    test('a connected battery cannot be forgotten', () {
      final m = manager(FakeFleetStore(), FakeKnownStore());
      final c = m.resolveDiscovered(
          serial: 'JS-C', deviceId: 'AA:04', profile: DeviceProfile.sphere);
      c.connState = ConnState.connected;
      expect(m.forgetDisabledReason(c), isNotNull);
      expect(() => m.forgetBattery(c), throwsStateError);
      expect(m.batteries, [c]);
    });
  });

  group('persistence and export', () {
    test('the prefs store round-trips and the export / import carries it',
        () async {
      final store = SharedPrefsKnownStore();
      await store.save(KnownBatteries(seeded: true, batteries: {
        'JS-A': KnownBattery(favourite('JS-A'), firstSeenMs: t0),
        'JS-B': KnownBattery(favourite('JS-B'), forgotten: true),
      }));
      final loaded = await store.load();
      expect(loaded.seeded, isTrue);
      expect(loaded.batteries['JS-A'],
          KnownBattery(favourite('JS-A'), firstSeenMs: t0));
      expect(loaded.batteries['JS-B']!.forgotten, isTrue);

      // #104: every preference is exported, so the list travels with it.
      final encoded = encodePrefs(await SharedPreferences.getInstance());
      expect(encoded.containsKey(SharedPrefsKnownStore.key), isTrue);
      SharedPreferences.setMockInitialValues({});
      final written =
          await applyPrefs(await SharedPreferences.getInstance(), encoded);
      expect(written, contains(SharedPrefsKnownStore.key));
      final imported = await SharedPrefsKnownStore().load();
      expect(imported.batteries, loaded.batteries);
      expect(imported.seeded, isTrue);
    });

    test('a corrupt entry is skipped, not the whole list', () async {
      SharedPreferences.setMockInitialValues({
        SharedPrefsKnownStore.key:
            '{"seeded":true,"batteries":[{"serial":"JS-OK"},{"serial":7}]}',
      });
      final loaded = await SharedPrefsKnownStore().load();
      expect(loaded.batteries.keys, ['JS-OK']);
    });

    test('live values of a known (un-starred) battery are persisted', () {
      final known = FakeKnownStore();
      var clock = DateTime(2026, 9, 24, 12);
      final m = BatteryManager(
          transport: NoopTransport(),
          fleetStore: FakeFleetStore(),
          knownStore: known,
          now: () => clock);
      final c = m.resolveDiscovered(
          serial: 'JS-L', deviceId: 'AA:05', profile: DeviceProfile.sphere);
      c.connState = ConnState.connected;
      c.state
        ..socPercent = 88
        ..remainingAh = 44;
      c.lastDataMs = clock.millisecondsSinceEpoch;
      clock = clock.add(const Duration(minutes: 2));
      m.persistFleetSnapshot();
      expect(known.saved.batteries['JS-L']!.record.soc, 88);
      expect(known.saved.batteries['JS-L']!.record.remainingAh, 44);
    });
  });

  group('the list UI (phone and desktop share it)', () {
    /// A session whose list has all three groups.
    Future<AppSession> session() async {
      final fleet = FakeFleetStore()..saved = {'JS-FAV': favourite('JS-FAV')};
      final known = FakeKnownStore()
        ..saved = KnownBatteries(seeded: true, batteries: {
          'JS-OLD': KnownBattery(favourite('JS-OLD', soc: 12, lastMs: t0)),
        });
      final m = await launch(fleet, known);
      // First found this session, connecting.
      m
          .resolveDiscovered(
              serial: 'JS-NEW',
              deviceId: 'AA:07',
              profile: DeviceProfile.sphere)
          .connState = ConnState.connecting;
      return AppSession(
          manager: m,
          aliases: AliasStore(prefs: SharedPreferences.getInstance));
    }

    Widget scaled(BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        );

    Future<void> size(WidgetTester tester, double w, double h) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('phone: grouped, the offline known row is compact and stale',
        (tester) async {
      await size(tester, 360, 800);
      final s = await tester.runAsync(session);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: gNavKey,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        builder: scaled,
        home: BatteryListPage(session: s),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(find.text('FLEET · 1'), findsOneWidget);
      expect(find.text('OTHER BATTERIES · 1'), findsOneWidget);
      expect(find.text('NEW · 1'), findsOneWidget);
      // Fleet + new are full cards; the offline known battery is one line.
      expect(find.byType(SummaryCard), findsNWidgets(2));
      final row = find.byType(KnownBatteryRow);
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, lessThanOrEqualTo(40));
      expect(tester.getSize(row).height,
          lessThan(tester.getSize(find.byType(SummaryCard).first).height / 2));
      // Groups in order, top to bottom.
      double y(Finder f) => tester.getTopLeft(f).dy;
      expect(y(find.text('FLEET · 1')), lessThan(y(row)));
      expect(y(row), lessThan(y(find.text('NEW · 1'))));
      // Last-known figures in the stale style (red), never dashes.
      final figures = tester.widget<Text>(
          find.descendant(of: row, matching: find.textContaining('12%')));
      expect(figures.style?.color, kStale);
    });

    testWidgets('forget asks first; Cancel keeps the row, Forget hides it',
        (tester) async {
      await size(tester, 360, 800);
      final s = await tester.runAsync(session);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: gNavKey,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        builder: scaled,
        home: BatteryListPage(session: s),
      ));
      await tester.pump();

      Future<void> openForget() async {
        await tester.tap(find.descendant(
            of: find.byType(KnownBatteryRow),
            matching: find.byIcon(Icons.more_vert)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Forget battery…'));
        await tester.pumpAndSettle();
        expect(find.text('Forget JS-OLD?'), findsOneWidget);
        expect(find.textContaining('Its history is kept'), findsOneWidget);
      }

      await openForget();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(KnownBatteryRow), findsOneWidget);

      await openForget();
      await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
      await tester.pumpAndSettle();
      expect(find.byType(KnownBatteryRow), findsNothing);
      expect(s!.manager.knownBatteries['JS-OLD']!.forgotten, isTrue);
      expect(find.text('OTHER BATTERIES · 1'), findsNothing);
    });

    testWidgets('desktop: the same groups and compact row, dense',
        (tester) async {
      await size(tester, 1280, 800);
      final s = await tester.runAsync(session);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: gNavKey,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        builder: scaled,
        home: DesktopShell(
          session: s!,
          selected: null,
          onSelect: (_) {},
          tab: DesktopTab.detail,
          onTab: (_) {},
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('FLEET · 1'), findsOneWidget);
      expect(find.text('OTHER BATTERIES · 1'), findsOneWidget);
      expect(find.text('NEW · 1'), findsOneWidget);
      final row = find.byType(KnownBatteryRow);
      expect(row, findsOneWidget);
      expect(tester.widget<KnownBatteryRow>(row).dense, isTrue);
      expect(tester.getSize(row).height, lessThanOrEqualTo(34));
    });
  });
}
