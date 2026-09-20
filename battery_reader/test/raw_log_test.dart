import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/raw_log.dart';

/// Tests for the verbose single-file raw log (issue #19). The line FORMATTING is
/// pure (no I/O), so it is asserted directly. The log entry points are exercised
/// through the [RawLogger.onLine] hook, which fires synchronously for every line
/// without touching the filesystem (init() is never called here).
void main() {
  group('Settings status line (raw logging OFF is stated plainly)', () {
    test('OFF: "Logging is OFF — last wrote <when>", "never" with no file', () {
      expect(
          RawLogger.statusLine(
              enabled: false, sizeBytes: 0, maxBytes: 50, lastWrittenAt: null),
          'Logging is OFF — last wrote never');
      final s = RawLogger.statusLine(
          enabled: false,
          sizeBytes: 0,
          maxBytes: 50,
          lastWrittenAt: DateTime(2026, 9, 20, 14, 5));
      expect(s, startsWith('Logging is OFF — last wrote 2026-09-20 14:05'));
    });

    test('ON: size + rotation cap', () {
      expect(
          RawLogger.statusLine(
              enabled: true,
              sizeBytes: 3 * 1024 * 1024,
              maxBytes: RawLogger.defaultMaxBytes,
              lastWrittenAt: null),
          'Logging — 3.0 MB (rotates at 50.0 MB)');
    });

    test('lastWrittenAt is null before any file, then the file mtime',
        () async {
      final dir = await Directory.systemTemp.createTemp('rawlog_mtime');
      try {
        final log = RawLogger.forTest(dir: dir);
        expect(log.lastWrittenAt, isNull, reason: 'no file before init');
        await log.init();
        log.logRaw('JS-A', [0x01, 0x02]);
        await log.flush();
        final t = log.lastWrittenAt;
        expect(t, isNotNull);
        expect(File(log.path!).lastModifiedSync(), t);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('formatLine (pure)', () {
    final t = DateTime(2026, 9, 19, 14, 23, 1, 123);

    test('has timestamp, serial, label, hex and summary in order', () {
      final line = RawLogger.formatLine(
        time: t,
        serial: 'JS-2C14AA',
        label: 'Battery data',
        raw: [0xA2, 0x57, 0x85, 0x00],
        summary: 'V=13.3',
      );
      // Timestamp first, zero-padded to millisecond.
      expect(line, startsWith('2026-09-19 14:23:01.123  JS-2C14AA  '));
      expect(line, contains('Battery data'));
      expect(line, contains('a2 57 85 00'));
      expect(line, endsWith('V=13.3'));
      // hex precedes the summary.
      expect(line.indexOf('a2 57'), lessThan(line.indexOf('V=13.3')));
    });

    test('single-digit clock fields and millis stay padded', () {
      final line = RawLogger.formatLine(
        time: DateTime(2026, 1, 2, 3, 4, 5, 7),
        serial: 'RV-1',
        label: 'x',
      );
      expect(line, startsWith('2026-01-02 03:04:05.007  RV-1  '));
    });

    test('hex is lowercase, two digits, space-separated', () {
      expect(RawLogger.hexOf([0x00, 0xFF, 0x30, 0x9]), '00 ff 30 09');
    });

    test('empty serial renders as a dash', () {
      final line = RawLogger.formatLine(
        time: t,
        serial: '',
        label: 'TX: handshake begin',
        raw: [0xFB, 0xC8],
        summary: 'sent',
      );
      expect(line, contains('  -  '));
      expect(line, contains('fb c8'));
    });

    test('label column pads so bodies align', () {
      final short = RawLogger.formatLine(
          time: t, serial: 'S', label: 'MOS status', summary: 'on=true');
      final long = RawLogger.formatLine(
          time: t, serial: 'S', label: 'State of charge', summary: '87%');
      // Both summaries start at the same column (label padded to 22 + 1 space).
      expect(short.indexOf('on=true'), long.indexOf('87%'));
    });
  });

  group('log entry points produce lines', () {
    final captured = <String>[];

    setUp(() {
      captured.clear();
      RawLogger.instance.enabled = true;
      RawLogger.instance.onLine = captured.add;
    });

    tearDown(() {
      RawLogger.instance.onLine = null;
    });

    test('a raw notification produces exactly one log line', () {
      RawLogger.instance.logRaw('JS-1', [0xA2, 0x57, 0x30]);
      expect(captured.length, 1);
      expect(captured.single, contains('Notification (raw)'));
      expect(captured.single, contains('a2 57 30'));
      expect(captured.single, contains('3 bytes'));
    });

    test('a decoded event line carries the label, frame hex and summary', () {
      RawLogger.instance
          .logEvent('JS-1', 'State of charge', '87%', frame: [0xA9, 0x64]);
      expect(captured.single, contains('State of charge'));
      expect(captured.single, contains('a9 64'));
      expect(captured.single, endsWith('87%'));
    });

    test('a TX line records the command name and bytes', () {
      RawLogger.instance
          .logTx('JS-1', 'handshake begin', [0xFB, 0xC8, 0x7C]);
      expect(captured.single, contains('TX: handshake begin'));
      expect(captured.single, contains('fb c8 7c'));
    });

    test('an UNRECOGNISED line records the dropped byte value', () {
      RawLogger.instance.logUnrecognised('JS-1', 0x30, runningCount: 1);
      expect(captured.single, contains('UNRECOGNISED'));
      expect(captured.single, contains('30'));
      expect(captured.single, contains('0x30'));
      expect(captured.single, contains('count=1'));
    });

    test('disabling verbose logging suppresses all lines', () {
      RawLogger.instance.enabled = false;
      RawLogger.instance.logRaw('JS-1', [0x01, 0x02]);
      expect(captured, isEmpty);
      RawLogger.instance.enabled = true; // restore for other tests
    });
  });
}
