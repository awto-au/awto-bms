import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/demo_source.dart';
import 'package:battery_reader/main.dart'
    show pluralBatteries, writeFailureReason;

import 'fakes.dart';

/// Review-fix Pass B (GitHub #51): the MEDIUM quick wins + LOW cleanups that
/// are unit-testable without a widget tree or a database.
///
///  * M2 — a write with no link THROWS (never a silent no-op); in demo mode
///    the virtual battery acks every write so read-backs complete.
///  * M3 — fleetSetOutput continues past a failing member and reports
///    per-member results; runWrite's reason text.
///  * M5 — the lifetime refresh never throws with the logger disabled.
///  * M8 — the packed `flags` row is gated on the SAME key set as Python.
///  * L1/L2/L4 — codec: SOC clamp, setting acks for every type, the
///    table-driven dispatch covering every begin sentinel.
///  * L9 — pluralisation.  L11 — no throw after dispose.  L15 — connect timeout.
void main() {
  List<int> bal({int chgMos = 1, int disMos = 1}) =>
      [0xA8, 0xAC, 0x01, chgMos, disMos, 0, 1, 0, 0, 0xB9, 0x21];
  List<int> payload(List<int> frame) => frame.sublist(2, frame.length - 2);

  group('M2: no link -> the write throws instead of silently no-op-ing', () {
    test('sleep / capacity / gate writes all throw StateError, nothing sent',
        () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      expect(c.writesDisabledReason, 'Not connected');
      await expectLater(c.setSleepMode(true), throwsA(isA<StateError>()));
      await expectLater(c.writeCapacity(100), throwsA(isA<StateError>()));
      await expectLater(c.sendGateControl(GateAction.bothMos, on: false),
          throwsA(isA<StateError>()));
      expect(t.writes, isEmpty);
    });

    test('after a drop the non-gate writes are refused too', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      expect(c.writesDisabledReason, isNull);
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.writesDisabledReason, 'Not connected');
      final before = t.writes.length;
      await expectLater(c.setSleepMode(false), throwsA(isA<StateError>()));
      expect(t.writes.length, before);
    });

    test('a connected link accepts the sleep and capacity frames', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      final before = t.writes.length;
      await c.setSleepMode(true);
      await c.writeCapacity(100);
      expect(t.writes.length, before + 2);
      expect(t.writes[before], BatteryCommands.openSleep);
      expect(t.writes[before + 1], buildCapacityWriteFrame(100));
    });
  });

  group('M2: demo mode simulates the BMS acks', () {
    test('output OFF is acked: read-back completes true, gates reflect it',
        () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.startDemo(startSoc: 50, mode: DemoMode.idle, serial: 'JS-DEMO');
      expect(c.hasFreshGateState, isTrue, reason: 'demo streams BAL_STATUS');
      expect(c.isOutputOn, isTrue);
      await c.sendGateControl(GateAction.bothMos, on: false);
      final ok = await c.confirmMosState(GateAction.bothMos, false,
          timeout: const Duration(seconds: 2));
      expect(ok, isTrue);
      expect(c.isOutputOn, isFalse);
      expect(c.state.gateAck.take(2), [false, false], reason: 'GATE_SET echo');
      await c.dispose();
    });

    test('capacity write is acked with SETTING_RESPOND type 4 + new fullAh',
        () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.startDemo(startSoc: 50, mode: DemoMode.idle, serial: 'JS-DEMO');
      await c.writeCapacity(120);
      final ok = await c.confirmCapacityWrite(120,
          timeout: const Duration(seconds: 2));
      expect(ok, isTrue);
      expect(c.state.capacityWriteAck, isTrue);
      expect(c.state.fullAh, closeTo(120, 0.01));
      await c.dispose();
    });

    test('sleep on / off is acked via SLEEP_SET_SUCCESS', () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.startDemo(startSoc: 50, mode: DemoMode.idle, serial: 'JS-DEMO');
      await c.setSleepMode(true);
      expect(
          await c.confirmSleepState(true, timeout: const Duration(seconds: 2)),
          isTrue);
      await c.setSleepMode(false);
      expect(
          await c.confirmSleepState(false,
              timeout: const Duration(seconds: 2)),
          isTrue);
      await c.dispose();
    });

    test('DemoBattery.handleWrite ignores frames it does not model', () {
      final frames = <List<int>>[];
      final d = DemoBattery(frames.add, ackLatency: Duration.zero);
      d.handleWrite(BatteryCommands.begin);
      d.handleWrite(BatteryCommands.getVersion);
      d.handleWrite(const [0xC3]);
      expect(frames, isEmpty);
    });
  });

  group('M3: fleetSetOutput reports per-member results', () {
    test('a member whose write throws does not stop the others', () async {
      final tA = FakeTransport();
      final tB = FakeTransport()..failWrite = true;
      final tC = FakeTransport();
      final a = BatteryConnection(transport: tA);
      final b = BatteryConnection(transport: tB);
      final c = BatteryConnection(transport: tC);
      // B's handshake writes fail too — that is a normal failed connect, so
      // let it connect first and only then start failing writes.
      tB.failWrite = false;
      await a.connectTo('dev-a', name: 'JS-A');
      await b.connectTo('dev-b', name: 'JS-B');
      await c.connectTo('dev-c', name: 'JS-C');
      tB.failWrite = true;
      for (final x in [a, b, c]) {
        x.parser.addBytes(bal());
      }
      final m = BatteryManager();
      m.batteries.addAll([a, b, c]);
      for (final x in [a, b, c]) {
        m.setInFleet(x, true);
      }
      expect(m.fleetGateWriteDisabledReason, isNull);

      final r = await m.fleetSetMos(GateAction.bothMos, on: false);
      expect(r.allOk, isFalse);
      expect(r.succeeded, ['JS-A', 'JS-C']);
      expect(r.failed.keys, ['JS-B']);
      expect(r.failed['JS-B'], isA<StateError>());
      expect(r.failureSummary, contains('JS-B'));
      expect(payload(tA.gateWrites.single).sublist(0, 2), [0, 0]);
      expect(payload(tC.gateWrites.single).sublist(0, 2), [0, 0]);
      expect(tB.gateWrites, isEmpty);
    });

    test('all members ok -> allOk with every serial listed', () async {
      final tA = FakeTransport();
      final a = BatteryConnection(transport: tA);
      await a.connectTo('dev-a', name: 'JS-A');
      a.parser.addBytes(bal());
      final m = BatteryManager();
      m.batteries.add(a);
      m.setInFleet(a, true);
      final r = await m.fleetSetMos(GateAction.bothMos, on: true);
      expect(r.allOk, isTrue);
      expect(r.succeeded, ['JS-A']);
      expect(r.failed, isEmpty);
    });

    test('the C1 pre-check still refuses before ANY member is written',
        () async {
      final tA = FakeTransport();
      final a = BatteryConnection(transport: tA);
      await a.connectTo('dev-a', name: 'JS-A'); // no BAL_STATUS yet
      final m = BatteryManager();
      m.batteries.add(a);
      m.setInFleet(a, true);
      // Output OFF can cut something: refused without a fresh base.
      await expectLater(m.fleetSetMos(GateAction.bothMos, on: false), throwsA(isA<StateError>()));
      expect(tA.gateWrites, isEmpty);
      // #59: output ON cannot — it goes out on the safe base (both MOS = 1).
      final r = await m.fleetSetMos(GateAction.bothMos, on: true);
      expect(r.allOk, isTrue);
      expect(tA.gateWrites.single.sublist(2, 4), [1, 1]);
    });
  });

  group('M3: writeFailureReason', () {
    test('uses the message of StateError / ArgumentError / TimeoutException',
        () {
      expect(writeFailureReason(StateError('Not connected — x')),
          'Not connected — x');
      expect(writeFailureReason(ArgumentError('bad')), 'bad');
      expect(writeFailureReason(TimeoutException('slow')), 'slow');
    });

    test('falls back to the error text for anything else', () {
      expect(writeFailureReason(Exception('gatt')), contains('gatt'));
      expect(writeFailureReason('plain'), 'plain');
    });
  });

  group('M5: lifetime refresh is safe with the logger disabled', () {
    test('refreshLifetimeTotals completes and caches nothing', () async {
      expect(BatteryLogger.instance.enabled, isFalse,
          reason: 'no SQLite under flutter test');
      final m = BatteryManager();
      final c = BatteryConnection(transport: FakeTransport())
        ..state.serial = 'JS-A';
      m.batteries.add(c);
      await m.refreshLifetimeTotals();
      expect(m.aggregateFor('JS-A'), isNull);
      // Overlapping calls are harmless.
      await Future.wait([m.refreshLifetimeTotals(), m.refreshLifetimeTotals()]);
    });

    test('BatteryLogger.dispose is idempotent and leaves the store disabled',
        () async {
      await BatteryLogger.instance.dispose();
      await BatteryLogger.instance.dispose();
      expect(BatteryLogger.instance.enabled, isFalse);
      expect(await BatteryLogger.instance.updateLifetimeTotals('JS-A'),
          isA<LifetimeTotals>());
    });
  });

  group('M8: flags row gated on the Python REQUIRED_FLAG_KEYS set', () {
    BatteryState full() => BatteryState()
      ..mosOn = true
      ..loadConnected = false
      ..chargerConnected = true
      ..chargeMos = true
      ..dischargeMos = false
      ..passiveBalancing = false
      ..chargeState = ChargeState.charging
      ..currentAlarmSeen = true
      ..voltageAlarmSeen = true
      ..temperatureAlarmSeen = true;

    test('every required key present -> packed', () {
      final f = packFlags(full());
      expect(f, isNotNull);
      expect(f! & Flags.mos, isNonZero);
      expect(f & Flags.load, 0);
      expect(f & Flags.charger, isNonZero);
      expect(f & Flags.chgMos, isNonZero);
      expect(f & Flags.disMos, 0);
      expect(f & Flags.sleep, 0, reason: 'sleep defaults to awake');
      expect(Flags.chargeState(f), 1);
      expect(Flags.faultActive(f), isFalse);
    });

    test('any missing key -> null (a 0 bit never means "unknown")', () {
      expect(packFlags(full()..mosOn = null), isNull);
      expect(packFlags(full()..loadConnected = null), isNull);
      expect(packFlags(full()..chargerConnected = null), isNull);
      expect(packFlags(full()..chargeMos = null), isNull);
      expect(packFlags(full()..dischargeMos = null), isNull);
      expect(packFlags(full()..passiveBalancing = null), isNull);
      expect(packFlags(full()..chargeState = ChargeState.unknown), isNull);
      expect(packFlags(full()..currentAlarmSeen = false), isNull);
      expect(packFlags(full()..voltageAlarmSeen = false), isNull);
      expect(packFlags(full()..temperatureAlarmSeen = false), isNull);
    });

    test('sleep is NOT required, and an explicit sleep ack sets the bit', () {
      expect(packFlags(full()..sleepModeOn = null), isNotNull);
      expect(packFlags(full()..sleepModeOn = true)! & Flags.sleep, isNonZero);
    });

    test('fault bits reflect live faults once all categories were seen', () {
      final f = packFlags(full()..faultVoltage = true)!;
      expect(Flags.faultCategories(f), ['Voltage']);
    });

    test('the parser marks each alarm category as seen', () {
      final s = BatteryState();
      final p = BatteryParser(state: s);
      p.addBytes([0xA4, 0x8B, 0, 0, 0, 0, 0, 0xB5, 0xDD]);
      expect(s.currentAlarmSeen, isTrue);
      expect(s.voltageAlarmSeen, isFalse);
      p.addBytes([0xA5, 0x99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xB6, 0x17]);
      expect(s.voltageAlarmSeen, isTrue);
      p.addBytes([0xA6, 0xC0, 0, 0, 0, 0, 0, 0, 0, 0xB7, 0x72]);
      expect(s.temperatureAlarmSeen, isTrue);
    });

    test('the demo battery streams all three alarm frames so flags complete',
        () async {
      final c = BatteryConnection(transport: FakeTransport());
      await c.startDemo(startSoc: 50, mode: DemoMode.idle, serial: 'JS-DEMO');
      expect(flagsComplete(c.state), isTrue);
      expect(packFlags(c.state), isNotNull);
      await c.dispose();
    });
  });

  group('L1 / L2: codec', () {
    test('SOC byte > 100 clamps to 100 (unsigned: no lower clamp needed)', () {
      final s = BatteryState();
      BatteryParser(state: s)
          .addBytes([0xA9, 0x64, 0xFF, 0, 0, 0, 0, 0, 0, 0xBA, 0x5E]);
      expect(s.socPercent, 100);
    });

    test('every SETTING_RESPOND type emits a SettingRespondEvent with its byte',
        () {
      final s = BatteryState();
      final events = <BatteryEvent>[];
      final p = BatteryParser(state: s, onEvent: events.add);
      for (final type in [1, 2, 3, 4, 9]) {
        p.addBytes([0xAB, 0xBA, type, 0xCD, 0xDC]);
      }
      final acks = events.whereType<SettingRespondEvent>().toList();
      expect(acks.map((e) => e.type), [1, 2, 3, 4, 9]);
      expect(acks.map((e) => e.typeName),
          ['voltage', 'current', 'temperature', 'capacity', 'unknown']);
      expect(acks.first.label, 'Setting ack');
    });

    test('only type 4 sets capacityWriteAck', () {
      final s = BatteryState();
      final p = BatteryParser(state: s);
      p.addBytes([0xAB, 0xBA, 0x01, 0xCD, 0xDC]);
      p.addBytes([0xAB, 0xBA, 0x02, 0xCD, 0xDC]);
      p.addBytes([0xAB, 0xBA, 0x03, 0xCD, 0xDC]);
      expect(s.capacityWriteAck, isNull);
      p.addBytes([0xAB, 0xBA, 0x04, 0xCD, 0xDC]);
      expect(s.capacityWriteAck, isTrue);
    });
  });

  group('L4: table-driven frame dispatch', () {
    test('the dispatch table covers every RX begin sentinel in PROTOCOL.md',
        () {
      final begins = BatteryParser().knownBegins;
      expect(begins, {
        (0xA0, 0xC1), // VOL
        (0xA1, 0x4F), // TEMP
        (0xA2, 0x57), // ALL_DATA
        (0xA3, 0x9F), // MOS_STATUS
        (0xA4, 0x8B), // WARN_CUR
        (0xA5, 0x99), // WARN_VOL
        (0xA6, 0xC0), // WARN_TEMP
        (0xA7, 0x4E), // OTHER
        (0xA8, 0xAC), // BAL_STATUS
        (0xA9, 0x64), // SOC
        (0xAA, 0xAF), // EST_TIME
        (0xAB, 0xBA), // SETTING_RESPOND
        (0xAC, 0x9A), // VERSION
        (0xAC, 0xCA), // SLEEP_SET_SUCCESS
        (0xD2, 0x7E), // GATE_SET
        (0xFE, 0xC9), // HISTORY 1
        (0xBD, 0x8A), // HISTORY 2
      });
    });

    test('a fixed frame with a bad end sentinel resyncs by one byte', () {
      final s = BatteryState();
      final p = BatteryParser(state: s);
      // TEMP frame with a wrong end, then a good one.
      p.addBytes([0xA1, 0x4F, 0x20, 25, 0x20, 26, 0x00, 0x00]);
      expect(s.temp1, isNull);
      expect(s.unrecognisedBytes, greaterThan(0));
      p.addBytes([0xA1, 0x4F, 0x20, 25, 0x20, 26, 0xB2, 0xE3]);
      expect(s.temp1, 25);
      expect(s.temp2, 26);
    });

    test('a stream of every fixed frame back-to-back decodes in one drain',
        () {
      final s = BatteryState();
      final events = <BatteryEvent>[];
      final p = BatteryParser(state: s, onEvent: events.add);
      p.addBytes([
        ...[0xA1, 0x4F, 0x20, 25, 0x20, 26, 0xB2, 0xE3], // TEMP
        ...[0xA3, 0x9F, 1, 1, 0, 0, 0, 0, 0xB4, 0xC7], // MOS
        ...bal(), // BAL
        ...[0xAA, 0xAF, 1, 0, 0, 2, 0, 0, 0xBB, 0x22], // EST
        ...[0xAC, 0x9A, 0x31, 0x2E, 0x30, 0x2E, 0x31, 0xBD, 0x10], // VER
        ...[0xAC, 0xCA, 0x01, 0xDE, 0xED], // SLEEP
        ...[0xAB, 0xBA, 0x04, 0xCD, 0xDC], // SETTING
        ...[0xD2, 0x7E, 1, 1, 1, 0, 0, 0, 0, 0, 0xFA, 0x4B], // GATE_SET
      ]);
      expect(events.map((e) => e.runtimeType), [
        TempEvent,
        MosEvent,
        BalancerEvent,
        EstTimeEvent,
        VersionEvent,
        SleepEvent,
        SettingRespondEvent,
        GateSetEvent,
      ]);
      expect(s.unrecognisedBytes, 0);
      expect(s.firmwareVersion, '1.0.1');
    });
  });

  group('L9: pluralisation', () {
    test('1 battery / N batteries', () {
      expect(pluralBatteries(0), '0 batteries');
      expect(pluralBatteries(1), '1 battery');
      expect(pluralBatteries(2), '2 batteries');
    });
  });

  group('L11: no throw after dispose', () {
    test('disconnect(), a late frame and a late link drop are all harmless',
        () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      final link = t.lastLink!;
      await c.dispose();
      await c.disconnect(); // _setConn on the closed controller
      c.parser.addBytes(bal()); // _events.add on the closed controller
      link.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.connState, ConnState.disconnected);
    });
  });

  group('L15: connectTo is bounded by connectTimeout', () {
    test('a hung transport.connect times out as a normal failed connect',
        () async {
      final t = FakeTransport()..connectGate = Completer<void>(); // never
      final c = BatteryConnection(
        transport: t,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(c.connectTo('dev-1', name: 'JS-A'),
          throwsA(isA<TimeoutException>()));
      expect(c.connState, ConnState.disconnected,
          reason: 'eligible for the rescan to retry');
      expect(c.alarmActive, isFalse, reason: 'a failed connect never alarms');
    });

    test('a link that arrives AFTER the timeout is dropped, not adopted',
        () async {
      final gate = Completer<void>();
      final t = FakeTransport()..connectGate = gate;
      final c = BatteryConnection(
        transport: t,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(c.connectTo('dev-1', name: 'JS-A'),
          throwsA(isA<TimeoutException>()));
      gate.complete(); // the transport finally connects
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.connState, ConnState.disconnected,
          reason: 'the superseded attempt must not flip the row to connected');
      expect(t.lastLink!.disconnected, isTrue,
          reason: 'the late link is released');
      expect(t.writes, isEmpty, reason: 'no handshake on the late link');
    });

    test('the manager clears its dedupe slot and arms a backoff on timeout',
        () async {
      var clock = DateTime.utc(2026, 1, 1, 12);
      final t = FakeTransport()..connectGate = Completer<void>();
      final m = BatteryManager(now: () => clock);
      final c = BatteryConnection(
        transport: t,
        connectTimeout: const Duration(milliseconds: 50),
      )..state.serial = 'JS-A';
      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(m.connectingIds, isEmpty);
      expect(m.nextAttemptMsFor('dev-1'), isNotNull);
    });

    test('the default timeout is 45 s', () {
      expect(BatteryConnection.defaultConnectTimeout,
          const Duration(seconds: 45));
      expect(BatteryConnection(transport: FakeTransport()).connectTimeout,
          const Duration(seconds: 45));
    });
  });
}
