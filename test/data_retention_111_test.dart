/// #111: nothing is deleted automatically. Raw-log rotation keeps every file;
/// "Keep data" defaults to All (nothing runs); a chosen period deletes only
/// rows / files older than the cutoff and never lifetime totals or settings;
/// the one-off deletes; the export carries every rotated log.
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/data_export.dart';
import 'package:battery_reader/data_retention.dart';
import 'package:battery_reader/monitoring_policy.dart';
import 'package:battery_reader/raw_log.dart';
import 'package:battery_reader/settings_page.dart';
import 'package:battery_reader/settings_store.dart';
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
    tmp = Directory.systemTemp.createTempSync('retention111_');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  var n = 0;
  Directory freshDir() =>
      Directory(p.join(tmp.path, 'case${n++}'))..createSync(recursive: true);

  Future<Database> ffiOpen(String path, OpenDatabaseOptions o) =>
      databaseFactoryFfi.openDatabase(path, options: o);

  // "Now" for every retention test, and one old / one recent instant.
  final now = DateTime(2026, 9, 24, 12);
  final old = DateTime(2026, 5, 1, 10).millisecondsSinceEpoch; // > 3 months
  final recent = DateTime(2026, 9, 1, 10).millisecondsSinceEpoch;
  const hour = 3600 * 1000;

  // Seeded ids start high so they never meet the logger's own ids.
  var nextId = 100000;
  Future<void> reading(Database db, String serial, String metric, double v,
      int startMs, int endMs) async {
    await db.insert('readings', {
      'id': nextId++,
      'serial': serial,
      'metric': metric,
      'value_num': v,
      'start_time': BatteryLogger.fmtTime(startMs),
      'end_time': BatteryLogger.fmtTime(endMs),
      'start_ms': startMs,
      'end_ms': endMs,
    });
  }

  Future<void> alarm(Database db, String serial, int atMs) =>
      db.insert('alarm_events', {
        'serial': serial,
        'at_ms': atMs,
        'at_time': BatteryLogger.fmtTime(atMs),
        'frame': 'A7',
        'byte_index': 1,
        'bit_name': 'b0',
        'transition': 'set',
      });

  Future<int> count(Database db, String table) async =>
      ((await db.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n']
              as num)
          .toInt();

  /// A store with old + recent readings and alarms for JS-A, and a lifetime
  /// row whose watermark is past every row (so its totals are final).
  Future<BatteryLogger> seeded(Directory dir) async {
    final log = BatteryLogger.custom(
        path: p.join(dir.path, 'db.sqlite'), opener: ffiOpen);
    await log.init();
    final db = log.debugDb!;
    await reading(db, 'JS-A', Metric.soc, 80, old, old + hour);
    await reading(db, 'JS-A', Metric.soc, 81, old + hour, old + 2 * hour);
    await reading(db, 'JS-A', Metric.soc, 90, recent, recent + hour);
    await alarm(db, 'JS-A', old);
    await alarm(db, 'JS-A', recent);
    await db.insert('lifetime_totals', {
      'serial': 'JS-A',
      'total_charge_ah': 5.6,
      'total_discharge_ah': 3.4,
      'total_efc': 0.09,
      'aggregated_up_to': BatteryLogger.fmtTime(recent + 2 * hour),
      'aggregated_up_to_ms': recent + 2 * hour,
    });
    return log;
  }

  /// A raw log in [dir] with a live file and three rotated files: one old,
  /// one recent, and a legacy `battery_raw.1.log` written just now.
  Future<RawLogger> seededRaw(Directory dir) async {
    File(p.join(dir.path, 'battery_raw.20260501-100000.log'))
        .writeAsStringSync('old lines\n');
    File(p.join(dir.path, 'battery_raw.20260901-100000.log'))
        .writeAsStringSync('recent lines\n');
    File(p.join(dir.path, RawLogger.legacyRotatedFileName))
        .writeAsStringSync('legacy lines\n');
    File(p.join(dir.path, 'unrelated.txt')).writeAsStringSync('not a log');
    final raw = RawLogger.forTest(dir: dir);
    await raw.init();
    raw.logRaw('JS-A', [1, 2, 3]);
    await raw.flush();
    return raw;
  }

  /// The raw-log files (and the unrelated one) in [dir]; SQLite side files
  /// are left out.
  Set<String> names(Directory dir) => {
        for (final e in dir.listSync())
          if (!p.basename(e.path).startsWith('db.sqlite')) p.basename(e.path),
      };

  KeepData shown(WidgetTester tester) => tester
      .widget<DropdownButton<KeepData>>(find.byKey(const ValueKey('keepData')))
      .value!;

  group('rotated file names (pure)', () {
    test('name carries the local close time and parses back', () {
      final t = DateTime(2026, 9, 24, 14, 5, 1);
      final name = RawLogger.rotatedFileNameAt(t);
      expect(name, 'battery_raw.20260924-140501.log');
      expect(RawLogger.rotatedAt(name), t);
      expect(RawLogger.rotatedAt('battery_raw.20260924-140501-3.log'), t);
      expect(RawLogger.rotatedAt(RawLogger.fileName), isNull);
    });

    test('the legacy .1 file counts as rotated; the live file does not', () {
      expect(RawLogger.isRotatedName('battery_raw.1.log'), isTrue);
      expect(
          RawLogger.isRotatedName('battery_raw.20260924-140501.log'), isTrue);
      expect(RawLogger.isRotatedName(RawLogger.fileName), isFalse);
      expect(RawLogger.isRotatedName('battery_raw.log.bak'), isFalse);
    });
  });

  test('init counts every rotated file, the legacy one included', () async {
    final dir = freshDir();
    final raw = await seededRaw(dir);
    expect(raw.rotatedCount, 3);
    expect(
        raw.rotatedBytes,
        'old lines\n'.length +
            'recent lines\n'.length +
            'legacy lines\n'.length);
    expect(raw.totalBytes, raw.rotatedBytes + raw.sizeBytes);
    await raw.dispose();
  });

  group('Keep data setting', () {
    test('defaults to All when unset or unknown', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore();
      expect(KeepData.fromMonths(await s.loadKeepDataMonths()), KeepData.all);
      expect(KeepData.fromMonths(7), KeepData.all,
          reason: 'a damaged value can never delete data');
      await s.saveKeepDataMonths(6);
      expect(
          KeepData.fromMonths(await s.loadKeepDataMonths()), KeepData.months6);
    });

    test('monthsBefore clamps to the target month', () {
      expect(
          monthsBefore(DateTime(2026, 5, 31, 8), 3), DateTime(2026, 2, 28, 8));
      expect(monthsBefore(DateTime(2026, 2, 15), 12), DateTime(2025, 2, 15));
      expect(monthsBefore(now, 3), DateTime(2026, 6, 24, 12));
    });

    test('the default (All) deletes nothing and schedules nothing', () async {
      final dir = freshDir();
      final log = await seeded(dir);
      final raw = await seededRaw(dir);
      final before = names(dir);
      final job = RetentionJob(store: log, raw: raw, clock: () => now);
      expect(await job.configure(KeepData.all), isNull);
      expect(job.scheduled, isFalse);
      expect(await job.runOnce(), isNull);
      final db = log.debugDb!;
      expect(await count(db, 'readings'), 3);
      expect(await count(db, 'alarm_events'), 2);
      expect(names(dir), before);
      await raw.dispose();
      await log.dispose();
    });

    test(
        'a period deletes only what is older than the cutoff, never '
        'lifetime totals or settings', () async {
      SharedPreferences.setMockInitialValues(
          {'keep_data_months_v1': 3, 'aliases_v1': '{"JS-A":"Van"}'});
      final dir = freshDir();
      final log = await seeded(dir);
      final raw = await seededRaw(dir);
      final totalsBefore = await log.lifetimeTotals('JS-A');
      final job = RetentionJob(store: log, raw: raw, clock: () => now);
      final done = await job.configure(KeepData.months3);
      expect(job.scheduled, isTrue, reason: 'runs daily from now on');
      job.stop();
      expect(done!.readings, 2);
      expect(done.alarmEvents, 1);
      expect(done.logFiles, 1);

      final db = log.debugDb!;
      final left = await db.query('readings');
      expect(left.single['value_num'], 90.0);
      final alarms = await db.query('alarm_events');
      expect(alarms.single['at_ms'], recent);
      final totals = await log.lifetimeTotals('JS-A');
      expect(totals.chargeAh, totalsBefore.chargeAh);
      expect(totals.dischargeAh, totalsBefore.dischargeAh);
      expect(totals.aggregatedUpToMs, totalsBefore.aggregatedUpToMs);

      final files = names(dir);
      expect(files, isNot(contains('battery_raw.20260501-100000.log')));
      expect(files, contains('battery_raw.20260901-100000.log'));
      expect(files, contains(RawLogger.legacyRotatedFileName),
          reason: 'written just now, so newer than the cutoff');
      expect(files, contains(RawLogger.fileName), reason: 'live file kept');
      expect(files, contains('unrelated.txt'));
      expect(raw.rotatedCount, 2);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('keep_data_months_v1'), 3);
      expect(prefs.getString('aliases_v1'), '{"JS-A":"Van"}');
      await raw.dispose();
      await log.dispose();
    });

    test(
        'pack current not yet in the lifetime totals is folded in before '
        'its rows are deleted', () async {
      Future<BatteryLogger> withCurrent() async {
        final log = BatteryLogger.custom(
            path: p.join(freshDir().path, 'db.sqlite'), opener: ffiOpen);
        await log.init();
        final db = log.debugDb!;
        await reading(db, 'JS-C', Metric.packCurrent, 10, old, old + hour);
        await reading(
            db, 'JS-C', Metric.packCurrent, -4, old + hour, old + 2 * hour);
        await reading(db, 'JS-C', Metric.packCurrent, 2, recent, recent + hour);
        return log;
      }

      final reference = await withCurrent();
      final expected = await reference.updateLifetimeTotals('JS-C');
      expect(expected.chargeAh, greaterThan(0));
      await reference.dispose();

      final log = await withCurrent();
      final h = await log.deleteHistory(
          beforeMs: monthsBefore(now, 3).millisecondsSinceEpoch);
      expect(h.done, isTrue);
      expect(h.readings, 2);
      final got = await log.lifetimeTotals('JS-C');
      expect(got.chargeAh, closeTo(expected.chargeAh, 1e-9));
      expect(got.dischargeAh, closeTo(expected.dischargeAh, 1e-9));
      await log.dispose();
    });

    test('the delete runs on the write queue, after writes queued before it',
        () async {
      final log = BatteryLogger.custom(
          path: p.join(freshDir().path, 'db.sqlite'), opener: ffiOpen);
      await log.init();
      final conn = BatteryConnection(transport: NoopTransport());
      conn.state.serial = 'JS-Q';
      conn.state.socPercent = 50;
      log.observeConnection(conn, nowMs: old); // insert queued, not awaited
      final h = await log.deleteHistory(
          beforeMs: monthsBefore(now, 3).millisecondsSinceEpoch);
      expect(h.readings, greaterThan(0),
          reason: 'the queued insert landed first');
      expect(await count(log.debugDb!, 'readings'), 0);
      await log.dispose();
      await conn.dispose();
    });
  });

  group('one-off deletes', () {
    test('Delete data older than… keeps newer rows, files and totals',
        () async {
      final dir = freshDir();
      final log = await seeded(dir);
      final raw = await seededRaw(dir);
      final done = await deleteDataBefore(DateTime(2026, 8, 1),
          store: log, raw: raw, compact: true);
      expect(done.storeDone, isTrue);
      expect(done.summary, 'Deleted 2 readings, 1 alarm event and 1 log file');
      expect(await count(log.debugDb!, 'readings'), 1);
      expect(await count(log.debugDb!, 'lifetime_totals'), 1);
      expect(names(dir), contains('battery_raw.20260901-100000.log'));
      await raw.dispose();
      await log.dispose();
    });

    test(
        'Delete all data empties history and logs; totals kept; logging '
        'carries on', () async {
      final dir = freshDir();
      final log = await seeded(dir);
      final raw = await seededRaw(dir);
      final conn = BatteryConnection(transport: NoopTransport());
      conn.state.serial = 'JS-A';
      conn.state.socPercent = 70;
      log.observeConnection(conn, nowMs: recent + 3 * hour); // an open row
      await log.drain();

      final done = await deleteAllData(store: log, raw: raw);
      expect(done.readings, greaterThanOrEqualTo(4));
      expect(done.alarmEvents, 2);
      expect(done.logFiles, 3);
      final db = log.debugDb!;
      expect(await count(db, 'readings'), 0);
      expect(await count(db, 'alarm_events'), 0);
      expect(await count(db, 'lifetime_totals'), 1);
      expect((await log.lifetimeTotals('JS-A')).chargeAh, 5.6);
      expect(names(dir), {RawLogger.fileName, 'unrelated.txt'},
          reason: 'every rotated file gone, the live file kept');
      expect(raw.rotatedCount, 0);

      // The same value again starts a NEW row (the open one was deleted).
      log.observeConnection(conn, nowMs: recent + 3 * hour + 1000);
      await log.drain();
      final rows = await db.query('readings',
          where: 'serial = ? AND metric = ?', whereArgs: ['JS-A', Metric.soc]);
      expect(rows.single['value_num'], 70.0);
      // The raw log keeps writing into the live file (the RETENTION line).
      await raw.flush();
      expect(File(raw.path!).readAsStringSync(), contains('RETENTION'));
      await raw.dispose();
      await log.dispose();
      await conn.dispose();
    });
  });

  test('the export includes the live raw log and EVERY rotated one', () async {
    final dir = freshDir();
    final raw = await seededRaw(dir);
    final paths = await raw.allLogPaths();
    expect(paths.map(p.basename), [
      'battery_raw.20260501-100000.log',
      'battery_raw.20260901-100000.log',
      RawLogger.legacyRotatedFileName,
      RawLogger.fileName,
    ]);
    final work = freshDir();
    final zip = await buildExportZip(
        workDir: work, dbSnapshot: null, logFiles: paths, prefs: const {});
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    final inZip = {for (final f in archive.files) f.name};
    for (final path in paths) {
      expect(inZip, contains(p.basename(path)));
    }
    await raw.dispose();
  });

  group('Settings → Data rows', () {
    Future<List<KeepData>> pumpPage(WidgetTester tester,
        {double width = 1200}) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <KeepData>[];
      await tester.pumpWidget(MaterialApp(
        home: SettingsPage(
          settings: SettingsStore(),
          demoMode: false,
          onDemoModeChanged: (_) {},
          useFahrenheit: false,
          onTempUnitChanged: (_) {},
          alertNotifications: true,
          onAlertNotificationsChanged: (_) {},
          backgroundMonitoring: true,
          onBackgroundMonitoringChanged: (_) {},
          sampleInterval: BackgroundSampleInterval.m5,
          onSampleIntervalChanged: (_) {},
          monitoringPaused: false,
          onMonitoringPausedChanged: (_) {},
          onExit: () {},
          onKeepDataChanged: (k) async {
            calls.add(k);
            return null;
          },
        ),
      ));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('storage, Keep data (All by default) and the delete rows show',
        (tester) async {
      await pumpPage(tester);
      expect(find.text('Keep data'), findsOneWidget);
      expect(shown(tester), KeepData.all);
      expect(
          find.textContaining('All kept, nothing deleted automatically\n'
              'Using 0 B — history 0 B · raw logs 0 B in 0 files'),
          findsOneWidget);
      expect(find.text('Delete data'), findsOneWidget);
      expect(find.text('Older than…'), findsOneWidget);
      expect(find.text('All data'), findsOneWidget);
    });

    testWidgets('the two rows fit a 360 px phone without overflow',
        (tester) async {
      await pumpPage(tester, width: 360);
      expect(find.text('Keep data'), findsOneWidget);
      expect(find.text('All data'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a period needs confirmation; Cancel changes nothing',
        (tester) async {
      final calls = await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('keepData')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3 months').last);
      await tester.pumpAndSettle();
      expect(find.text('Keep only 3 months?'), findsOneWidget);
      expect(find.text('Export first'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(shown(tester), KeepData.all);

      await tester.tap(find.byKey(const ValueKey('keepData')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3 months').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep 3 months'));
      await tester.pumpAndSettle();
      expect(calls, [KeepData.months3]);
      expect(shown(tester), KeepData.months3);
      expect(find.textContaining('Older than 3 months deleted daily'),
          findsOneWidget);

      // Back to All: no confirmation needed.
      await tester.tap(find.byKey(const ValueKey('keepData')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All (default)').last);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, [KeepData.months3, KeepData.all]);
      expect(shown(tester), KeepData.all);
    });

    testWidgets('Delete all data and Delete older than… both confirm first',
        (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('All data'));
      await tester.pumpAndSettle();
      expect(find.text('Delete all data?'), findsOneWidget);
      expect(find.text('Export first'), findsOneWidget);
      expect(find.text('Delete all'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('Older than…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete data older than…'), findsOneWidget);
      await tester.tap(find.text('6 months'));
      await tester.pumpAndSettle();
      expect(find.text('Delete data older than 6 months?'), findsOneWidget);
      expect(find.text('Export first'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
