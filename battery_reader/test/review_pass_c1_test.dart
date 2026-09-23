import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/metrics.dart' show chartMetrics;
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/diagnostics_page.dart' show diagnosticsSummary;
import 'package:battery_reader/fleet_store.dart';
import 'package:battery_reader/prefs_store.dart';
import 'package:battery_reader/raw_log.dart';
import 'package:battery_reader/settings_store.dart';

import 'fakes.dart';

/// Review-fix Pass C1 (GitHub #51): the data/infra refactors.
///
///  * H2  — schema v3: epoch-ms columns backfilled from the text columns, and
///          EVERY ordering / window / watermark decision made on ms (proved
///          with a DST-style case whose text sorts wrong lexicographically).
///  * DIAG — [AppLog] ring buffer + [guard]/[guardSync]; swallow sites record.
///  * PREFS — [PrefsStore] base; keys unchanged; failures recorded.
///  * M7/L18 — DB write failures counted, degraded after 5, open retried.
///  * M9  — raw-log size cap with a single rotation.
///  * M11 — attach() handle cancelled on dispose; no subscription growth.
///  * M12 — a serial re-advertising under a new device id rebinds its row.
///  * M13 — scan failures surface as [BatteryManager.scanErrorText].
///  * M14 — every cell present is logged; charts take N cells.
void main() {
  sqfliteFfiInit();
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('c1_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  var n = 0;
  String freshPath() => '${tmp.path}${Platform.pathSeparator}db${n++}.db';

  Future<Database> ffiOpen(String path, OpenDatabaseOptions o) =>
      databaseFactoryFfi.openDatabase(path, options: o);

  BatteryLogger openLogger(String path,
          {Duration backoff = BatteryLogger.defaultReopenBackoff}) =>
      BatteryLogger.custom(path: path, opener: ffiOpen, reopenBackoff: backoff);

  /// A pack row: [ms] is the TRUE epoch instant; [text] is the local-time text
  /// as an older build wrote it (or as the live writer still writes it).
  Map<String, Object?> row(int id, String serial, String metric, double v,
          {required String startText,
          required String endText,
          int? startMs,
          int? endMs}) =>
      {
        'id': id,
        'serial': serial,
        'metric': metric,
        'value_num': v,
        'start_time': startText,
        'end_time': endText,
        if (startMs != null) 'start_ms': startMs,
        if (endMs != null) 'end_ms': endMs,
      };

  // -------------------------------------------------------------------------
  group('H2: schema v3 migration backfills the ms columns from the text', () {
    test('a v2 database gets start_ms/end_ms/aggregated_up_to_ms = parse(text)',
        () async {
      final path = freshPath();
      // Build a v2 store exactly as the previous build did (text-only).
      final v2 = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE readings ('
                  ' id INTEGER PRIMARY KEY, serial TEXT NOT NULL,'
                  ' metric TEXT NOT NULL, value_num REAL, value_text TEXT,'
                  ' start_time TEXT NOT NULL, end_time TEXT NOT NULL)');
              await db.execute('CREATE INDEX ix_readings ON readings '
                  '(serial, metric, start_time)');
              await db.execute('CREATE TABLE lifetime_totals ('
                  ' serial TEXT PRIMARY KEY,'
                  ' total_charge_ah REAL NOT NULL DEFAULT 0,'
                  ' total_discharge_ah REAL NOT NULL DEFAULT 0,'
                  ' total_efc REAL NOT NULL DEFAULT 0,'
                  ' aggregated_up_to TEXT)');
            },
          ));
      const texts = [
        ('2026-04-05 02:30:00.000', '2026-04-05 02:40:00.000'),
        ('2026-04-05 02:45:00.000', '2026-04-05 02:59:59.999'),
        ('2026-04-05 03:05:00.000', '2026-04-05 03:20:00.000'),
      ];
      for (var i = 0; i < texts.length; i++) {
        await v2.insert(
            'readings',
            row(i + 1, 'JS-A', Metric.packCurrent, 5,
                startText: texts[i].$1, endText: texts[i].$2));
      }
      await v2.insert('lifetime_totals', {
        'serial': 'JS-A',
        'total_charge_ah': 1.5,
        'aggregated_up_to': '2026-04-05 03:20:00.000',
      });
      await v2.close();

      // Open through the logger: onUpgrade v2 -> v3 runs the backfill once.
      final log = openLogger(path);
      await log.init();
      expect(log.enabled, isTrue);
      final db = log.debugDb!;
      expect(await db.getVersion(), BatteryLogger.schemaVersion);
      final rows = await db.query('readings', orderBy: 'id');
      expect(rows.length, 3);
      for (var i = 0; i < rows.length; i++) {
        expect(rows[i]['start_time'], texts[i].$1, reason: 'text untouched');
        expect(rows[i]['end_time'], texts[i].$2, reason: 'text untouched');
        expect(rows[i]['start_ms'], BatteryLogger.parseTime(texts[i].$1));
        expect(rows[i]['end_ms'], BatteryLogger.parseTime(texts[i].$2));
      }
      final lt = await db.query('lifetime_totals');
      expect(lt.single['aggregated_up_to'], '2026-04-05 03:20:00.000');
      expect(lt.single['aggregated_up_to_ms'],
          BatteryLogger.parseTime('2026-04-05 03:20:00.000'));
      expect((await log.lifetimeTotals('JS-A')).aggregatedUpToMs,
          BatteryLogger.parseTime('2026-04-05 03:20:00.000'));
      // The ms index exists.
      final idx = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='ix_readings_ms'");
      expect(idx, isNotEmpty);
      // The migration is idempotent (re-running on a v3 DB is a no-op).
      await BatteryLogger.migrateToV3(db);
      expect((await db.query('readings')).length, 3);
      await log.dispose();
    });

    test('a fresh database is created at v3 with both column families',
        () async {
      final log = openLogger(freshPath());
      await log.init();
      final cols = await log.debugDb!.rawQuery('PRAGMA table_info(readings)');
      final names = cols.map((c) => c['name']).toSet();
      expect(names, containsAll(['start_time', 'end_time', 'start_ms', 'end_ms']));
      final lt = await log.debugDb!.rawQuery('PRAGMA table_info(lifetime_totals)');
      expect(lt.map((c) => c['name']),
          containsAll(['aggregated_up_to', 'aggregated_up_to_ms']));
      await log.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('H2: ordering, windows and watermarks use ms, never the text', () {
    // A DST fall-back night: the clock runs 02:00 -> 03:00 TWICE. Real order
    // of events is A, B, C, D; the LOCAL-TIME TEXT of C (second pass through
    // 02:xx) sorts BEFORE A and B lexicographically.
    const base = 1775000000000; // an arbitrary epoch-ms instant
    const min = 60 * 1000;
    const a = (text: '2026-04-05 02:30:00.000', ms: base);
    const b = (text: '2026-04-05 02:45:00.000', ms: base + 15 * min);
    const c = (text: '2026-04-05 02:10:00.000', ms: base + 40 * min);
    const d = (text: '2026-04-05 03:05:00.000', ms: base + 95 * min);

    test('the text order really is wrong (sanity)', () {
      final byText = [a, b, c, d]..sort((x, y) => x.text.compareTo(y.text));
      expect(byText.map((r) => r.ms), [c.ms, a.ms, b.ms, d.ms]);
    });

    test('intervals() come back in ms order across the repeated hour',
        () async {
      final log = openLogger(freshPath());
      await log.init();
      final db = log.debugDb!;
      var id = 100;
      for (final r in [a, b, c, d]) {
        await db.insert(
            'readings',
            row(id++, 'JS-A', Metric.soc, 50,
                startText: r.text,
                endText: r.text,
                startMs: r.ms,
                endMs: r.ms + 5 * min));
      }
      final ivs = await log.intervals('JS-A', Metric.soc);
      expect(ivs.map((iv) => iv.startMs), [a.ms, b.ms, c.ms, d.ms]);
      // Window filter on ms: a window opening after B's end still returns C
      // (whose TEXT would have failed a text `>=` compare against B's text).
      final late = await log.intervals('JS-A', Metric.soc,
          sinceMs: b.ms + 6 * min);
      expect(late.map((iv) => iv.startMs), [c.ms, d.ms]);
      await log.dispose();
    });

    test('lifetime watermark compares ms: the repeated-hour row is not lost',
        () async {
      final log = openLogger(freshPath());
      await log.init();
      final db = log.debugDb!;
      // +10 A held for 5 min each.
      Future<void> put(int id, ({String text, int ms}) r) => db.insert(
          'readings',
          row(id, 'JS-A', Metric.packCurrent, 10,
              startText: r.text,
              endText: r.text,
              startMs: r.ms,
              endMs: r.ms + 5 * min));
      await put(1, a);
      await put(2, b);
      final first = await log.updateLifetimeTotals('JS-A');
      expect(first.aggregatedUpToMs, b.ms + 5 * min);
      // Now C arrives: its TEXT (02:10) is lexicographically BEFORE the
      // watermark text (02:45) — a text compare would exclude it forever.
      await put(3, c);
      final second = await log.updateLifetimeTotals('JS-A');
      expect(second.aggregatedUpToMs, c.ms + 5 * min);
      expect(second.chargeAh, greaterThan(first.chargeAh));
      // The persisted watermark carries both forms.
      final lt = (await db.query('lifetime_totals')).single;
      expect(lt['aggregated_up_to_ms'], c.ms + 5 * min);
      expect(lt['aggregated_up_to'], BatteryLogger.fmtTime(c.ms + 5 * min));
      await log.dispose();
    });

    test('the writer stores BOTH forms and reads back by ms', () async {
      final log = openLogger(freshPath());
      await log.init();
      final conn = BatteryConnection(transport: NoopTransport());
      conn.state
        ..serial = 'JS-W'
        ..socPercent = 42;
      log.observeConnection(conn, nowMs: a.ms);
      log.observeConnection(conn, nowMs: a.ms + 5000); // extend
      log.flushAll();
      await log.drain();
      final r = (await log.debugDb!
              .query('readings', where: 'metric = ?', whereArgs: [Metric.soc]))
          .single;
      expect(r['start_ms'], a.ms);
      expect(r['end_ms'], a.ms + 5000);
      expect(r['start_time'], BatteryLogger.fmtTime(a.ms));
      expect(r['end_time'], BatteryLogger.fmtTime(a.ms + 5000));
      final ivs = await log.intervals('JS-W', Metric.soc);
      expect(ivs.single.startMs, a.ms);
      expect(ivs.single.endMs, a.ms + 5000);
      await log.dispose();
      await conn.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('Diagnostics: AppLog ring buffer + guard', () {
    setUp(() {
      AppLog.instance.clear();
      AppLog.instance.echoToConsole = false;
    });
    tearDown(() => AppLog.instance.echoToConsole = true);

    test('guard swallows, records "what: error" and returns the fallback',
        () async {
      final v = await guard<int>('boom op', () async => throw StateError('x'),
          fallback: 7, source: 'T');
      expect(v, 7);
      final e = AppLog.instance.entries.last;
      expect(e.source, 'T');
      expect(e.message, 'boom op: Bad state: x');
    });

    test('guard passes a success straight through without recording',
        () async {
      expect(await guard<int>('ok', () async => 3), 3);
      expect(AppLog.instance.isEmpty, isTrue);
    });

    test('guard applies the timeout and records it', () async {
      final v = await guard<int>('slow', () => Completer<int>().future,
          timeout: const Duration(milliseconds: 20), fallback: -1);
      expect(v, -1);
      expect(AppLog.instance.entries.single.message, contains('slow: '));
      expect(AppLog.instance.entries.single.message, contains('TimeoutException'));
    });

    test('guardSync mirrors guard', () {
      expect(guardSync<int>('sync boom', () => throw 'bad', fallback: 1), 1);
      expect(AppLog.instance.entries.single.message, 'sync boom: bad');
      expect(guardSync<int>('fine', () => 2), 2);
    });

    test('the ring keeps only the last 500 entries, newest first via recent()',
        () {
      for (var i = 0; i < 600; i++) {
        AppLog.instance.record('S', 'm$i');
      }
      expect(AppLog.instance.length, AppLog.capacity);
      expect(AppLog.instance.totalRecorded, 600);
      expect(AppLog.instance.entries.first.message, 'm100');
      expect(AppLog.instance.recent(2).map((e) => e.message), ['m599', 'm598']);
      expect(AppLog.instance.dump().split('\n').length, AppLog.capacity);
    });

    test('the sink receives every entry and a throwing sink is contained', () {
      final seen = <String>[];
      AppLog.instance.sink = (e) {
        seen.add(e.message);
        throw 'sink broke';
      };
      AppLog.instance.record('S', 'hello');
      AppLog.instance.sink = null;
      expect(seen, ['hello']);
      expect(AppLog.instance.length, 1);
    });

    test('diagnosticsSummary wording', () {
      expect(
          diagnosticsSummary(
              dbDegraded: true,
              lastDbError: 'disk full',
              entryCount: 3,
              totalRecorded: 3),
          'Logging is failing: disk full');
      expect(
          diagnosticsSummary(
              dbDegraded: false, entryCount: 0, totalRecorded: 0),
          'No problems recorded');
      expect(
          diagnosticsSummary(
              dbDegraded: false, entryCount: 500, totalRecorded: 620),
          '500 recent entries (120 older dropped)');
    });
  });

  // -------------------------------------------------------------------------
  group('PrefsStore base: thin subclasses, unchanged keys, recorded failures',
      () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppLog.instance.clear();
      AppLog.instance.echoToConsole = false;
    });
    tearDown(() => AppLog.instance.echoToConsole = true);

    test('SettingsStore is a table of BoolSetting with the ORIGINAL keys', () {
      expect(SettingsStore.demoMode.key, 'demo_mode_v1');
      expect(SettingsStore.verbose.key, 'verbose_logging_v1');
      expect(SettingsStore.useFahrenheit.key, 'temp_fahrenheit_v1');
      expect(SettingsStore.alertNotifications.key, 'alert_notifications_v1');
      // #52 added background monitoring (default ON); the original keys and
      // defaults above are unchanged.
      expect(SettingsStore.backgroundMonitoring.key,
          'background_monitoring_v1');
      expect(SettingsStore.all.map((s) => s.defaultValue),
          [false, true, false, true, true, false]);
    });

    test('data persisted under the old keys still loads', () async {
      SharedPreferences.setMockInitialValues({
        'demo_mode_v1': true,
        'verbose_logging_v1': false,
        'temp_fahrenheit_v1': true,
        'battery_aliases_v1': '{"JS-A":"Left"}',
        'fleet_records_v1': ['{"serial":"JS-A","profile":"JS","soc":55}'],
      });
      final s = SettingsStore();
      expect(await s.loadDemoMode(), isTrue);
      expect(await s.loadVerbose(), isFalse);
      expect(await s.loadUseFahrenheit(), isTrue);
      expect(await s.loadAlertNotifications(), isTrue, reason: 'default');
      final a = AliasStore();
      await a.load();
      expect(a.aliasFor('JS-A'), 'Left');
      final f = await SharedPrefsFleetStore().load();
      expect(f['JS-A']?.soc, 55);
    });

    test('round trip through the base writes the same keys', () async {
      final s = SettingsStore();
      await s.saveDemoMode(true);
      await s.save(SettingsStore.verbose, false);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('demo_mode_v1'), isTrue);
      expect(p.getBool('verbose_logging_v1'), isFalse);
      expect(await s.load(SettingsStore.verbose), isFalse);
    });

    test('an unavailable plugin falls back to defaults AND records', () async {
      Future<SharedPreferences> broken() async =>
          throw StateError('MissingPluginException');
      final s = SettingsStore(prefs: broken);
      expect(await s.loadDemoMode(), isFalse);
      expect(await s.loadVerbose(), isTrue);
      await s.saveDemoMode(true); // must not throw
      final a = AliasStore(prefs: broken);
      await a.load();
      expect(a.aliasFor('JS-A'), isNull);
      final f = SharedPrefsFleetStore(prefs: broken);
      expect(await f.load(), isEmpty);
      await f.save({});
      final sources = AppLog.instance.entries.map((e) => e.source).toSet();
      expect(sources, containsAll(['SettingsStore', 'AliasStore', 'FleetStore']));
      expect(AppLog.instance.entries.every((e) => e.message.contains('Missing')),
          isTrue);
    });

    test('a corrupt fleet row is skipped and recorded, the rest load',
        () async {
      SharedPreferences.setMockInitialValues({
        'fleet_records_v1': ['not json', '{"serial":"JS-B"}'],
      });
      final f = await SharedPrefsFleetStore().load();
      expect(f.keys, ['JS-B']);
      expect(AppLog.instance.entries.single.message,
          startsWith('decode fleet record: '));
    });

    test('readJson tolerates a corrupt payload', () async {
      SharedPreferences.setMockInitialValues({'k': '{oops'});
      final p = PrefsStore('T');
      expect(await p.readJson('k'), isNull);
      expect(AppLog.instance.entries.single.message, startsWith('decode k: '));
      await p.writeJson('k', {'a': 1});
      expect(await p.readJson('k'), {'a': 1});
    });
  });

  // -------------------------------------------------------------------------
  group('M7 / L18: DB failures are counted, degrade after 5 and retry', () {
    setUp(() {
      AppLog.instance.clear();
      AppLog.instance.echoToConsole = false;
    });
    tearDown(() => AppLog.instance.echoToConsole = true);

    test('a failed open is recorded and retried after the backoff, not fatal',
        () async {
      var calls = 0;
      final log = BatteryLogger.custom(
        path: freshPath(),
        reopenBackoff: Duration.zero,
        opener: (path, o) {
          if (calls++ == 0) throw StateError('disk not ready');
          return ffiOpen(path, o);
        },
      );
      await log.init();
      expect(log.enabled, isFalse);
      expect(log.lastDbError, contains('disk not ready'));
      expect(log.consecutiveFailures, 1);
      expect(log.dbDegraded, isFalse, reason: 'one transient failure');
      expect(AppLog.instance.entries.single.message,
          'open database: Bad state: disk not ready');
      // L18: a second init (the retry) succeeds — it is not permanently off.
      await log.init();
      expect(log.enabled, isTrue);
      expect(log.lastDbError, isNull);
      expect(log.consecutiveFailures, 0);
      await log.dispose();
    });

    test('5 consecutive write failures flip dbDegraded; a re-open recovers',
        () async {
      final log = openLogger(freshPath(), backoff: Duration.zero);
      await log.init();
      final conn = BatteryConnection(transport: NoopTransport());
      conn.state.serial = 'JS-D';
      conn.state.socPercent = 1;
      log.observeConnection(conn, nowMs: 1000);
      await log.drain();
      expect(log.consecutiveFailures, 0);

      // Break the store underneath the logger (as a closed/corrupt file would).
      await log.debugDb!.close();
      for (var i = 2; i <= 6; i++) {
        conn.state.socPercent = i; // a value change = one insert each
        log.observeConnection(conn, nowMs: 1000 + i * 1000);
      }
      await log.drain();
      expect(log.consecutiveFailures, greaterThanOrEqualTo(5));
      expect(log.dbDegraded, isTrue);
      expect(log.lastDbError, isNotNull);
      expect(log.enabled, isFalse, reason: 'handle dropped for retry');
      expect(
          AppLog.instance.entries
              .where((e) => e.message.startsWith('insert soc: '))
              .length,
          greaterThanOrEqualTo(5));
      expect(AppLog.instance.entries.any((e) => e.message.contains('degraded')),
          isTrue);
      // The in-memory hour kept working throughout.
      expect(log.hourSegments('JS-D', Metric.soc), isNotEmpty);

      // Backoff is zero: the next observation triggers the re-open.
      conn.state.socPercent = 50;
      log.observeConnection(conn, nowMs: 20000);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(log.enabled, isTrue);
      expect(log.dbDegraded, isFalse);
      expect(log.lastDbError, isNull);
      expect(AppLog.instance.entries.last.message, 'logging recovered');
      // And writes land again.
      conn.state.socPercent = 51;
      log.observeConnection(conn, nowMs: 21000);
      await log.drain();
      expect(log.consecutiveFailures, 0);
      final rows = await log.debugDb!
          .query('readings', where: 'value_num = 51');
      expect(rows.length, 1);
      await log.dispose();
      await conn.dispose();
    });

    test('the backoff really gates the retry when non-zero', () async {
      var calls = 0;
      final log = BatteryLogger.custom(
        path: freshPath(),
        reopenBackoff: const Duration(minutes: 10),
        opener: (path, o) {
          calls++;
          throw StateError('never');
        },
      );
      await log.init();
      expect(calls, 1);
      expect(log.nextOpenAttemptMs,
          greaterThan(DateTime.now().millisecondsSinceEpoch + 9 * 60 * 1000));
      final conn = BatteryConnection(transport: NoopTransport());
      conn.state.serial = 'JS-B';
      conn.state.socPercent = 1;
      log.observeConnection(conn, nowMs: 1); // would retry if due
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1, reason: 'not due yet');
      await log.dispose();
      await conn.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('M9: raw log rotates once past the size cap', () {
    test('exceeding maxBytes moves the file to battery_raw.1.log', () async {
      final dir = Directory('${tmp.path}${Platform.pathSeparator}raw${n++}');
      // One 20-byte raw line is 125 bytes incl. newline: 3 lines fit, 4 do not.
      final raw = RawLogger.forTest(dir: dir, maxBytes: 400);
      await raw.init();
      expect(raw.path, endsWith(RawLogger.fileName));
      expect(raw.sizeBytes, 0);
      for (var i = 0; i < 3; i++) {
        raw.logRaw('JS-A', List.filled(20, 0xAA)); // ~100 bytes per line
      }
      await raw.flush();
      expect(raw.sizeBytes, greaterThan(250));
      expect(raw.rotations, 0);
      // One more chunk pushes it over: rotate.
      raw.logRaw('JS-A', List.filled(20, 0xBB));
      await raw.flush();
      expect(raw.rotations, 1);
      expect(raw.sizeBytes, 0);
      final rotated = File(raw.rotatedPath!);
      expect(await rotated.exists(), isTrue);
      final firstRotation = await rotated.readAsString();
      expect(firstRotation, contains('bb bb'));
      expect(await File(raw.path!).exists(), isFalse, reason: 'fresh start');

      // A second rotation OVERWRITES the previous one (single rotation).
      for (var i = 0; i < 4; i++) {
        raw.logRaw('JS-A', List.filled(20, 0xCC));
      }
      await raw.flush();
      expect(raw.rotations, 2);
      final second = await rotated.readAsString();
      expect(second, contains('cc cc'));
      expect(second, isNot(contains('bb bb')));
      // Writes continue into a new live file.
      raw.logRaw('JS-A', [1]);
      await raw.flush();
      expect(await File(raw.path!).exists(), isTrue);
      expect(raw.sizeBytes, greaterThan(0));
      await raw.dispose();
    });

    test('fmtSize', () {
      expect(RawLogger.fmtSize(512), '512 B');
      expect(RawLogger.fmtSize(20 * 1024), '20 KB');
      expect(RawLogger.fmtSize(52428800), '50.0 MB');
    });
  });

  // -------------------------------------------------------------------------
  group('M11: attach() returns a handle cancelled on dispose', () {
    test('re-attaching replaces; dispose cancels; the set never grows',
        () async {
      final log = BatteryLogger.custom();
      final c = BatteryConnection(transport: NoopTransport());
      final h1 = log.attach(c);
      expect(log.attachmentCount, 1);
      expect(c.loggerAttachment, same(h1));
      final h2 = log.attach(c);
      await Future<void>.delayed(Duration.zero);
      expect(h1.isCancelled, isTrue);
      expect(log.attachmentCount, 1);
      expect(c.loggerAttachment, same(h2));
      await c.dispose();
      expect(h2.isCancelled, isTrue);
      expect(c.loggerAttachment, isNull);
      expect(log.attachmentCount, 0);
    });

    test('demo/live toggles do not accumulate subscriptions', () async {
      final m = BatteryManager();
      final before = BatteryLogger.instance.attachmentCount;
      m.startDemoFleet();
      expect(BatteryLogger.instance.attachmentCount, before + 4);
      m.startDemoFleet(); // disposes the old four, attaches four new
      await Future<void>.delayed(Duration.zero);
      expect(BatteryLogger.instance.attachmentCount, before + 4);
      m.disposeAll();
      await Future<void>.delayed(Duration.zero);
      expect(BatteryLogger.instance.attachmentCount, before);
    });
  });

  // -------------------------------------------------------------------------
  group('M12: a serial re-advertising under a new device id rebinds', () {
    test('disconnected row is remapped, no duplicate row', () {
      final m = BatteryManager();
      final first = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'id-1', profile: DeviceProfile.sphere);
      first.connState = ConnState.disconnected; // it dropped
      final again = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'id-2', profile: DeviceProfile.sphere);
      expect(again, same(first));
      expect(m.batteries.length, 1);
      expect(m.deviceIdOf(first), 'id-2');
      expect(first.rememberedRemoteId, 'id-2');
      expect(m.bindableBySerial('JS-A'), isNull, reason: 'bound under id-2');
      // A third id change rebinds again — still one row.
      final third = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'id-3', profile: DeviceProfile.sphere);
      expect(third, same(first));
      expect(m.deviceIdOf(first), 'id-3');
      expect(m.batteries.length, 1);
    });

    test('a CONNECTED row with the same serial is never stolen', () {
      final m = BatteryManager();
      final live = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'id-1', profile: DeviceProfile.sphere);
      live.connState = ConnState.connected;
      final other = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'id-2', profile: DeviceProfile.sphere);
      expect(other, isNot(same(live)));
      expect(m.deviceIdOf(live), 'id-1');
    });
  });

  // -------------------------------------------------------------------------
  group('M13: scan failures are surfaced', () {
    test('describeScanError maps the common causes', () {
      expect(describeScanError('Bluetooth must be turned on'),
          contains('Bluetooth is off'));
      expect(describeScanError('BluetoothAdapterState.off'),
          contains('Bluetooth is off'));
      expect(describeScanError('permission denied: BLUETOOTH_SCAN'),
          contains('permission denied'));
      expect(describeScanError('weird'), 'Scan failed: weird');
    });

    test('a throwing startScan sets lastScanError; a good scan clears it',
        () async {
      AppLog.instance.echoToConsole = false;
      final t = NoopTransport()..scanError = StateError('adapter off');
      final m = BatteryManager(
          transport: t,
          scanWindow: const Duration(milliseconds: 5),
          rescanInterval: const Duration(hours: 1));
      await m.startLive();
      expect(m.lastScanError, isA<StateError>());
      expect(m.scanErrorText, contains('Bluetooth is off'));
      t.scanError = null;
      await m.scanOnceForTest();
      expect(m.lastScanError, isNull);
      expect(m.scanErrorText, isNull);
      m.stopLive();
      m.disposeAll();
      AppLog.instance.echoToConsole = true;
    });
  });

  // -------------------------------------------------------------------------
  group('M14: every cell present is logged; charts take N cells', () {
    test('Metric.cell / cellIndex / compareCells', () {
      expect(Metric.cell(0), 'cell1');
      expect(Metric.cell(11), 'cell12');
      expect(Metric.cellIndex('cell12'), 12);
      expect(Metric.cellIndex('cellSum'), isNull);
      expect(Metric.cellIndex('packV'), isNull);
      final names = ['cell10', 'cell2', 'cell1']..sort(Metric.compareCells);
      expect(names, ['cell1', 'cell2', 'cell10']);
    });

    test('a 12-cell pack logs cell1..cell12 and cellMetrics lists them',
        () async {
      final log = openLogger(freshPath());
      await log.init();
      final conn = BatteryConnection(transport: NoopTransport());
      conn.state.serial = 'JS-12';
      conn.state.cellsMv = List.generate(12, (i) => 3300 + i);
      log.observeConnection(conn, nowMs: 5000);
      await log.drain();
      for (var i = 0; i < 12; i++) {
        final segs = log.hourSegments('JS-12', Metric.cell(i));
        expect(segs.single.valueNum, closeTo((3300 + i) / 1000.0, 1e-9));
      }
      expect(log.hourSegments('JS-12', 'cell13'), isEmpty);
      final cells = await log.cellMetrics('JS-12');
      expect(cells, List.generate(12, Metric.cell));
      expect(chartMetrics(cells).take(12), cells);
      expect(chartMetrics(const []).take(4), Metric.cells,
          reason: 'no history yet: the familiar four');
      await log.dispose();
      await conn.dispose();
    });
  });
}
