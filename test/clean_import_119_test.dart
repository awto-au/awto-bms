/// #119: check a clean-history import zip built by `scripts/build_import.py`
/// with the app's OWN import path: [stageImport] -> [commitImport] ->
/// [applyPendingImport] into a temp folder, then open the result with the real
/// [BatteryLogger] and compare counts, lifetime totals and schema with what
/// the zip's manifest promises.
///
/// Skipped unless `AWTO_IMPORT_ZIP` names one zip or several separated by `;`
/// (PowerShell):
///   $env:AWTO_IMPORT_ZIP = 'logs/import-20260924/awto-bms-import-phone.zip'
///   flutter test test/clean_import_119_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/data_export.dart';
import 'package:battery_reader/desktop_data_dir.dart' show kIntervalDbName;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

void main() {
  sqfliteFfiInit();
  final env = Platform.environment['AWTO_IMPORT_ZIP'] ?? '';
  final zips = env.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
  late Directory tmp;
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('import119_');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<Database> ffiOpen(String path, OpenDatabaseOptions o) =>
      databaseFactoryFfi.openDatabase(path, options: o);

  if (zips.isEmpty) {
    test('clean import zip (set AWTO_IMPORT_ZIP to run)', () {},
        skip: 'AWTO_IMPORT_ZIP not set');
    return;
  }

  var n = 0;
  for (final zipPath in zips) {
    test('import ${p.basename(zipPath)} through the app', () async {
      expect(File(zipPath).existsSync(), isTrue, reason: zipPath);
      final dir = Directory(p.join(tmp.path, 'case${n++}'))..createSync();
      final archive =
          ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());
      Map<String, Object?> json(String name) => (jsonDecode(utf8.decode(
              archive.files.firstWhere((f) => f.name == name).content
                  as List<int>)) as Map)
          .cast<String, Object?>();
      final manifest = json(kManifestName);
      final expected = (manifest['cleanImport'] as Map).cast<String, Object?>();
      final settings = json(kSettingsName);
      final perSerial = (expected['perSerial'] as Map).cast<String, Object?>();
      final lifetime = (expected['lifetime'] as Map).cast<String, Object?>();

      // The receiving device: an existing store with its own rows.
      final target = p.join(dir.path, 'device', kIntervalDbName);
      Directory(p.dirname(target)).createSync();
      final existing = BatteryLogger.custom(path: target, opener: ffiOpen);
      await existing.init();
      await existing.debugDb!.insert('readings', {
        'id': 1,
        'serial': 'JS-OLD',
        'metric': 'soc',
        'value_num': 50.0,
        'start_time': '2026-09-24 10:00:00.000',
        'end_time': '2026-09-24 10:00:01.000',
        'start_ms': 1,
        'end_ms': 2,
      });
      await existing.dispose();

      // 1. stage: the checks the Import dialog runs.
      final staging = importStagingDir(Directory(p.join(dir.path, 'support')));
      final summary = await stageImport(zipPath, staging);
      expect(summary.readings, expected['readings']);
      expect(summary.serials, perSerial.keys.toList()..sort());
      await commitImport(staging);

      // 2. apply, as main() does at the next start.
      SharedPreferences.setMockInitialValues(
          {'window_bounds_v1': 'this machine', 'battery_aliases_v1': 'old'});
      final prefs = await SharedPreferences.getInstance();
      final msg = await applyPendingImport(
          stagingDir: staging,
          dbPath: target,
          prefs: prefs,
          now: DateTime(2026, 9, 25, 8, 0));
      expect(msg, contains('import applied'));
      expect(File('$target.before-import-20260925-0800').existsSync(), isTrue,
          reason: 'the previous store is kept');
      expect(prefs.getString('window_bounds_v1'), 'this machine',
          reason: 'window bounds are never imported');
      for (final e in settings.entries) {
        final v = (e.value as Map)['v'];
        expect(prefs.get(e.key), v is List ? v.map((x) => '$x').toList() : v,
            reason: 'setting ${e.key}');
      }

      // 3. open with the real logger.
      final log = BatteryLogger.custom(path: target, opener: ffiOpen);
      await log.init();
      final db = log.debugDb!;
      expect(db, isNotNull, reason: 'the imported store opens');
      Future<Object?> one(String sql) async =>
          (await db.rawQuery(sql)).first.values.first;
      expect(await one('PRAGMA user_version'), BatteryLogger.schemaVersion);
      expect(await one('PRAGMA integrity_check'), 'ok');
      expect(await one('SELECT COUNT(*) FROM readings'), expected['readings']);
      expect(await one('SELECT MIN(id) FROM readings'), 1);
      expect(await one('SELECT MAX(id) FROM readings'), expected['readings']);
      expect(
          await one('SELECT COUNT(*) FROM readings WHERE start_ms IS NULL '
              'OR end_ms IS NULL OR end_ms < start_ms'),
          0);
      expect(await one('SELECT COUNT(*) FROM alarm_events'),
          expected['alarmEvents']);
      for (final e in perSerial.entries) {
        final c = await db.rawQuery(
            'SELECT COUNT(*) AS n FROM readings WHERE serial = ?', [e.key]);
        expect(c.first['n'], e.value, reason: e.key);
      }

      // Schema: the app's own objects exactly as a fresh store creates them.
      final fresh = BatteryLogger.custom(
          path: p.join(dir.path, 'fresh.db'), opener: ffiOpen);
      await fresh.init();
      Future<Map<String, String>> objects(Database d) async => {
            for (final r in await d.rawQuery(
                "SELECT name, sql FROM sqlite_master WHERE name NOT LIKE "
                "'import_%' AND name NOT LIKE 'sqlite_%'"))
              '${r['name']}':
                  '${r['sql']}'.replaceAll(RegExp(r'\s+'), ' ').trim()
          };
      expect(await objects(db), await objects(fresh.debugDb!));
      await fresh.dispose();

      // 4. lifetime totals: as stored, unchanged by the app's next fold, and
      // equal to a full re-fold by the app's integrator.
      for (final e in lifetime.entries) {
        final want = (e.value as Map).cast<String, Object?>();
        final lt = await log.lifetimeTotals(e.key);
        expect(lt.chargeAh, closeTo(want['chargeAh'] as num, 1e-9));
        expect(lt.dischargeAh, closeTo(want['dischargeAh'] as num, 1e-9));
        expect(lt.efc, closeTo(want['efc'] as num, 1e-9));
        expect(lt.aggregatedUpToMs, want['aggregatedUpToMs']);
        final next = await log.updateLifetimeTotals(e.key);
        expect(next.throughputAh, closeTo(lt.throughputAh, 1e-9),
            reason: '${e.key}: nothing left to fold');
      }
      await db.delete('lifetime_totals');
      for (final e in lifetime.entries) {
        final want = (e.value as Map).cast<String, Object?>();
        final refold = await log.updateLifetimeTotals(e.key);
        // ignore: avoid_print
        print('${p.basename(zipPath)} ${e.key}: app re-fold '
            '${refold.chargeAh} / ${refold.dischargeAh} Ah, zip '
            '${want['chargeAh']} / ${want['dischargeAh']} Ah');
        expect(refold.chargeAh, closeTo(want['chargeAh'] as num, 1e-6));
        expect(refold.dischargeAh, closeTo(want['dischargeAh'] as num, 1e-6));
        expect(refold.aggregatedUpToMs, want['aggregatedUpToMs']);
      }

      // 5. the chart query sees the recovered 89 A load of 21 Sep (#116).
      if (perSerial.containsKey('JS-2C14B8')) {
        // 20 Sep 20:00 .. 21 Sep 20:00 AWST, whatever this machine's zone.
        final since = DateTime.utc(2026, 9, 20, 12).millisecondsSinceEpoch;
        final cur = await log.intervals('JS-2C14B8', Metric.packCurrent,
            sinceMs: since);
        final minI = cur
            .where((r) => r.startMs < since + 86400000 && r.valueNum != null)
            .map((r) => r.valueNum!)
            .reduce((a, b) => a < b ? a : b);
        expect(minI, lessThan(-85));
      }
      await log.dispose();
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
