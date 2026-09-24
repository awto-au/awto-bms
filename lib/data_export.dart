/// Export all app data to one zip, and import it back (#104).
///
/// Export: a consistent snapshot of the interval store, the raw log (and every
/// rotated file, #111), every SharedPreferences value, a `readings.csv` for
/// reading without SQLite, and a `manifest.json` describing it all. Used to send a
/// developer everything in one file, and to carry data to another install
/// (new applicationId, Store build).
///
/// Import is two-step so a live database is never swapped underneath the app:
/// [stageImport] validates and unpacks a zip into a staging folder, [commitImport]
/// marks it pending, and [applyPendingImport] runs at the NEXT start, before the
/// store opens. The data it replaces is kept as a backup file, never deleted.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'battery_log.dart';
import 'desktop_data_dir.dart' show kIntervalDbName;
import 'fmt.dart' show logLine;
import 'raw_log.dart';

const kExportFormat = 'awto-bms-export';
const kExportFormatVersion = 1;
const kManifestName = 'manifest.json';
const kSettingsName = 'settings.json';
const kReadingsCsvName = 'readings.csv';

/// Prefs that describe this machine rather than the user's data; exported for
/// the developer but not applied on import (a phone's window bounds mean
/// nothing on a PC).
const kImportSkipPrefs = {'window_bounds_v1'};

const _source = 'DataExport';

// --- preferences -------------------------------------------------------------

/// Every preference as `{key: {"t": type, "v": value}}`. The type tag keeps an
/// int apart from a double and a string list apart from a JSON string.
Map<String, Object?> encodePrefs(SharedPreferences prefs) {
  final out = <String, Object?>{};
  for (final key in prefs.getKeys().toList()..sort()) {
    final v = prefs.get(key);
    final String t;
    if (v is bool) {
      t = 'bool';
    } else if (v is int) {
      t = 'int';
    } else if (v is double) {
      t = 'double';
    } else if (v is String) {
      t = 'string';
    } else if (v is List) {
      t = 'stringList';
    } else {
      continue;
    }
    out[key] = {'t': t, 'v': v};
  }
  return out;
}

/// Write [encoded] (from [encodePrefs]) into [prefs], skipping [skip] and any
/// entry whose tag or value is not understood. Returns the keys written.
Future<List<String>> applyPrefs(
    SharedPreferences prefs, Map<String, Object?> encoded,
    {Set<String> skip = kImportSkipPrefs}) async {
  final written = <String>[];
  for (final e in encoded.entries) {
    if (skip.contains(e.key)) continue;
    final entry = e.value;
    if (entry is! Map) continue;
    final v = entry['v'];
    final ok = switch (entry['t']) {
      'bool' when v is bool => await prefs.setBool(e.key, v),
      'int' when v is int => await prefs.setInt(e.key, v),
      'double' when v is num => await prefs.setDouble(e.key, v.toDouble()),
      'string' when v is String => await prefs.setString(e.key, v),
      'stringList' when v is List =>
        await prefs.setStringList(e.key, v.map((x) => '$x').toList()),
      _ => false,
    };
    if (ok) written.add(e.key);
  }
  return written;
}

// --- export ------------------------------------------------------------------

/// `awto-bms-export-20260924-1405.zip`
String exportFileName(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'awto-bms-export-${t.year}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}.zip';
}

/// Build the export zip in [workDir] from already-prepared inputs. Pure file
/// work so tests can drive it: [dbSnapshot] is a closed copy of the store
/// (see [BatteryLogger.snapshotTo]), [logFiles] are added when they exist.
Future<File> buildExportZip({
  required Directory workDir,
  required String? dbSnapshot,
  required List<String> logFiles,
  required Map<String, Object?> prefs,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final stage = await workDir.createTemp('export_');
  try {
    final files = <String, File>{};

    Map<String, Object?> dbInfo = {'included': false};
    if (dbSnapshot != null && await File(dbSnapshot).exists()) {
      final db = File(p.join(stage.path, kIntervalDbName));
      await File(dbSnapshot).copy(db.path);
      files[kIntervalDbName] = db;
      final csv = File(p.join(stage.path, kReadingsCsvName));
      dbInfo = await _describeAndCsv(db.path, csv);
      files[kReadingsCsvName] = csv;
    }

    for (final path in logFiles) {
      final f = File(path);
      if (await f.exists()) files[p.basename(path)] = f;
    }

    final settings = File(p.join(stage.path, kSettingsName));
    await settings.writeAsString(
        const JsonEncoder.withIndent('  ').convert(prefs));
    files[kSettingsName] = settings;

    final listing = <Map<String, Object?>>[];
    for (final e in files.entries) {
      listing.add({
        'name': e.key,
        'bytes': await e.value.length(),
        'sha256': (await sha256.bind(e.value.openRead()).first).toString(),
      });
    }
    final manifest = {
      'format': kExportFormat,
      'formatVersion': kExportFormatVersion,
      'app': 'AWTO BMS',
      'exportedAt': at.toIso8601String(),
      'exportedAtUtcMs': at.toUtc().millisecondsSinceEpoch,
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'schemaVersion': BatteryLogger.schemaVersion,
      'database': dbInfo,
      'files': listing,
    };
    final manifestFile = File(p.join(stage.path, kManifestName));
    await manifestFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

    final zip = File(p.join(workDir.path, exportFileName(at)));
    if (await zip.exists()) await zip.delete();
    final enc = ZipFileEncoder()..create(zip.path);
    await enc.addFile(manifestFile, kManifestName);
    for (final e in files.entries) {
      await enc.addFile(e.value, e.key);
    }
    await enc.close();
    return zip;
  } finally {
    await stage.delete(recursive: true);
  }
}

/// Row counts, serials and user_version of the snapshot, and its readings as
/// CSV (paged so a large store never sits in memory at once).
Future<Map<String, Object?>> _describeAndCsv(String dbPath, File csv) async {
  final db = await databaseFactory.openDatabase(dbPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
  try {
    Future<int> count(String table) async {
      try {
        final r = await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
        return (r.first['n'] as num?)?.toInt() ?? 0;
      } catch (_) {
        return 0; // table absent in an older schema
      }
    }

    final version =
        (await db.rawQuery('PRAGMA user_version')).first.values.first;
    final serials = (await db
            .rawQuery('SELECT DISTINCT serial FROM readings ORDER BY serial'))
        .map((r) => r['serial'])
        .toList();

    const cols = [
      'serial', 'metric', 'value_num', 'value_text', //
      'start_time', 'end_time', 'start_ms', 'end_ms',
    ];
    final sink = csv.openWrite();
    sink.writeln(cols.join(','));
    const page = 5000;
    var lastId = -1;
    while (true) {
      final rows = await db.rawQuery(
          'SELECT id, ${cols.join(', ')} FROM readings '
          'WHERE id > ? ORDER BY id LIMIT $page',
          [lastId]);
      if (rows.isEmpty) break;
      for (final r in rows) {
        sink.writeln(cols.map((c) => csvField(r[c])).join(','));
      }
      lastId = (rows.last['id'] as num).toInt();
    }
    await sink.close();

    return {
      'included': true,
      'userVersion': version,
      'readings': await count('readings'),
      'lifetimeTotals': await count('lifetime_totals'),
      'alarmEvents': await count('alarm_events'),
      'serials': serials,
    };
  } finally {
    await db.close();
  }
}

/// RFC 4180 field: quoted only when it holds a comma, quote or newline.
String csvField(Object? v) {
  if (v == null) return '';
  final s = '$v';
  if (s.contains(RegExp(r'[",\r\n]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}

/// Export everything the running app holds, into [workDir] (a temp folder).
Future<File> exportAllData(Directory workDir) async {
  final raw = RawLogger.instance;
  await raw.flush();
  final snap = p.join(workDir.path, 'snapshot_$kIntervalDbName');
  final ok = await BatteryLogger.instance.snapshotTo(snap);
  try {
    return await buildExportZip(
      workDir: workDir,
      dbSnapshot: ok ? snap : null,
      // #111: the live raw log and EVERY rotated one.
      logFiles: await raw.allLogPaths(),
      prefs: encodePrefs(await SharedPreferences.getInstance()),
    );
  } finally {
    final f = File(snap);
    if (await f.exists()) await f.delete();
  }
}

// --- import ------------------------------------------------------------------

/// What a staged export holds, for the confirmation dialog.
class ImportSummary {
  final String exportedAt;
  final String platform;
  final int readings;
  final List<String> serials;
  const ImportSummary({
    required this.exportedAt,
    required this.platform,
    required this.readings,
    required this.serials,
  });
}

/// Thrown by [stageImport] for a file that is not a usable export.
class ImportError implements Exception {
  final String message;
  const ImportError(this.message);
  @override
  String toString() => message;
}

const _incoming = 'incoming';
const _pending = 'pending';

/// Unpack [zipPath] into `<stagingDir>/incoming` and check it: our manifest
/// format, a known format version, settings present, and a database that
/// opens with a `readings` table and a schema no newer than this build.
Future<ImportSummary> stageImport(String zipPath, Directory stagingDir) async {
  final dir = Directory(p.join(stagingDir.path, _incoming));
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  try {
    await extractFileToDisk(zipPath, dir.path);
  } catch (e) {
    throw ImportError('Not a readable zip file ($e)');
  }

  final manifestFile = File(p.join(dir.path, kManifestName));
  if (!await manifestFile.exists()) {
    throw const ImportError('Not an AWTO BMS export (no manifest.json)');
  }
  final Map<String, Object?> manifest;
  try {
    manifest = (jsonDecode(await manifestFile.readAsString()) as Map)
        .cast<String, Object?>();
  } catch (_) {
    throw const ImportError('The export manifest is damaged');
  }
  if (manifest['format'] != kExportFormat) {
    throw const ImportError('Not an AWTO BMS export');
  }
  final fv = manifest['formatVersion'];
  if (fv is! int || fv > kExportFormatVersion) {
    throw const ImportError(
        'This export was made by a newer app version; update the app first');
  }
  if (!await File(p.join(dir.path, kSettingsName)).exists()) {
    throw const ImportError('The export has no settings.json');
  }

  final dbFile = File(p.join(dir.path, kIntervalDbName));
  if (!await dbFile.exists()) {
    throw const ImportError('The export has no history database');
  }
  int readings;
  List<String> serials;
  try {
    final db = await databaseFactory.openDatabase(dbFile.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      final v = (await db.rawQuery('PRAGMA user_version')).first.values.first;
      if (v is int && v > BatteryLogger.schemaVersion) {
        throw const ImportError(
            'The history was written by a newer app version; update the app first');
      }
      readings = ((await db.rawQuery('SELECT COUNT(*) AS n FROM readings'))
              .first['n'] as num)
          .toInt();
      serials = (await db.rawQuery(
              'SELECT DISTINCT serial FROM readings ORDER BY serial'))
          .map((r) => '${r['serial']}')
          .toList();
    } finally {
      await db.close();
    }
  } on ImportError {
    rethrow;
  } catch (e) {
    throw ImportError('The history database cannot be read ($e)');
  }

  return ImportSummary(
    exportedAt: '${manifest['exportedAt'] ?? '?'}',
    platform: '${manifest['platform'] ?? '?'}',
    readings: readings,
    serials: serials,
  );
}

/// Confirm the staged import: it is applied on the next start.
Future<void> commitImport(Directory stagingDir) async {
  final incoming = Directory(p.join(stagingDir.path, _incoming));
  final pending = Directory(p.join(stagingDir.path, _pending));
  if (await pending.exists()) await pending.delete(recursive: true);
  await incoming.rename(pending.path);
}

/// Throw away a staged import the user declined.
Future<void> cancelImport(Directory stagingDir) async {
  final incoming = Directory(p.join(stagingDir.path, _incoming));
  if (await incoming.exists()) await incoming.delete(recursive: true);
}

/// Where imports are staged: `<app support>/pending_import`.
Directory importStagingDir(Directory appSupport) =>
    Directory(p.join(appSupport.path, 'pending_import'));

/// Apply a committed import. Call at startup BEFORE the interval store opens
/// and before anything reads preferences. The current store (and its SQLite
/// side files) is renamed to `<db>.before-import-<stamp>`, the imported one
/// takes its place, and the imported preferences are written over the current
/// ones. Returns a log message when something was applied, else null.
Future<String?> applyPendingImport({
  required Directory stagingDir,
  required String dbPath,
  required SharedPreferences prefs,
  DateTime? now,
}) async {
  final pending = Directory(p.join(stagingDir.path, _pending));
  if (!await pending.exists()) return null;
  final newDb = File(p.join(pending.path, kIntervalDbName));
  final settings = File(p.join(pending.path, kSettingsName));
  if (!await newDb.exists() || !await settings.exists()) {
    await pending.delete(recursive: true);
    return 'discarded an incomplete pending import';
  }

  final at = now ?? DateTime.now();
  final stamp = exportFileName(at)
      .replaceFirst('awto-bms-export-', '')
      .replaceFirst('.zip', '');
  final backup = '$dbPath.before-import-$stamp';
  await Directory(p.dirname(dbPath)).create(recursive: true);
  // Copy next to the target first: if that fails, the current store is
  // still untouched. Renames within one folder are the only steps after it.
  final incoming = await newDb.copy('$dbPath.importing');
  if (await File(dbPath).exists()) await File(dbPath).rename(backup);
  for (final side in const ['-journal', '-wal', '-shm']) {
    final f = File('$dbPath$side');
    if (await f.exists()) await f.rename('$backup$side');
  }
  await incoming.rename(dbPath);

  final encoded =
      (jsonDecode(await settings.readAsString()) as Map).cast<String, Object?>();
  final keys = await applyPrefs(prefs, encoded);

  await pending.delete(recursive: true);
  final msg = 'import applied: database replaced (previous kept as '
      '${p.basename(backup)}), ${keys.length} settings restored';
  logLine(_source, msg);
  return msg;
}
