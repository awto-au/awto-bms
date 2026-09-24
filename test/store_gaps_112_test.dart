/// GitHub #112: telemetry received and shown, but not written to the interval
/// store.
///
/// Root cause: the manager attached the [BatteryLogger] to a row only when a
/// scan first discovered it. A remembered pack is restored as an offline
/// placeholder by `startLive`; when the app (re)started and went to the
/// background before a scan sighted the pack, the first background sample
/// linked the placeholder directly (by its remembered address) and registered
/// it by device id. From then on the scan path saw an "existing" row and only
/// reconnected it, so the logger was never attached for the rest of the
/// process: the UI and the raw log got every frame, the store none.
///
/// The fix attaches the store on every link path (the one connect choke point
/// and the placeholder itself), and Diagnostics now shows when history was
/// last saved and how many rows this session, so a silent gap is visible.
library;

import 'dart:io';

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/diagnostics_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'fakes.dart';

List<int> u16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> u24(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff];

/// One full telemetry cycle (VOL, TEMP, ALL, MOS, BAL, SOC) at [cellMv] mV
/// per cell and [soc] %.
List<List<int>> cycle({int cellMv = 3300, int soc = 50}) => [
      [
        0xA0,
        0xC1,
        4,
        ...u16(cellMv),
        ...u16(cellMv),
        ...u16(cellMv),
        ...u16(cellMv),
        0xB1,
        0xD2
      ],
      [0xA1, 0x4F, 0x20, 28, 0x20, 30, 0xB2, 0xE3],
      [
        0xA2,
        0x57,
        ...u16(132),
        ...u24(1500),
        0,
        1,
        24,
        ...u16(132),
        ...u16(3310),
        ...u16(3300),
        ...u16(10),
        ...u16(198),
        ...u16(7),
        ...u16(3303),
        0xB3,
        0x6C,
      ],
      [0xA3, 0x9F, 1, 1, 0, 0, 0, 0, 0xB4, 0xC7],
      [0xA8, 0xAC, 1, 1, 1, 0, 1, 0, 0, 0xB9, 0x21],
      [0xA9, 0x64, soc, ...u24(100000), ...u24(soc * 1000), 0xBA, 0x5E],
    ];

const serial = 'JS-2C14B8';
const devId = '0A:24:37:2C:14:B8';

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('store112_'));
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A store a failed test left open; the temp dir is the OS's to clear.
    }
  });
  setUp(() {
    AppLog.instance.clear();
    AppLog.instance.echoToConsole = false;
  });

  var n = 0;
  String freshPath() => '${tmp.path}${Platform.pathSeparator}db${n++}.db';
  Future<Database> ffiOpen(String path, OpenDatabaseOptions o) =>
      databaseFactoryFfi.openDatabase(path, options: o);

  /// A manager as the app builds it after a restart: B8 is a remembered
  /// favourite, the store is open, and the first scan does not sight it.
  Future<(BatteryManager, BatteryLogger, FakeTransport)> restarted() async {
    final log = BatteryLogger.custom(path: freshPath(), opener: ffiOpen);
    final t = FakeTransport();
    final m = BatteryManager(
      transport: t,
      logger: log,
      fleetStore: FakeFleetStore()
        ..saved = {
          serial: const FleetRecord(
              serial: serial, profile: 'JS', remoteId: devId, fullAh: 100),
        },
      scanWindow: const Duration(milliseconds: 10),
      rescanInterval: const Duration(seconds: 100),
    );
    addTearDown(() async {
      m.stopLive();
      m.disposeAll();
      await log.drain();
      await log.dispose();
    });
    await m.loadFleetMembership();
    await m.startLive();
    expect(log.enabled, isTrue);
    return (m, log, t);
  }

  Future<void> feed(BatteryConnection c, List<List<int>> frames) async {
    for (final f in frames) {
      c.parser.addBytes(f);
    }
    await Future<void>.delayed(Duration.zero);
  }

  group('#112: a pack first linked by a background sample is stored', () {
    test('sample of a remembered placeholder writes rows', () async {
      final (m, log, t) = await restarted();
      final b8 = m.batteries.single;
      expect(b8.isRemembered, isTrue);

      // Backgrounded straight after the restart, then one sample.
      await m.enterSampling(const Duration(minutes: 5));
      final sample = m.sampleOnce();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(b8.connState, ConnState.connected, reason: 'linked by the sample');
      await feed(b8, cycle());
      expect(await sample, isTrue);

      // The frames reached the UI state...
      expect(b8.state.socPercent, 50);
      // ...and the store.
      await log.drain();
      expect(await log.readingCount(serial), greaterThan(0),
          reason: 'every decoded frame is offered to the store');
      expect(log.rowsWrittenThisSession, greaterThan(0));
      expect(log.lastWriteMs, isNotNull);
    });

    test('the foreground link after that sample keeps writing', () async {
      final (m, log, t) = await restarted();
      final b8 = m.batteries.single;
      await m.enterSampling(const Duration(minutes: 5));
      final sample = m.sampleOnce();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await feed(b8, cycle());
      await sample;
      await log.drain();
      final afterSample = await log.readingCount(serial);

      // Foreground again: the row is reconnected through the "known device"
      // path (not a fresh discovery) — the case that stayed unlogged.
      await m.exitSampling();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(b8.connState, ConnState.connected);
      await feed(b8, cycle(cellMv: 3350, soc: 60)); // an 89 A load, say
      await log.drain();
      expect(await log.readingCount(serial), greaterThan(afterSample));
      expect(log.attachmentCount, 1, reason: 'attached once, not per link');
    });

    test('a pack re-sighted by a scan after a sample is still attached once',
        () async {
      final (m, log, t) = await restarted();
      final b8 = m.batteries.single;
      await m.enterSampling(const Duration(minutes: 5));
      final sample = m.sampleOnce();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await feed(b8, cycle());
      await sample;
      final handle = b8.loggerAttachment;
      expect(handle, isNotNull);
      await m.exitSampling();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(b8.loggerAttachment, same(handle),
          reason: 'no re-subscribe per connect');
      expect(log.attachmentCount, 1);
    });
  });

  group('#112: Diagnostics "History last saved"', () {
    test('counts rows written this session and stamps the last write',
        () async {
      final log = BatteryLogger.custom(path: freshPath(), opener: ffiOpen);
      await log.init();
      expect(log.rowsWrittenThisSession, 0);
      expect(log.lastWriteMs, isNull);
      expect(log.historySavedLine(),
          'History last saved: never · 0 rows this session');

      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      log.ensureAttached(c);
      await c.connectTo(devId, name: serial);
      await feed(c, cycle());
      await log.drain();
      final rows = await log.readingCount(serial);
      expect(rows, greaterThan(0));
      expect(log.rowsWrittenThisSession, rows);
      expect(log.lastWriteMs, isNotNull);
      await c.dispose();
      await log.drain();
      await log.dispose();
    });

    test('the line: time today, date otherwise, row count', () {
      final now = DateTime(2026, 9, 24, 15, 30).millisecondsSinceEpoch;
      final today = DateTime(2026, 9, 24, 14, 11, 32).millisecondsSinceEpoch;
      final earlier = DateTime(2026, 9, 23, 11, 24, 4).millisecondsSinceEpoch;
      expect(historySavedText(lastWriteMs: null, rows: 0, nowMs: now),
          'History last saved: never · 0 rows this session');
      expect(historySavedText(lastWriteMs: today, rows: 1, nowMs: now),
          'History last saved: 14:11:32 · 1 row this session');
      expect(historySavedText(lastWriteMs: earlier, rows: 2380, nowMs: now),
          'History last saved: 23 Sep 11:24:04 · 2380 rows this session');
    });

    testWidgets('the Diagnostics page shows it under the interval store',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: DiagnosticsPage()));
      expect(
          find.textContaining(
              RegExp(r'\nHistory last saved: .+ this session$')),
          findsOneWidget);
    });

    test('ensureAttached is idempotent; attach still replaces', () async {
      final log = BatteryLogger.custom();
      final c = BatteryConnection(transport: NoopTransport());
      final h1 = log.ensureAttached(c);
      expect(log.ensureAttached(c), same(h1));
      expect(log.attachmentCount, 1);
      final h2 = log.attach(c);
      await Future<void>.delayed(Duration.zero);
      expect(h1.isCancelled, isTrue);
      expect(log.ensureAttached(c), same(h2));
      expect(log.attachmentCount, 1);
      await c.dispose();
      expect(log.attachmentCount, 0);
      final other = BatteryLogger.custom();
      final c2 = BatteryConnection(transport: NoopTransport());
      final h3 = other.ensureAttached(c2);
      expect(log.ensureAttached(c2), isNot(same(h3)),
          reason: "another logger's handle does not count");
      await c2.dispose();
    });
  });
}
