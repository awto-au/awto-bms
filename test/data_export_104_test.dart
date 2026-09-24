/// #104: "Export all data" zip and the staged import that applies it on the
/// next start.
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
  late Directory tmp;
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('export104_');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  var n = 0;
  Directory freshDir() =>
      Directory(p.join(tmp.path, 'case${n++}'))..createSync(recursive: true);

  Future<Database> ffiOpen(String path, OpenDatabaseOptions o) =>
      databaseFactoryFfi.openDatabase(path, options: o);

  /// A real store at [path] holding [rows] readings for [serial] and a
  /// lifetime row, written through the logger's own schema.
  Future<BatteryLogger> seededStore(String path, String serial, int rows,
      {String? text}) async {
    final log = BatteryLogger.custom(path: path, opener: ffiOpen);
    await log.init();
    final db = log.debugDb!;
    for (var i = 0; i < rows; i++) {
      await db.insert('readings', {
        'id': i + 1,
        'serial': serial,
        'metric': i.isEven ? 'soc' : 'firmware',
        'value_num': i.isEven ? 90.0 + i : null,
        'value_text': i.isEven ? null : (text ?? 'JS5.1'),
        'start_time': '2026-09-2${i % 3} 10:00:00.000',
        'end_time': '2026-09-2${i % 3} 10:05:00.000',
        'start_ms': 1000 * i,
        'end_ms': 1000 * i + 300000,
      });
    }
    await db.insert('lifetime_totals', {
      'serial': serial,
      'total_charge_ah': 5.6,
      'total_discharge_ah': 3.4,
      'total_efc': 0.09,
      'aggregated_up_to': '2026-09-23 09:33:53.975',
      'aggregated_up_to_ms': 1790127233975,
    });
    return log;
  }

  Future<Map<String, List<int>>> unzip(File zip) async {
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    return {for (final f in archive.files) f.name: f.content as List<int>};
  }

  Future<File> exportFrom(Directory dir, {int rows = 6, String? text}) async {
    final log = await seededStore(p.join(dir.path, 'src.db'), 'JS-2C14AA', rows,
        text: text);
    final snap = p.join(dir.path, 'snap.db');
    expect(await log.snapshotTo(snap), isTrue);
    await log.dispose();
    final raw = File(p.join(dir.path, 'battery_raw.log'))
      ..writeAsStringSync('frame 1\nframe 2\n');
    SharedPreferences.setMockInitialValues({
      'battery_aliases_v1': '{"JS-2C14AA":"Broke A@"}',
      'background_sample_interval_v1': 300,
      'temp_fahrenheit_v1': false,
      'fleet_serials_v1': <String>['JS-2C14AA', 'JS-2C14B8'],
      'window_bounds_v1': '{"left":1,"top":2,"width":3,"height":4}',
    });
    return buildExportZip(
      workDir: dir,
      dbSnapshot: snap,
      logFiles: [raw.path, p.join(dir.path, 'missing.1.log')],
      prefs: encodePrefs(await SharedPreferences.getInstance()),
      now: DateTime(2026, 9, 24, 14, 5),
    );
  }

  test('export zip holds the DB, CSV, logs, settings and a manifest', () async {
    final dir = freshDir();
    final zip = await exportFrom(dir, text: 'a,"quoted"');
    expect(p.basename(zip.path), 'awto-bms-export-20260924-1405.zip');

    final files = await unzip(zip);
    expect(files.keys.toSet(), {
      kManifestName,
      kIntervalDbName,
      kReadingsCsvName,
      'battery_raw.log',
      kSettingsName,
    }); // the missing rotated log is skipped, not an error

    final manifest = jsonDecode(utf8.decode(files[kManifestName]!)) as Map;
    expect(manifest['format'], kExportFormat);
    expect(manifest['formatVersion'], kExportFormatVersion);
    expect(manifest['app'], 'AWTO BMS');
    final db = manifest['database'] as Map;
    expect(db['readings'], 6);
    expect(db['lifetimeTotals'], 1);
    expect(db['serials'], ['JS-2C14AA']);
    expect(db['userVersion'], BatteryLogger.schemaVersion);
    final listed = (manifest['files'] as List).map((f) => f['name']).toSet();
    expect(listed, files.keys.toSet()..remove(kManifestName));

    final csv = const LineSplitter().convert(utf8.decode(files[kReadingsCsvName]!));
    expect(csv.first, startsWith('serial,metric,value_num,value_text'));
    expect(csv.length, 1 + 6);
    expect(csv[2], contains('"a,""quoted"""')); // RFC 4180 quoting

    final settings = jsonDecode(utf8.decode(files[kSettingsName]!)) as Map;
    expect(settings['background_sample_interval_v1'], {'t': 'int', 'v': 300});
    expect(settings['fleet_serials_v1']['t'], 'stringList');
    expect(settings.containsKey('window_bounds_v1'), isTrue); // for the dev
  });

  test('prefs round-trip keeps types and skips machine-specific keys',
      () async {
    SharedPreferences.setMockInitialValues({
      'b': true,
      'i': 7,
      'd': 1.0,
      's': 'x',
      'l': <String>['a', 'b'],
      'window_bounds_v1': '{}',
    });
    final encoded = encodePrefs(await SharedPreferences.getInstance());
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final keys = await applyPrefs(prefs, encoded);
    expect(keys.toSet(), {'b', 'i', 'd', 's', 'l'});
    expect(prefs.getBool('b'), isTrue);
    expect(prefs.getInt('i'), 7);
    expect(prefs.getDouble('d'), 1.0);
    expect(prefs.getStringList('l'), ['a', 'b']);
    expect(prefs.getString('window_bounds_v1'), isNull);
  });

  test('stage → commit → apply replaces the store, keeps a backup, restores '
      'prefs, and runs once', () async {
    final dir = freshDir();
    final zip = await exportFrom(dir, rows: 6);

    // The receiving device: its own store with different data.
    final target = p.join(dir.path, 'device', kIntervalDbName);
    Directory(p.dirname(target)).createSync();
    final existing = await seededStore(target, 'JS-OTHER', 2);
    await existing.dispose();

    final staging = importStagingDir(Directory(p.join(dir.path, 'support')));
    final summary = await stageImport(zip.path, staging);
    expect(summary.readings, 6);
    expect(summary.serials, ['JS-2C14AA']);
    expect(summary.exportedAt, startsWith('2026-09-24T14:05'));
    await commitImport(staging);

    SharedPreferences.setMockInitialValues({'window_bounds_v1': 'mine'});
    final prefs = await SharedPreferences.getInstance();
    final msg = await applyPendingImport(
        stagingDir: staging,
        dbPath: target,
        prefs: prefs,
        now: DateTime(2026, 9, 25, 8, 0));
    expect(msg, contains('import applied'));

    // The store now opens with the imported rows through the real logger.
    final after = BatteryLogger.custom(path: target, opener: ffiOpen);
    await after.init();
    final rows = await after.debugDb!
        .rawQuery('SELECT DISTINCT serial FROM readings');
    expect(rows.map((r) => r['serial']), ['JS-2C14AA']);
    await after.dispose();

    final backup = File('$target.before-import-20260925-0800');
    expect(backup.existsSync(), isTrue, reason: 'old history kept');
    expect(prefs.getString('battery_aliases_v1'), '{"JS-2C14AA":"Broke A@"}');
    expect(prefs.getString('window_bounds_v1'), 'mine');

    // Nothing pending any more: a second start is a no-op.
    expect(
        await applyPendingImport(
            stagingDir: staging, dbPath: target, prefs: prefs),
        isNull);
  });

  test('a declined import leaves nothing pending', () async {
    final dir = freshDir();
    final zip = await exportFrom(dir);
    final staging = importStagingDir(Directory(p.join(dir.path, 'support')));
    await stageImport(zip.path, staging);
    await cancelImport(staging);
    SharedPreferences.setMockInitialValues({});
    expect(
        await applyPendingImport(
            stagingDir: staging,
            dbPath: p.join(dir.path, 'x.db'),
            prefs: await SharedPreferences.getInstance()),
        isNull);
    expect(File(p.join(dir.path, 'x.db')).existsSync(), isFalse);
  });

  test('stageImport rejects files that are not a usable export', () async {
    final dir = freshDir();
    final staging = importStagingDir(Directory(p.join(dir.path, 'support')));

    final notZip = File(p.join(dir.path, 'notes.zip'))..writeAsStringSync('hi');
    await expectLater(stageImport(notZip.path, staging),
        throwsA(isA<ImportError>()));

    Future<File> zipOf(Map<String, String> entries, String name) async {
      final a = Archive();
      entries.forEach((k, v) => a.addFile(ArchiveFile.string(k, v)));
      final f = File(p.join(dir.path, name));
      await f.writeAsBytes(ZipEncoder().encode(a));
      return f;
    }

    final noManifest = await zipOf({'x.txt': 'x'}, 'a.zip');
    await expectLater(
        stageImport(noManifest.path, staging),
        throwsA(isA<ImportError>().having(
            (e) => e.message, 'message', contains('no manifest'))));

    final otherFormat = await zipOf(
        {kManifestName: '{"format":"something-else","formatVersion":1}'},
        'b.zip');
    await expectLater(
        stageImport(otherFormat.path, staging),
        throwsA(isA<ImportError>()
            .having((e) => e.message, 'message', 'Not an AWTO BMS export')));

    final newer = await zipOf({
      kManifestName: '{"format":"$kExportFormat","formatVersion":99}',
    }, 'c.zip');
    await expectLater(
        stageImport(newer.path, staging),
        throwsA(isA<ImportError>()
            .having((e) => e.message, 'message', contains('newer app'))));
  });

  test('snapshotTo on a closed store reports false', () async {
    final log = BatteryLogger.custom(); // memory-only
    expect(await log.snapshotTo(p.join(tmp.path, 'none.db')), isFalse);
  });
}
