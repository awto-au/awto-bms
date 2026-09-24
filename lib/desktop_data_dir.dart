/// Desktop data location (#74).
///
/// `sqflite_common_ffi` defaults `getDatabasesPath()` to
/// `<current working directory>/.dart_tool/sqflite_common_ffi/databases/`, so
/// a desktop build kept a different interval store for every directory it was
/// launched from (`flutter run` vs the built exe vs a shell elsewhere).
/// `main()` now points the FFI factory at the app-support directory — the
/// same folder the raw log and preferences already use — and, on the first
/// start there, copies the legacy CWD-relative file in. The legacy file is
/// never deleted.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Filename of the interval store (kept in sync with BatteryLogger).
const kIntervalDbName = 'battery_intervals.db';

/// Where the FFI factory used to put the store, relative to [cwd].
String legacyIntervalDbPath(String cwd) =>
    p.join(cwd, '.dart_tool', 'sqflite_common_ffi', 'databases', kIntervalDbName);

/// Copy the legacy store into [targetDir] when the target has none yet.
///
/// Returns the legacy path that was copied, or null when nothing was done
/// (target already present, or no legacy file). Pure file I/O; the caller
/// decides the directories so tests can use temp folders.
Future<String?> migrateLegacyIntervalDb({
  required String legacyPath,
  required String targetDir,
}) async {
  final target = File(p.join(targetDir, kIntervalDbName));
  if (await target.exists()) return null;
  final legacy = File(legacyPath);
  if (!await legacy.exists()) return null;
  await Directory(targetDir).create(recursive: true);
  await legacy.copy(target.path);
  // SQLite side files, if a previous run left them (journal / WAL).
  for (final suffix in const ['-journal', '-wal', '-shm']) {
    final side = File('$legacyPath$suffix');
    if (await side.exists()) await side.copy('${target.path}$suffix');
  }
  return legacyPath;
}
