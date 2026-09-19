import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/health_palette.dart';

import 'fakes.dart';

/// Fleet behaviour: MANUAL membership (issue #10) and the "every member must be
/// connected" gating for fleet-level controls (issue #11).
///
/// Batteries are built directly (no BLE, no timers, no DB) so the tests are
/// hermetic; each carries a serial, a connection state and totals, exactly like
/// a demo-fleet pack.
void main() {
  // Build a battery with a known serial / connection state / capacity.
  BatteryConnection make(
    String serial, {
    ConnState conn = ConnState.connected,
    double fullAh = 100,
    double remainingAh = 50,
  }) {
    final c = BatteryConnection(profile: DeviceProfile.sphere);
    c.state.serial = serial;
    c.state.fullAh = fullAh;
    c.state.remainingAh = remainingAh;
    c.connState = conn;
    return c;
  }

  late BatteryManager m;
  setUp(() => m = BatteryManager());

  group('manual membership (#10)', () {
    test('a discovered/added battery is NOT in the fleet by default', () {
      final a = make('JS-A');
      final b = make('JS-B');
      m.batteries.addAll([a, b]);
      expect(a.inFleet, isFalse);
      expect(b.inFleet, isFalse);
      expect(m.fleetMembers, isEmpty);
      expect(m.totalCapacityAh, 0);
    });

    test('setInFleet adds/removes and the total sums only members', () {
      final a = make('JS-A', remainingAh: 40);
      final b = make('JS-B', remainingAh: 60);
      final c = make('JS-C', remainingAh: 10);
      m.batteries.addAll([a, b, c]);

      m.setInFleet(a, true);
      m.setInFleet(b, true);
      expect(m.fleetMembers.map((x) => x.state.serial), ['JS-A', 'JS-B']);
      // Totals sum ONLY the two members (not c).
      expect(m.totalCapacityAh, 200);
      expect(m.totalRemainingAh, 100);
      expect(m.combinedSocPercent, 50);

      m.setInFleet(a, false);
      expect(m.fleetMembers.map((x) => x.state.serial), ['JS-B']);
      expect(m.totalRemainingAh, 60);
    });

    test('membership is tracked by serial and restored on a new connection', () {
      final a = make('JS-A');
      m.batteries.add(a);
      m.setInFleet(a, true);
      expect(m.fleetSerials.contains('JS-A'), isTrue);

      // Simulate a reconnect: a brand-new connection object, same serial.
      final a2 = make('JS-A');
      a2.inFleet = m.fleetSerials.contains(a2.state.serial);
      expect(a2.inFleet, isTrue);
    });
  });

  group('persistent fleet membership across restarts (#27)', () {
    test('setInFleet writes through to the store; loadFleetMembership restores',
        () async {
      final store = FakeFleetStore();
      final m1 = BatteryManager(fleetStore: store);
      final a = make('JS-A');
      final b = make('JS-B');
      m1.batteries.addAll([a, b]);
      m1.setInFleet(a, true);
      m1.setInFleet(b, true);
      m1.setInFleet(b, false); // remove one again
      await Future<void>.delayed(Duration.zero); // let fire-and-forget saves run
      expect(store.saved.keys.toSet(), {'JS-A'});

      // Simulate an app restart: a brand-new manager + store with the same
      // persisted records, and the battery rediscovered as a fresh connection.
      final m2 = BatteryManager(fleetStore: store);
      final a2 = make('JS-A');
      m2.batteries.add(a2);
      await m2.loadFleetMembership();
      expect(m2.fleetSerials, {'JS-A'});
      expect(a2.inFleet, isTrue, reason: 'rediscovered pack rejoins the fleet');
    });

    test('a pack discovered AFTER load still picks up persisted membership',
        () async {
      final store = FakeFleetStore()
        ..saved = {'JS-Z': const FleetRecord(serial: 'JS-Z')};
      final m2 = BatteryManager(fleetStore: store);
      await m2.loadFleetMembership();
      // The manager path sets inFleet from fleetSerials as packs appear.
      final z = make('JS-Z');
      z.inFleet = m2.fleetSerials.contains(z.state.serial);
      expect(z.inFleet, isTrue);
    });

    test('no store: membership is session-only (unchanged legacy behaviour)',
        () async {
      final m1 = BatteryManager(); // no fleetStore
      final a = make('JS-A');
      m1.batteries.add(a);
      m1.setInFleet(a, true);
      await m1.loadFleetMembership(); // no-op, must not throw
      expect(m1.fleetSerials, {'JS-A'});
    });
  });

  group('fleet all-connected gating (#11)', () {
    test('empty fleet: controls disabled with an explanatory reason', () {
      expect(m.fleetAllConnected, isFalse);
      expect(m.fleetControlsDisabledReason, isNotNull);
      expect(m.fleetControlsDisabledReason, contains('No batteries'));
    });

    test('all members connected: controls enabled, no reason', () {
      final a = make('JS-A');
      final b = make('JS-B');
      m.batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      expect(m.fleetConnectedCount, 2);
      expect(m.fleetAllConnected, isTrue);
      expect(m.fleetControlsDisabledReason, isNull);
    });

    test('one member disconnected: controls disabled, reason shows the count',
        () {
      final a = make('JS-A');
      final b = make('JS-B', conn: ConnState.disconnected);
      final c = make('JS-C');
      m.batteries.addAll([a, b, c]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      m.setInFleet(c, true);
      expect(m.fleetConnectedCount, 2);
      expect(m.fleetAllConnected, isFalse);
      final reason = m.fleetControlsDisabledReason!;
      expect(reason, contains('2/3 fleet batteries connected'));
    });

    test('a non-member being disconnected does NOT gate the fleet', () {
      final a = make('JS-A');
      final b = make('JS-B');
      final stray = make('JS-STRAY', conn: ConnState.disconnected);
      m.batteries.addAll([a, b, stray]); // stray is NOT added to the fleet
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      expect(m.fleetAllConnected, isTrue);
      expect(m.fleetControlsDisabledReason, isNull);
    });
  });

  group('fleet colour mirrors the batteries (#21)', () {
    // The fleet-total bar is coloured EXACTLY like a per-battery bar: the
    // combined fleet SOC fed through the SAME HealthPalette.socOrFault at the
    // SAME thresholds, with the identical fault-red override. This mirrors the
    // widget code (main.dart _FleetTotal) so there is no separate fleet palette.
    Color fleetColour(BatteryManager m) => HealthPalette.socOrFault(
        (m.combinedSocPercent ?? 0).toDouble(),
        fault: m.fleetAlarmActive);

    test('combined SOC uses the SAME graded palette as a per-battery bar', () {
      final a = make('JS-A', fullAh: 100, remainingAh: 40);
      final b = make('JS-B', fullAh: 100, remainingAh: 60);
      m.batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      expect(m.combinedSocPercent, 50);
      // Identical to grading a single 50 % battery — same function, same stops.
      expect(fleetColour(m), HealthPalette.colorForSoc(50));
    });

    test('grades high vs low fleets exactly like the SOC bar', () {
      final full = make('JS-FULL', fullAh: 100, remainingAh: 95);
      m.batteries.add(full);
      m.setInFleet(full, true);
      expect(fleetColour(m), HealthPalette.colorForSoc(95));

      m.setInFleet(full, false);
      final low = make('JS-LOW', fullAh: 100, remainingAh: 8);
      m.batteries.add(low);
      m.setInFleet(low, true);
      expect(fleetColour(m), HealthPalette.colorForSoc(8));
    });

    test('any member in alarm overrides the fleet colour to fault red', () {
      final a = make('JS-A', fullAh: 100, remainingAh: 90);
      final b = make('JS-B', fullAh: 100, remainingAh: 90);
      m.batteries.addAll([a, b]);
      m.setInFleet(a, true);
      m.setInFleet(b, true);
      expect(m.fleetAlarmActive, isFalse);
      expect(fleetColour(m), HealthPalette.colorForSoc(90));

      b.alarmActive = true; // one member trips
      expect(m.fleetAlarmActive, isTrue);
      expect(fleetColour(m), HealthPalette.faultRed);
    });

    test('a non-member in alarm does NOT trip the fleet colour', () {
      final a = make('JS-A', fullAh: 100, remainingAh: 70);
      final stray = make('JS-STRAY', fullAh: 100, remainingAh: 70);
      stray.alarmActive = true;
      m.batteries.addAll([a, stray]); // stray NOT in the fleet
      m.setInFleet(a, true);
      expect(m.fleetAlarmActive, isFalse);
      expect(fleetColour(m), HealthPalette.colorForSoc(70));
    });
  });

  group('demo fleet seeds start outside the fleet (#10)', () {
    test('startDemoFleet adds four packs, none auto-added to the fleet', () {
      m.startDemoFleet();
      expect(m.batteries.length, 4);
      expect(m.fleetMembers, isEmpty);
      expect(m.fleetControlsDisabledReason, contains('No batteries'));
      m.disposeAll(); // cancel the demo timers
    });
  });

  group('offline favourites + bind-on-discovery (#34)', () {
    test('FleetRecord round-trips through JSON', () {
      const r = FleetRecord(
        serial: 'JS-A',
        profile: 'JS',
        remoteId: 'dev-1',
        soc: 64,
        packVoltage: 13.2,
        remainingAh: 64,
        fullAh: 100,
        lastSeenMs: 1710000000000,
      );
      expect(FleetRecord.fromJson(r.toJson()), r);
    });

    test('materialiseRememberedFleet shows offline placeholders with last values',
        () async {
      final store = FakeFleetStore()
        ..saved = {
          'JS-OFF': const FleetRecord(
            serial: 'JS-OFF',
            profile: 'JS',
            remoteId: 'dev-off',
            soc: 80,
            packVoltage: 13.1,
            remainingAh: 80,
            fullAh: 100,
            lastSeenMs: 1710000000000,
          ),
        };
      final man = BatteryManager(fleetStore: store);
      await man.loadFleetMembership();
      man.materialiseRememberedFleet();

      expect(man.batteries.length, 1);
      final e = man.batteries.single;
      expect(e.isRemembered, isTrue);
      expect(e.isOffline, isTrue, reason: 'offline until discovered');
      expect(e.inFleet, isTrue);
      expect(e.state.serial, 'JS-OFF');
      expect(e.state.socPercent, 80);
      expect(e.state.fullAh, 100);
      expect(e.rememberedRemoteId, 'dev-off');
      expect(man.totalCapacityAh, 100, reason: 'offline fullAh counts (#36)');
      expect(man.offlineFleetMembers.length, 1);
      expect(man.connectedFleetMembers, isEmpty);
    });

    test('discovery BINDS to the remembered entry (no duplicate) and goes live',
        () async {
      final store = FakeFleetStore()
        ..saved = {
          'JS-OFF': const FleetRecord(
              serial: 'JS-OFF', fullAh: 100, remainingAh: 50, soc: 50),
        };
      final man = BatteryManager(fleetStore: store);
      await man.loadFleetMembership();
      man.materialiseRememberedFleet();
      final placeholder = man.batteries.single;
      expect(man.bindableBySerial('JS-OFF'), same(placeholder));

      // Simulate a scan discovering the pack with a real device id.
      final resolved = man.resolveDiscovered(
        serial: 'JS-OFF',
        deviceId: 'dev-42',
        profile: DeviceProfile.sphere,
        rssi: -55,
      );
      expect(resolved, same(placeholder), reason: 'bound to same entry');
      expect(man.batteries.length, 1, reason: 'no duplicate row');
      expect(resolved.rememberedRemoteId, 'dev-42');
      resolved.connState = ConnState.connected; // now live
      expect(resolved.isOffline, isFalse);
      // Already mapped: it can no longer be bound again.
      expect(man.bindableBySerial('JS-OFF'), isNull);
    });

    test('an unremembered discovery creates a fresh, non-fleet row', () async {
      final man = BatteryManager(fleetStore: FakeFleetStore());
      await man.loadFleetMembership();
      final c = man.resolveDiscovered(
        serial: 'JS-NEW',
        deviceId: 'dev-new',
        profile: DeviceProfile.sphere,
      );
      expect(man.batteries.single, same(c));
      expect(c.inFleet, isFalse);
      expect(c.isRemembered, isFalse);
    });

    test('offline members count toward capacity but not live net current',
        () async {
      final store = FakeFleetStore()
        ..saved = {
          'JS-OFF': const FleetRecord(
              serial: 'JS-OFF', fullAh: 100, remainingAh: 80, soc: 80),
        };
      final man = BatteryManager(fleetStore: store);
      await man.loadFleetMembership();
      man.materialiseRememberedFleet(); // JS-OFF offline placeholder

      final live = make('JS-LIVE', fullAh: 100, remainingAh: 50);
      live.state.chargeState = ChargeState.charging;
      live.state.packCurrent = 10;
      man.batteries.add(live);
      man.setInFleet(live, true);

      expect(man.fleetMembers.length, 2);
      expect(man.totalCapacityAh, 200, reason: 'offline fullAh included (#36)');
      expect(man.totalRemainingAh, 130);
      expect(man.netCurrentA, 10, reason: 'offline excluded from live current');
      expect(man.connectedFleetMembers.length, 1);
      expect(man.offlineFleetMembers.length, 1);
    });

    test('un-starring an offline placeholder drops its record and its row',
        () async {
      final store = FakeFleetStore()
        ..saved = {'JS-OFF': const FleetRecord(serial: 'JS-OFF', fullAh: 100)};
      final man = BatteryManager(fleetStore: store);
      await man.loadFleetMembership();
      man.materialiseRememberedFleet();
      final placeholder = man.batteries.single;

      man.setInFleet(placeholder, false);
      await Future<void>.delayed(Duration.zero);
      expect(man.batteries, isEmpty, reason: 'offline row removed on un-star');
      expect(man.fleetSerials, isEmpty);
      expect(store.saved, isEmpty);
    });

    test('persistFleetSnapshot writes live values back, throttled', () async {
      // #47: drive a controllable clock so the throttle/changed decision is
      // deterministic. With the real wall clock, setInFleet's initial save and
      // the first snapshot could land in the SAME millisecond, making the
      // snapshot see no change and never arm the throttle — a spurious failure.
      final store = FakeFleetStore();
      var clock = DateTime.utc(2024, 1, 1, 12, 0, 0);
      final man = BatteryManager(
        fleetStore: store,
        recordSaveInterval: const Duration(hours: 1),
        now: () => clock,
      );
      final live = make('JS-A', fullAh: 100, remainingAh: 60);
      live.state.socPercent = 60;
      man.batteries.add(live);
      man.setInFleet(live, true); // persists the initial record (t0)

      // Advance past t0 so the first snapshot is a distinct instant: its fresh
      // lastSeenMs is a real change, so it writes through and arms the throttle.
      clock = clock.add(const Duration(seconds: 1));
      man.persistFleetSnapshot();
      final afterFirst = store.saveCount;

      // A later update refreshes the in-memory record but the 1 h throttle
      // suppresses another disk write.
      clock = clock.add(const Duration(seconds: 1));
      live.state.socPercent = 61;
      man.persistFleetSnapshot();
      expect(store.saveCount, afterFirst, reason: 'throttled — no extra write');
      expect(man.fleetRecords['JS-A']!.soc, 61, reason: 'in-memory updated');

      // Forcing bypasses the throttle. Advance the clock so this snapshot is a
      // fresh instant (a real change over the throttled call's record), then
      // force writes it through despite the 1 h window not having elapsed.
      clock = clock.add(const Duration(seconds: 1));
      man.persistFleetSnapshot(force: true);
      expect(store.saveCount, afterFirst + 1);
      expect(store.saved['JS-A']!.soc, 61);
    });
  });
}
