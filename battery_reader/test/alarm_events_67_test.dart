/// GitHub #67: alarm EVENT records. Every alarm-byte transition (set /
/// cleared, documented bit or unknown byte) becomes one `alarm_events` row
/// carrying a snapshot of the pack state, the last command sent and the time
/// since connect — captured by the REAL parser on a [FakeTransport] link,
/// stored by the logger (schema v4, additive) and rendered by
/// [AlarmEventsSection].
library;

import 'dart:io';

import 'package:battery_reader/alarm_events.dart';
import 'package:battery_reader/alarm_events_view.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/fmt.dart';
import 'package:battery_reader/raw_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'fakes.dart';

/// A settable clock the connection stamps every frame and TX with.
class _Clock {
  DateTime t;
  _Clock(this.t);
  DateTime now() => t;
  void advance(Duration d) => t = t.add(d);
  int get ms => t.millisecondsSinceEpoch;
}

// --- frames (begin + payload incl. end sentinel) ---------------------------

/// ALL_DATA (A2 57): 13.2 V, 0.0 A, load attached, chip 0 C, cells
/// 3.30..3.31 V (delta 0.01), 0 W, 3 cycles.
const allData = [
  0xA2, 0x57, //
  132, 0, // pack V = 13.2
  0, 0, 0, // current 0
  1, 0, // load, charger
  0, // chip temp
  132, 0, // cell sum
  0xEE, 0x0C, // max 3310 -> 3.31
  0xE4, 0x0C, // min 3300 -> 3.30
  10, 0, // diff 0.01
  0, 0, // power
  3, 0, // cycles
  0xE9, 0x0C, // avg
  0xB3, 0x6C,
];

/// BAL_STATUS (A8 AC): idle, charge MOS on, output MOS OFF, temp gate 1.
const balOutputOff = [0xA8, 0xAC, 0, 1, 0, 0, 1, 0, 0, 0xB9, 0x21];

/// BAL_STATUS: discharging, both MOS on.
const balBothOn = [0xA8, 0xAC, 2, 1, 1, 0, 1, 0, 0, 0xB9, 0x21];

/// TEMP (A1 4F): 31 / 32 / 31 / 32 C.
const temps = [0xA1, 0x4F, 31, 32, 32, 31, 0xB2, 0xE3];

/// SOC (A9 64): 93 %, full 100.000 Ah, remaining 93.000 Ah.
const soc = [0xA9, 0x64, 93, 0xA0, 0x86, 0x01, 0x48, 0x6B, 0x01, 0xBA, 0x5E];

/// Current alarm (A4 8B): 5 data bytes, end B5 DD.
List<int> curAlarm(List<int> data) => [0xA4, 0x8B, ...data, 0xB5, 0xDD];

/// Temperature alarm (A6 C0): 7 data bytes, end B7 72.
List<int> tempAlarm(List<int> data) => [0xA6, 0xC0, ...data, 0xB7, 0x72];

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('alarm67_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));
  setUp(() => AppLog.instance.echoToConsole = false);

  var n = 0;
  String freshPath() => '${tmp.path}${Platform.pathSeparator}db${n++}.db';

  Future<Database> ffiOpen(String path, OpenDatabaseOptions o) =>
      databaseFactoryFfi.openDatabase(path, options: o);

  BatteryLogger openLogger(String path) =>
      BatteryLogger.custom(path: path, opener: ffiOpen);

  /// A connected pack on the real parser with a fake clock, primed with the
  /// telemetry frames above and a baseline (all-zero) current alarm frame.
  Future<(BatteryConnection, FakeTransport, _Clock)> primed(
      BatteryLogger log) async {
    final clock = _Clock(DateTime(2026, 9, 21, 15, 6, 50));
    final t = FakeTransport();
    final c = BatteryConnection(transport: t, now: clock.now);
    log.attach(c);
    await c.connectTo('dev-b8', name: 'JS-2C14B8');
    final feed = t.lastLink!.onData!;
    feed(allData);
    feed(balOutputOff);
    feed(temps);
    feed(soc);
    feed(curAlarm([0, 0, 0, 0, 0])); // baseline: no event
    return (c, t, clock);
  }

  group('#67 capture through the real parser', () {
    test('a rising transition writes ONE row with the snapshot', () async {
      final log = openLogger(freshPath());
      await log.init();
      final (c, t, clock) = await primed(log);
      final raw = <String>[];
      RawLogger.instance.onLine = raw.add;
      addTearDown(() => RawLogger.instance.onLine = null);

      // 15:06:58.8 — Output ON (a safe write, goes out on any connected link).
      clock.advance(const Duration(milliseconds: 8800));
      await c.sendGateControl(GateAction.dischargeMos, on: true);
      expect(c.lastTxLabel, 'gate control output on');
      expect(c.lastTxBytes, t.writes.last);
      expect(c.lastTxMs, clock.ms);

      // 15:06:59.3 — short-circuit protection bit sets, current still 0 A,
      // output MOS still reads off.
      clock.advance(const Duration(milliseconds: 500));
      final events = <AlarmEvent>[];
      final sub = c.alarmEvents.listen(events.add);
      t.lastLink!.onData!(curAlarm([0, 0, 1, 0, 0]));
      await log.drain();
      await sub.cancel();

      expect(events.length, 1, reason: 'one transition, one event');
      final rows = await log.debugDb!.query('alarm_events');
      expect(rows.length, 1);
      final r = rows.single;
      expect(r['serial'], 'JS-2C14B8');
      expect(r['at_ms'], clock.ms);
      expect(r['at_time'], fmtStampMs(clock.ms));
      expect(r['frame'], 'current');
      expect(r['byte_index'], 2);
      expect(r['bit_name'], 'Short circuit protection');
      expect(r['transition'], 'set');
      expect(r['from_value'], 0);
      expect(r['to_value'], 1);
      expect(r['duration_ms'], isNull, reason: 'not cleared yet');
      // Snapshot.
      expect(r['pack_i'], 0.0);
      expect(r['pack_v'], 13.2);
      expect(r['cell_min'], 3.30);
      expect(r['cell_max'], 3.31);
      expect(r['cell_delta'], 0.01);
      expect(r['temp0'], 31);
      expect(r['temp1'], 32);
      expect(r['temp2'], 31);
      expect(r['temp3'], 32);
      expect(r['chip'], 0);
      expect(r['soc'], 93);
      expect(r['charge_state'], 'idle');
      expect(r['chg_mos'], 1);
      expect(r['dis_mos'], 0);
      expect(r['temp_gate'], 1);
      expect(r['smoke_gate'], 0);
      expect(r['heat_gate'], 0);
      expect(r['over_temp_latched'], 0);
      expect(r['standby_on'], isNull, reason: 'never reported on this link');
      expect(r['last_tx_label'], 'gate control output on');
      expect(r['last_tx_hex'], hexOf(t.writes.last));
      expect(r['since_last_tx_ms'], 500);
      expect(r['since_connect_ms'], 9300);

      // The same event reached the raw log as an ALARM line and Diagnostics.
      expect(raw, anyElement(contains('ALARM')));
      expect(raw.singleWhere((l) => l.contains('ALARM')),
          contains("current byte 2 'Short circuit protection' 0 -> 1 (set)"));
      expect(AppLog.instance.entries.map((e) => e.source),
          contains('Alarm JS-2C14B8'));
      // Display text.
      final ev = (await log.alarmEvents('JS-2C14B8')).single;
      expect(
          ev.describe(),
          '21 Sep 15:06:59  Short circuit protection SET — 0.0 A · 13.2 V · '
          "charge on · output off · 0.5 s after 'gate control output on'");
      // Sync stats for Diagnostics.
      expect(log.alarmSummaryLine('JS-2C14B8'),
          '1 alarm event, last 21 Sep 15:06:59 Short circuit protection set');
      await c.dispose();
      await log.dispose();
    });

    test('a falling transition writes the cleared row and back-fills the set',
        () async {
      final log = openLogger(freshPath());
      await log.init();
      final (c, t, clock) = await primed(log);
      final feed = t.lastLink!.onData!;
      clock.advance(const Duration(milliseconds: 9300));
      feed(curAlarm([0, 0, 1, 0, 0])); // set at 15:06:59.3
      // FETs close: both MOS on, discharging 1.5 A.
      feed(balBothOn);
      clock.advance(const Duration(milliseconds: 1700));
      feed(curAlarm([0, 0, 0, 0, 0])); // cleared at 15:07:01.0
      await log.drain();

      final rows =
          await log.debugDb!.query('alarm_events', orderBy: 'at_ms ASC');
      expect(rows.length, 2);
      expect(rows[0]['transition'], 'set');
      expect(rows[0]['duration_ms'], 1700, reason: 'back-filled');
      expect(rows[1]['transition'], 'cleared');
      expect(rows[1]['duration_ms'], 1700);
      expect(rows[1]['from_value'], 1);
      expect(rows[1]['to_value'], 0);
      expect(rows[1]['charge_state'], 'discharging');
      expect(rows[1]['dis_mos'], 1);

      final list = await log.alarmEvents('JS-2C14B8');
      expect(list.length, 2, reason: 'newest first');
      expect(list.first.isSet, isFalse);
      expect(list.first.describe(), contains('CLEARED'));
      expect(list.first.describe(), endsWith('was set for 1.7 s'));
      expect(list.last.describe(), endsWith('cleared after 1.7 s'));
      expect(list.last.describe(), contains('charge on · output off'),
          reason: 'the SET snapshot predates the FETs closing');
      expect(list.first.describe(), contains('MOS on'),
          reason: 'the CLEARED snapshot has both MOS on');
      expect(await log.alarmEventCount('JS-2C14B8'), 2);
      expect(log.alarmStats('JS-2C14B8').count, 2);
      await c.dispose();
      await log.dispose();
    });

    test('a cleared row resolves a set row stored by an EARLIER session',
        () async {
      final path = freshPath();
      final log = openLogger(path);
      await log.init();
      final t0 = DateTime(2026, 9, 21, 15, 6, 59, 300).millisecondsSinceEpoch;
      // A set row from a previous run (no in-memory context for it).
      log.recordAlarmEvent(AlarmEvent(
          serial: 'JS-X',
          atMs: t0,
          frame: 'temperature',
          byteIndex: 2,
          bitName: alarmBitName('temperature', 2),
          transition: AlarmEvent.set,
          fromValue: 0,
          toValue: 1));
      await log.drain();
      log.recordAlarmEvent(AlarmEvent(
          serial: 'JS-X',
          atMs: t0 + 5000,
          frame: 'temperature',
          byteIndex: 2,
          bitName: alarmBitName('temperature', 2),
          transition: AlarmEvent.cleared,
          fromValue: 1,
          toValue: 0));
      await log.drain();
      final rows =
          await log.debugDb!.query('alarm_events', orderBy: 'at_ms ASC');
      expect(rows[0]['duration_ms'], 5000);
      expect(rows[1]['duration_ms'], 5000);
      expect(rows[0]['bit_name'], 'Latched over-temperature protection');
      await log.dispose();
    });

    test('an unknown byte is labelled and still recorded; the latched flag '
        'is named', () async {
      final log = openLogger(freshPath());
      await log.init();
      final (c, t, clock) = await primed(log);
      final feed = t.lastLink!.onData!;
      feed(tempAlarm([0, 0, 1, 0, 0, 0, 0])); // baseline, latched already 1
      clock.advance(const Duration(seconds: 1));
      feed(curAlarm([0, 0, 0, 1, 0])); // current byte 3: undocumented
      clock.advance(const Duration(seconds: 1));
      feed(tempAlarm([0, 0, 0, 0, 0, 0, 0])); // latched flag clears
      await log.drain();
      final list = await log.alarmEvents('JS-2C14B8');
      expect(list.length, 2);
      expect(list.last.bitName, 'unknown byte 3');
      expect(list.last.frame, 'current');
      expect(list.last.byteIndex, 3);
      expect(list.first.bitName, 'Latched over-temperature protection');
      expect(list.first.transition, 'cleared');
      expect(list.first.durationMs, isNull,
          reason: 'set before any record existed');
      expect(alarmBitName('voltage', 4), 'unknown byte 4');
      expect(alarmBitName('voltage', 3), 'Voltage difference alarm');
      await c.dispose();
      await log.dispose();
    });

    test('the first frame of each alarm kind is a baseline, not an event',
        () async {
      final log = openLogger(freshPath());
      await log.init();
      final (c, t, _) = await primed(log);
      final feed = t.lastLink!.onData!;
      feed(tempAlarm([0, 0, 1, 0, 0, 0, 0])); // already latched at contact
      feed(tempAlarm([0, 0, 1, 0, 0, 0, 0]));
      feed(curAlarm([0, 0, 0, 0, 0]));
      await log.drain();
      expect(await log.alarmEventCount('JS-2C14B8'), 0);
      await c.dispose();
      await log.dispose();
    });
  });

  group('#67 schema v4', () {
    test('upgrading a v3 store keeps readings and lifetime_totals', () async {
      final path = freshPath();
      final v3 = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE readings ('
                  ' id INTEGER PRIMARY KEY, serial TEXT NOT NULL,'
                  ' metric TEXT NOT NULL, value_num REAL, value_text TEXT,'
                  ' start_time TEXT NOT NULL, end_time TEXT NOT NULL,'
                  ' start_ms INTEGER, end_ms INTEGER)');
              await db.execute('CREATE INDEX ix_readings ON readings '
                  '(serial, metric, start_time)');
              await db.execute('CREATE INDEX ix_readings_ms ON readings '
                  '(serial, metric, start_ms)');
              await db.execute('CREATE TABLE lifetime_totals ('
                  ' serial TEXT PRIMARY KEY,'
                  ' total_charge_ah REAL NOT NULL DEFAULT 0,'
                  ' total_discharge_ah REAL NOT NULL DEFAULT 0,'
                  ' total_efc REAL NOT NULL DEFAULT 0,'
                  ' aggregated_up_to TEXT, aggregated_up_to_ms INTEGER)');
            },
          ));
      const t1 = '2026-09-21 15:06:50.000', t2 = '2026-09-21 15:07:10.000';
      final ms1 = BatteryLogger.parseTime(t1), ms2 = BatteryLogger.parseTime(t2);
      await v3.insert('readings', {
        'id': 1,
        'serial': 'JS-A',
        'metric': Metric.packCurrent,
        'value_num': -89.0,
        'start_time': t1,
        'end_time': t2,
        'start_ms': ms1,
        'end_ms': ms2,
      });
      await v3.insert('readings', {
        'id': 2,
        'serial': 'JS-A',
        'metric': Metric.flags,
        'value_num': 1.0,
        'start_time': t1,
        'end_time': t2,
        'start_ms': ms1,
        'end_ms': ms2,
      });
      await v3.insert('lifetime_totals', {
        'serial': 'JS-A',
        'total_charge_ah': 1.5,
        'total_discharge_ah': 2.5,
        'total_efc': 0.04,
        'aggregated_up_to': t2,
        'aggregated_up_to_ms': ms2,
      });
      await v3.close();

      final log = openLogger(path);
      await log.init();
      expect(log.enabled, isTrue);
      final db = log.debugDb!;
      expect(await db.getVersion(), 4);
      expect(BatteryLogger.schemaVersion, 4);
      final rows = await db.query('readings', orderBy: 'id');
      expect(rows.length, 2);
      expect(rows[0]['value_num'], -89.0);
      expect(rows[0]['start_ms'], ms1);
      expect(rows[1]['metric'], Metric.flags);
      final lt = await log.lifetimeTotals('JS-A');
      expect(lt.chargeAh, 1.5);
      expect(lt.dischargeAh, 2.5);
      expect(lt.aggregatedUpToMs, ms2);
      final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='alarm_events'");
      expect(tables, isNotEmpty);
      final idx = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='ix_alarm_events'");
      expect(idx, isNotEmpty);
      final cols = await db.rawQuery('PRAGMA table_info(alarm_events)');
      final names = {for (final c in cols) c['name'] as String};
      expect(
          names,
          containsAll([
            'serial', 'at_ms', 'at_time', 'frame', 'byte_index', 'bit_name',
            'transition', 'duration_ms', 'pack_i', 'pack_v', 'cell_min',
            'cell_max', 'cell_delta', 'temp0', 'temp1', 'temp2', 'temp3',
            'chip', 'soc', 'charge_state', 'chg_mos', 'dis_mos', 'temp_gate',
            'smoke_gate', 'heat_gate', 'over_temp_latched', 'standby_on',
            'last_tx_label', 'last_tx_hex', 'since_last_tx_ms',
            'since_connect_ms', //
          ]));
      // Still writable after the upgrade.
      expect(await log.alarmEvents('JS-A'), isEmpty);
      await log.dispose();
    });
  });

  group('#67 text + section', () {
    final example = AlarmEvent(
      serial: 'JS-2C14B8',
      atMs: DateTime(2026, 9, 21, 15, 6, 59, 300).millisecondsSinceEpoch,
      frame: 'current',
      byteIndex: 2,
      bitName: alarmBitName('current', 2),
      transition: AlarmEvent.set,
      fromValue: 0,
      toValue: 1,
      durationMs: 1700,
      packI: 0.0,
      packV: 13.2,
      chgMos: 0,
      disMos: 0,
      lastTxLabel: 'Output ON',
      sinceLastTxMs: 500,
    );

    test('describe() renders the canonical example', () {
      expect(
          example.describe(),
          '21 Sep 15:06:59  Short circuit protection SET — 0.0 A · 13.2 V · '
          "MOS off · 0.5 s after 'Output ON' · cleared after 1.7 s");
      expect(fmtShortStamp(example.atMs), '21 Sep 15:06:59');
      expect(example.toRow()['at_time'], '2026-09-21 15:06:59.300');
      expect(AlarmEvent.fromRow(example.toRow()).describe(), example.describe());
      expect(alarmEventsCopyText('JS-2C14B8', [example]),
          startsWith('Alarm events JS-2C14B8 (1, newest first)\n21 Sep'));
      expect(const AlarmStats().summaryLine, 'no alarm events');
    });

    testWidgets('the detail section renders the example text, Copy and '
        'Show all', (tester) async {
      var showAll = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            AlarmEventsSection(
              serial: 'JS-2C14B8',
              events: [example],
              total: 73,
              onShowAll: () => showAll++,
            ),
          ]),
        ),
      ));
      expect(find.text('Alarm events (73)'), findsOneWidget);
      expect(
          find.text(
              '21 Sep 15:06:59  Short circuit protection SET — 0.0 A · 13.2 V · '
              "MOS off · 0.5 s after 'Output ON' · cleared after 1.7 s"),
          findsOneWidget);
      expect(find.byTooltip('Copy'), findsOneWidget);
      await tester.tap(find.text('Show all 73'));
      expect(showAll, 1);
    });

    testWidgets('an empty section says so', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AlarmEventsSection(serial: 'JS-A', events: [], total: 0),
        ),
      ));
      expect(find.text('Alarm events'), findsOneWidget);
      expect(find.textContaining('None recorded'), findsOneWidget);
    });
  });
}
