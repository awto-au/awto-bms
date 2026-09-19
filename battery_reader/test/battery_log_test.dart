import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_log.dart';

/// Pure-logic tests for the append-only interval logger: the change / extend /
/// gap rules ([IntervalRule]) and the fold that turns a stream of observations
/// into interval rows ([buildIntervals]). Neither touches sqflite, so they run
/// on the Dart VM under `flutter test`.
void main() {
  group('IntervalRule change / extend / gap', () {
    const rule = IntervalRule(gapMs: 10000);

    test('opens a new interval when nothing is open', () {
      expect(
        rule.decide(hasOpen: false, newNum: 13.3, nowMs: 1000),
        IntervalAction.openNew,
      );
    });

    test('extends when the value is unchanged and contiguous', () {
      expect(
        rule.decide(
            hasOpen: true, openNum: 13.3, openEndMs: 1000,
            newNum: 13.3, nowMs: 2000),
        IntervalAction.extend,
      );
    });

    test('closes and re-opens on a value change (even if contiguous)', () {
      expect(
        rule.decide(
            hasOpen: true, openNum: 13.3, openEndMs: 1000,
            newNum: 13.4, nowMs: 1500),
        IntervalAction.closeAndOpen,
      );
    });

    test('closes and re-opens across a gap (even if value unchanged)', () {
      expect(
        rule.decide(
            hasOpen: true, openNum: 13.3, openEndMs: 1000,
            newNum: 13.3, nowMs: 1000 + 10001),
        IntervalAction.closeAndOpen,
      );
    });

    test('float noise within epsilon is treated as unchanged', () {
      expect(
        rule.decide(
            hasOpen: true, openNum: 13.3, openEndMs: 0,
            newNum: 13.3 + 1e-12, nowMs: 500),
        IntervalAction.extend,
      );
    });

    test('discrete/text values compare by text', () {
      expect(
        rule.decide(
            hasOpen: true, openText: 'charging', openEndMs: 0,
            newText: 'charging', nowMs: 500),
        IntervalAction.extend,
      );
      expect(
        rule.decide(
            hasOpen: true, openText: 'charging', openEndMs: 0,
            newText: 'idle', nowMs: 500),
        IntervalAction.closeAndOpen,
      );
    });
  });

  group('timestamp column format', () {
    test('fmtTime is zero-padded local yyyy-MM-dd HH:mm:ss.SSS', () {
      final ms = DateTime(2026, 9, 19, 14, 23, 1, 123).millisecondsSinceEpoch;
      expect(BatteryLogger.fmtTime(ms), '2026-09-19 14:23:01.123');
    });

    test('single-digit fields and millis stay padded', () {
      final ms = DateTime(2026, 1, 2, 3, 4, 5, 7).millisecondsSinceEpoch;
      expect(BatteryLogger.fmtTime(ms), '2026-01-02 03:04:05.007');
    });

    test('fmtTime/parseTime round-trip to the same instant', () {
      final ms = DateTime(2026, 9, 19, 14, 23, 1, 123).millisecondsSinceEpoch;
      expect(BatteryLogger.parseTime(BatteryLogger.fmtTime(ms)), ms);
    });
  });

  group('buildIntervals fold', () {
    test('an unchanged, contiguous run collapses into ONE interval', () {
      final out = buildIntervals(const [
        Obs(0, value: 13.3),
        Obs(1000, value: 13.3),
        Obs(2000, value: 13.3),
      ]);
      expect(out.length, 1);
      expect(out.first.valueNum, 13.3);
      expect(out.first.startMs, 0);
      expect(out.first.endMs, 2000); // end advanced to last observation
    });

    test('a value change splits into two abutting intervals', () {
      final out = buildIntervals(const [
        Obs(0, value: 50),
        Obs(1000, value: 50),
        Obs(2000, value: 51), // change
        Obs(3000, value: 51),
      ]);
      expect(out.length, 2);
      expect(out[0].valueNum, 50);
      expect(out[0].startMs, 0);
      expect(out[0].endMs, 1000); // first run keeps its last same-value time
      expect(out[1].valueNum, 51);
      expect(out[1].startMs, 2000); // new run starts at the change
      expect(out[1].endMs, 3000);
      // Abutting: the two runs are 1000 ms apart (< gap), so charts join them.
      expect(out[1].startMs - out[0].endMs, lessThanOrEqualTo(10000));
    });

    test('a gap larger than the threshold is preserved, not bridged', () {
      final out = buildIntervals(const [
        Obs(0, value: 13.3),
        Obs(1000, value: 13.3),
        // ...disconnect... next reading is > 10 s later, same value:
        Obs(20000, value: 13.3),
        Obs(21000, value: 13.3),
      ]);
      expect(out.length, 2);
      expect(out[0].startMs, 0);
      expect(out[0].endMs, 1000); // old row keeps its last end_ms
      expect(out[1].startMs, 20000); // fresh row after the gap
      expect(out[1].endMs, 21000);
      // The known-disconnected window is [1000, 20000).
      expect(out[1].startMs - out[0].endMs, greaterThan(10000));
    });

    test('empty input yields no intervals', () {
      expect(buildIntervals(const []), isEmpty);
    });

    test('metrics/serials are carried through onto every row', () {
      final out = buildIntervals(
        const [Obs(0, value: 1), Obs(500, value: 2)],
        serial: 'JS-1',
        metric: 'soc',
      );
      expect(out.every((iv) => iv.serial == 'JS-1' && iv.metric == 'soc'),
          isTrue);
    });
  });
}
