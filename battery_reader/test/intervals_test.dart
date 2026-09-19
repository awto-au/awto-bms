import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/intervals.dart';

/// Review pass C2: the shared interval helpers that the charts, the sparklines
/// and the logger now all call — one implementation of the gap rule, the run
/// split, the coverage merge / offline complement, the live-tail splice (H4,
/// moved here from battery_log.dart), the y-axis policy (#32, one function for
/// charts AND sparklines) and the look-back window / range derivation.
void main() {
  ReadingInterval iv(int s, int e, [double? v]) =>
      ReadingInterval(metric: 'm', valueNum: v, startMs: s, endMs: e);

  group('abuts — THE gap rule', () {
    test('within or at the threshold abuts; one ms over does not', () {
      expect(abuts(1000, 11000, 10000), isTrue);
      expect(abuts(1000, 11001, 10000), isFalse);
      expect(abuts(1000, 1000, 10000), isTrue, reason: 'touching');
      expect(abuts(1000, 500, 10000), isTrue, reason: 'overlap');
    });
  });

  group('splitRuns', () {
    test('an abutting run stays ONE run', () {
      final runs = splitRuns([iv(0, 1000, 5), iv(1000, 2000, 6), iv(2000, 3000, 7)],
          gapMs: 10000);
      expect(runs.length, 1);
      expect(runs.single.length, 3);
    });

    test('a gap wider than the threshold SPLITS into two runs (unbridged)', () {
      final runs =
          splitRuns([iv(0, 1000, 5), iv(20000, 21000, 5)], gapMs: 10000);
      expect(runs.length, 2);
      expect(runs[0].last.endMs, 1000);
      expect(runs[1].first.startMs, 20000);
    });

    test('where() drops rows BEFORE grouping (a dropped row never extends)',
        () {
      final runs = splitRuns(
        [iv(0, 1000, 1), iv(1000, 2000), iv(2000, 3000, 2)],
        gapMs: 10000,
        where: (r) => r.valueNum != null,
      );
      expect(runs.length, 1);
      expect(runs.single.map((r) => r.valueNum), [1, 2]);
    });

    test('empty input yields no runs', () {
      expect(splitRuns(const <ReadingInterval>[], gapMs: 10000), isEmpty);
    });
  });

  group('mergeCoverage / uncoveredGaps', () {
    test('overlapping and abutting spans merge; a wide gap stays separate', () {
      final merged = mergeCoverage(
          [iv(5000, 9000), iv(0, 6000), iv(30000, 40000)],
          gapMs: 10000);
      expect(merged, [(0, 9000), (30000, 40000)]);
    });

    test('offline gaps are the complement within the window, > gapMs only', () {
      final gaps = uncoveredGaps([iv(20000, 30000), iv(50000, 60000)], 0, 100000,
          gapMs: 10000);
      expect(gaps, [(0, 20000), (30000, 50000), (60000, 100000)]);
      // A short uncovered stretch (<= gapMs) is not "offline".
      expect(uncoveredGaps([iv(0, 5000), iv(12000, 20000)], 0, 20000,
              gapMs: 10000),
          isEmpty);
    });

    test('a gap that runs past the window end is clipped to it', () {
      expect(uncoveredGaps([iv(0, 10000), iv(80000, 90000)], 0, 50000,
              gapMs: 10000),
          [(10000, 50000)]);
    });

    test('nothing covered -> no gaps (nothing to contrast against)', () {
      expect(uncoveredGaps(const <ReadingInterval>[], 0, 1000, gapMs: 10),
          isEmpty);
    });
  });

  group('H4: spliceTail keeps every DB row and appends only the new tail', () {
    ReadingInterval soc(int s, int e, double v) =>
        ReadingInterval(metric: 'soc', valueNum: v, startMs: s, endMs: e);

    test('previous-session DB history + this-session buffer: both retained, '
        'gap preserved', () {
      const t = 10 * 3600 * 1000; // "now"
      // Previous session: an hour of rows ending 30 min ago (the buffer never
      // held these — the app was restarted).
      final db = [
        soc(t - 90 * 60000, t - 60 * 60000, 50),
        soc(t - 60 * 60000, t - 30 * 60000, 49),
      ];
      // This session's in-memory hour: started 5 min ago.
      final buf = [soc(t - 5 * 60000, t, 48)];
      final out = spliceTail(db, buf, sinceMs: t - 3600 * 1000);
      expect(out.length, 3);
      expect(out.sublist(0, 2), db, reason: 'DB rows kept verbatim');
      expect(out[2].startMs, t - 5 * 60000);
      expect(out[2].endMs, t);
      // The offline window [t-30min, t-5min] is preserved, not bridged.
      expect(out[2].startMs - out[1].endMs, 25 * 60000);
    });

    test('an open row not yet flushed is completed, not duplicated', () {
      const t = 10 * 3600 * 1000;
      final db = [soc(t - 10 * 60000, t - 2 * 60000, 48)]; // flushed 2 min ago
      final buf = [soc(t - 10 * 60000, t, 48)]; // same run, live to now
      final out = spliceTail(db, buf);
      expect(out.length, 2);
      expect(out[1].startMs, t - 2 * 60000, reason: 'clamped to DB max end');
      expect(out[1].endMs, t);
      expect(out[1].metric, 'soc', reason: 'clamp keeps the row identity');
    });

    test('buffer segments fully covered by the DB are dropped — and the body '
        'is returned AS IS (same identity), so an unchanged series is cheap to '
        'detect', () {
      final db = [soc(0, 5000, 1), soc(5000, 9000, 2)];
      final buf = [soc(0, 5000, 1), soc(5000, 9000, 2)];
      final out = spliceTail(db, buf);
      expect(out, db);
      expect(identical(out, db), isTrue);
    });

    test('repeated splicing onto the same body never fragments', () {
      const t = 10 * 3600 * 1000;
      final db = [soc(t - 10 * 60000, t - 2 * 60000, 48)];
      var buf = [soc(t - 10 * 60000, t, 48)];
      final a = spliceTail(db, buf);
      buf = [soc(t - 10 * 60000, t + 1000, 48)]; // one tick later
      final b = spliceTail(db, buf);
      expect(a.length, 2);
      expect(b.length, 2, reason: 'still one tail segment, not a sliver more');
      expect(b[1].endMs, t + 1000);
    });
  });

  group('yBounds — the ONE 0-based / symmetric axis policy (#32)', () {
    test('explicit min/max win (e.g. SOC 0..100)', () {
      expect(yBounds(20, 80, minY: 0, maxY: 100), (0.0, 100.0));
    });

    test('no finite data falls back to 0..1', () {
      expect(yBounds(double.infinity, double.negativeInfinity), (0.0, 1.0));
    });

    group('charts (pad 0.1)', () {
      test('all-positive data keeps 0 as the hard floor, pads the top', () {
        final (lo, hi) = yBounds(3.0, 3.6);
        expect(lo, 0); // includes 0 — no band far from zero
        expect(hi, closeTo(3.6 + 0.36, 1e-9)); // 10 % of the 0..3.6 span
      });

      test('all-negative data keeps 0 as the hard ceiling', () {
        final (lo, hi) = yBounds(-5, -1);
        expect(hi, 0);
        expect(lo, closeTo(-5.5, 1e-9));
      });

      test('signed (centreZero) span is symmetric about 0 and padded', () {
        final (lo, hi) = yBounds(-4, 12, centreZero: true);
        expect(lo, -hi);
        expect(hi, closeTo(13.2, 1e-9));
      });

      test('flat at 0 keeps the floor: 0..1 (centred: −1..1)', () {
        expect(yBounds(0, 0), (0.0, 1.0));
        expect(yBounds(0, 0, centreZero: true), (-1.0, 1.0));
      });
    });

    group('sparklines (pad 0)', () {
      test('all-positive data spans exactly 0..max', () {
        expect(yBounds(3.2, 3.4, pad: 0), (0.0, 3.4));
      });

      test('all-negative data spans exactly min..0', () {
        expect(yBounds(-3, -1, pad: 0), (-3.0, 0.0));
      });

      test('signed metric is exactly symmetric about 0', () {
        expect(yBounds(-4, 12, centreZero: true, pad: 0), (-12.0, 12.0));
      });

      test('a flat series: at 5 -> 0..5; at 0 -> widened to −1..1 so the held '
          'line sits mid-height', () {
        expect(yBounds(5, 5, pad: 0), (0.0, 5.0));
        expect(yBounds(0, 0, pad: 0), (-1.0, 1.0));
        expect(yBounds(0, 0, centreZero: true, pad: 0), (-1.0, 1.0));
      });
    });
  });

  group('LookbackWindow', () {
    test('spans and labels', () {
      expect(LookbackWindow.h1.spanMs, 3600 * 1000);
      expect(LookbackWindow.h6.spanMs, 6 * 3600 * 1000);
      expect(LookbackWindow.h24.spanMs, 24 * 3600 * 1000);
      expect(LookbackWindow.d7.spanMs, 7 * 24 * 3600 * 1000);
      expect(LookbackWindow.all.spanMs, isNull);
      expect(LookbackWindow.values.map((w) => w.label),
          ['1h', '6h', '24h', '7d', 'All']);
    });

    test('the charts page offers 1h/6h/24h/All; the sparklines add 7d', () {
      expect(LookbackWindow.chartWindows, [
        LookbackWindow.h1,
        LookbackWindow.h6,
        LookbackWindow.h24,
        LookbackWindow.all,
      ]);
      expect(LookbackWindow.values.length, 5);
    });
  });

  group('computeRange', () {
    test('a fixed window is exactly now-span .. now', () {
      final r = computeRange(const <List<ReadingInterval>>[], 3600 * 1000, 5000000);
      expect(r, (fromMs: 5000000 - 3600 * 1000, toMs: 5000000));
    });

    test('"all" spans the data extent, extended to now', () {
      final r = computeRange([
        [iv(1000, 2000)],
        [iv(500, 9000)],
      ], null, 20000);
      expect(r.fromMs, 500);
      expect(r.toMs, 20000, reason: 'now is later than the newest end');
    });

    test('"all" keeps a future-dated end, and is never shorter than a minute',
        () {
      expect(computeRange([[iv(0, 99000)]], null, 50000).toMs, 99000);
      final tiny = computeRange([[iv(1000, 1000)]], null, 1000);
      expect(tiny.toMs - tiny.fromMs, 60 * 1000);
    });

    test('"all" with no data is the last hour', () {
      final r = computeRange(const <List<ReadingInterval>>[], null, 7200000);
      expect(r, (fromMs: 7200000 - 3600 * 1000, toMs: 7200000));
    });
  });

  group('intervalsSignature (L8)', () {
    test('equal content -> equal signature; a grown tail or new row differs',
        () {
      final a = [iv(0, 1000, 1), iv(1000, 2000, 2)];
      final b = [iv(0, 1000, 1), iv(1000, 2000, 2)];
      expect(intervalsSignature(a), intervalsSignature(b));
      expect(intervalsSignature(a),
          isNot(intervalsSignature([iv(0, 1000, 1), iv(1000, 2500, 2)])));
      expect(intervalsSignature(a),
          isNot(intervalsSignature([...a, iv(2000, 3000, 3)])));
      expect(intervalsSignature(const []), 0);
    });
  });
}
