// #74: desktop interval store lives in the app-support dir; legacy
// CWD-relative file is copied in once and never deleted.
import 'dart:io';

import 'package:battery_reader/desktop_data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('awto74_');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('legacy path is <cwd>/.dart_tool/sqflite_common_ffi/databases/', () {
    expect(
        legacyIntervalDbPath('/x/y'),
        p.join('/x/y', '.dart_tool', 'sqflite_common_ffi', 'databases',
            'battery_intervals.db'));
  });

  test('copies the legacy store when the target has none, keeps the original',
      () async {
    final cwd = p.join(tmp.path, 'cwd');
    final legacy = File(legacyIntervalDbPath(cwd));
    await legacy.create(recursive: true);
    await legacy.writeAsString('HISTORY');
    await File('${legacy.path}-wal').writeAsString('WAL');
    final target = p.join(tmp.path, 'support');

    final done = await migrateLegacyIntervalDb(
        legacyPath: legacy.path, targetDir: target);

    expect(done, legacy.path);
    expect(await File(p.join(target, kIntervalDbName)).readAsString(),
        'HISTORY');
    expect(await File(p.join(target, '$kIntervalDbName-wal')).readAsString(),
        'WAL');
    expect(await legacy.exists(), isTrue, reason: 'never deleted');
  });

  test('does nothing when the target already exists (no overwrite)', () async {
    final cwd = p.join(tmp.path, 'cwd');
    final legacy = File(legacyIntervalDbPath(cwd));
    await legacy.create(recursive: true);
    await legacy.writeAsString('OLD');
    final target = p.join(tmp.path, 'support');
    final existing = File(p.join(target, kIntervalDbName));
    await existing.create(recursive: true);
    await existing.writeAsString('CURRENT');

    expect(
        await migrateLegacyIntervalDb(
            legacyPath: legacy.path, targetDir: target),
        isNull);
    expect(await existing.readAsString(), 'CURRENT');
  });

  test('does nothing when there is no legacy file', () async {
    final target = p.join(tmp.path, 'support');
    expect(
        await migrateLegacyIntervalDb(
            legacyPath: legacyIntervalDbPath(p.join(tmp.path, 'nowhere')),
            targetDir: target),
        isNull);
    expect(await File(p.join(target, kIntervalDbName)).exists(), isFalse);
  });
}
