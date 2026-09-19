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

  group('AggregateTotals', () {
    test('throughput is charge + discharge and sums across batteries', () {
      const a = AggregateTotals(chargeAh: 10, dischargeAh: 4, efc: 0.14);
      const b = AggregateTotals(chargeAh: 6, dischargeAh: 6, efc: 0.12);
      expect(a.throughputAh, 14);
      final sum = a + b;
      expect(sum.chargeAh, 16);
      expect(sum.dischargeAh, 10);
      expect(sum.efc, closeTo(0.26, 1e-9));
    });
  });

  group('foldLifetime incremental checkpoint (#37)', () {
    // Helper: a signed-current packI interval row [startMs, endMs] @ current A.
    ReadingInterval iv(int startMs, int endMs, double current) =>
        ReadingInterval(
          metric: 'packI',
          valueNum: current,
          startMs: startMs,
          endMs: endMs,
        );

    test('first aggregation over some rows sets totals + watermark', () {
      // +10 A for 3600 s => +10 Ah charge; -5 A for 3600 s => 5 Ah discharge.
      final lt = foldLifetime(
        prior: const LifetimeTotals(),
        newRows: [
          iv(0, 3600 * 1000, 10),
          iv(3600 * 1000, 2 * 3600 * 1000, -5),
        ],
        ratedFullAh: 100,
      );
      expect(lt.chargeAh, closeTo(10, 1e-9));
      expect(lt.dischargeAh, closeTo(5, 1e-9));
      // EFC = throughput / rated = (10 + 5) / 100.
      expect(lt.efc, closeTo(0.15, 1e-9));
      // Watermark advanced to the newest row's end.
      expect(lt.aggregatedUpToMs, 2 * 3600 * 1000);
    });

    test('a second call with only new rows ADDS and advances the watermark '
        'without re-counting old rows', () {
      final first = foldLifetime(
        prior: const LifetimeTotals(),
        newRows: [iv(0, 3600 * 1000, 10)], // +10 Ah
        ratedFullAh: 100,
      );
      expect(first.chargeAh, closeTo(10, 1e-9));
      expect(first.aggregatedUpToMs, 3600 * 1000);

      // Only the NEW row is passed (mirrors the DB filter end_time > watermark).
      final second = foldLifetime(
        prior: first,
        newRows: [iv(3600 * 1000, 2 * 3600 * 1000, 20)], // +20 Ah
        ratedFullAh: 100,
      );
      // Added to the prior total, not recomputed from scratch.
      expect(second.chargeAh, closeTo(30, 1e-9));
      expect(second.dischargeAh, 0);
      expect(second.efc, closeTo(0.30, 1e-9)); // (10+20)/100
      expect(second.aggregatedUpToMs, 2 * 3600 * 1000);
    });

    test('a grown open interval counts ONLY its tail past the watermark', () {
      // Row opened at 0, folded once when it ended at t=3600s (=> +10 Ah).
      final first = foldLifetime(
        prior: const LifetimeTotals(),
        newRows: [iv(0, 3600 * 1000, 10)],
        ratedFullAh: 100,
      );
      expect(first.chargeAh, closeTo(10, 1e-9));

      // The SAME open row later grew to t=2*3600s (same value). The DB query
      // (end_time > watermark) re-selects it; the fold must only add the tail
      // [3600s, 7200s] = +10 Ah, NOT re-count [0, 3600s].
      final second = foldLifetime(
        prior: first,
        newRows: [iv(0, 2 * 3600 * 1000, 10)],
        ratedFullAh: 100,
      );
      expect(second.chargeAh, closeTo(20, 1e-9));
      expect(second.aggregatedUpToMs, 2 * 3600 * 1000);
    });

    test('charge vs discharge split by current sign', () {
      final lt = foldLifetime(
        prior: const LifetimeTotals(),
        newRows: [
          iv(0, 3600 * 1000, 8), // +8 Ah charge
          iv(3600 * 1000, 2 * 3600 * 1000, -3), // 3 Ah discharge
          iv(2 * 3600 * 1000, 3 * 3600 * 1000, 0), // idle, contributes nothing
        ],
        ratedFullAh: 50,
      );
      expect(lt.chargeAh, closeTo(8, 1e-9));
      expect(lt.dischargeAh, closeTo(3, 1e-9));
      expect(lt.throughputAh, closeTo(11, 1e-9));
    });

    test('EFC is zero when rated capacity is unknown, then accrues later', () {
      final noRating = foldLifetime(
        prior: const LifetimeTotals(),
        newRows: [iv(0, 3600 * 1000, 10)],
        ratedFullAh: null,
      );
      expect(noRating.chargeAh, closeTo(10, 1e-9));
      expect(noRating.efc, 0);

      final withRating = foldLifetime(
        prior: noRating,
        newRows: [iv(3600 * 1000, 2 * 3600 * 1000, 10)],
        ratedFullAh: 100,
      );
      // Only the second batch's throughput (10 Ah) / 100 accrues to EFC.
      expect(withRating.efc, closeTo(0.10, 1e-9));
    });

    test('no new rows leaves totals and watermark unchanged', () {
      const prior =
          LifetimeTotals(chargeAh: 5, dischargeAh: 2, efc: 0.07, aggregatedUpToMs: 999);
      final lt = foldLifetime(prior: prior, newRows: const [], ratedFullAh: 100);
      expect(lt.chargeAh, 5);
      expect(lt.dischargeAh, 2);
      expect(lt.efc, closeTo(0.07, 1e-9));
      expect(lt.aggregatedUpToMs, 999);
    });
  });

  group('H1: rows are HELD until the next row starts (change-every-sample)', () {
    ReadingInterval iv(int startMs, int endMs, double current) =>
        ReadingInterval(
          metric: 'packI',
          valueNum: current,
          startMs: startMs,
          endMs: endMs,
        );

    test('start == end rows (value changed on every sample) contribute Ah', () {
      // Ten 1-Hz samples at -5 A, each a change-only row with start == end.
      // Before the fix each row spanned 0 s -> 0 Ah total. Now each row is held
      // to the next row's start: 9 x 1 s at 5 A = 45 A.s = 0.0125 Ah (the last
      // row holds only to its own end -> 0 s until a later row appears).
      final rows = [for (var k = 0; k < 10; k++) iv(k * 1000, k * 1000, -5)];
      final r = integrateCurrentRows(rows, gapMs: 10000);
      expect(r.dischargeAh, closeTo(5 * 9 / 3600.0, 1e-12)); // 0.0125 Ah
      expect(r.chargeAh, 0);
      expect(r.newestEndMs, 9000);

      final lt = foldLifetime(
          prior: const LifetimeTotals(), newRows: rows, ratedFullAh: 100);
      expect(lt.dischargeAh, closeTo(0.0125, 1e-12));
      expect(lt.efc, closeTo(0.0125 / 100, 1e-15));
      expect(lt.aggregatedUpToMs, 9000);
    });

    test('the hold is bounded by the gap threshold (offline gap not bridged)',
        () {
      // 10 A row at t=0 (start == end), next row 60 s later: held for only
      // gapMs (10 s), not 60 s -> 10 A x 10 s = 100 A.s = 0.02778 Ah.
      final rows = [iv(0, 0, 10), iv(60000, 60000, 10)];
      final r = integrateCurrentRows(rows, gapMs: 10000);
      expect(r.chargeAh, closeTo(10 * 10 / 3600.0, 1e-12));
      // A row that ran [0, 5 s] then the next at 8 s: held to 8 s (< end+gap).
      final r2 = integrateCurrentRows([iv(0, 5000, 10), iv(8000, 8000, 10)],
          gapMs: 10000);
      expect(r2.chargeAh, closeTo(10 * 8 / 3600.0, 1e-12));
    });

    test('incremental folds never double-count the watermark row', () {
      // Fold 1: rows at 0,1,2 s (start == end). Watermark -> 2000; the last row
      // contributes nothing yet.
      final f1 = foldLifetime(
        prior: const LifetimeTotals(),
        newRows: [iv(0, 0, 10), iv(1000, 1000, 10), iv(2000, 2000, 10)],
        ratedFullAh: 100,
      );
      expect(f1.chargeAh, closeTo(10 * 2 / 3600.0, 1e-12));
      expect(f1.aggregatedUpToMs, 2000);
      // Fold 2: the DB query (end_time >= watermark) re-returns the 2 s row plus
      // a new row at 3 s. The 2 s row now holds [2000, 3000]; total = 3 s.
      final f2 = foldLifetime(
        prior: f1,
        newRows: [iv(2000, 2000, 10), iv(3000, 3000, 10)],
        ratedFullAh: 100,
      );
      expect(f2.chargeAh, closeTo(10 * 3 / 3600.0, 1e-12));
      expect(f2.aggregatedUpToMs, 3000);
      // Fold 3: nothing new (only the watermark row comes back) -> unchanged.
      final f3 = foldLifetime(
          prior: f2, newRows: [iv(3000, 3000, 10)], ratedFullAh: 100);
      expect(f3.chargeAh, closeTo(f2.chargeAh, 1e-15));
      expect(f3.aggregatedUpToMs, 3000);
    });

    test('a grown open row still counts only its tail past the watermark', () {
      final f1 = foldLifetime(
        prior: const LifetimeTotals(),
        newRows: [iv(0, 3600 * 1000, 10)],
        ratedFullAh: 100,
      );
      expect(f1.chargeAh, closeTo(10, 1e-9));
      // Same row grew to 2 h and a new row opened right after it.
      final f2 = foldLifetime(
        prior: f1,
        newRows: [
          iv(0, 2 * 3600 * 1000, 10),
          iv(2 * 3600 * 1000 + 1000, 2 * 3600 * 1000 + 1000, -5),
        ],
        ratedFullAh: 100,
      );
      // Tail [1 h, 2 h + 1 s] at 10 A = 10 Ah + 10/3600 Ah.
      expect(f2.chargeAh, closeTo(20 + 10 / 3600.0, 1e-9));
    });
  });

  // H4: the live-tail splice moved to intervals.dart (review pass C2) and is
  // tested in intervals_test.dart as spliceTail.

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
