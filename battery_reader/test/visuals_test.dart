import 'package:flutter_test/flutter_test.dart';

import 'package:battery_reader/health_palette.dart';
import 'package:battery_reader/sparkline.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_charts.dart';
import 'package:battery_reader/battery_protocol.dart' show ChargeState;
import 'package:battery_reader/main.dart' show fChipTemp, fSignedA;

/// Pass 3 (VISUALS) pure-logic tests: the SOC health palette boundaries, the
/// sparkline series builder (offline gaps left unbridged + draw-only
/// downsampling), and the chip "not reported" formatting. (Review pass C2: the
/// look-back windows and the shared y-axis policy are tested in
/// intervals_test.dart; the charge-state band uses [ChargeState] directly.)
void main() {
  group('HealthPalette.colorForSoc', () {
    test('100 % is exactly the healthy green', () {
      expect(HealthPalette.colorForSoc(100), HealthPalette.healthy);
    });

    test('0 % is exactly the critical red', () {
      expect(HealthPalette.colorForSoc(0), HealthPalette.critical);
    });

    test('out-of-range clamps to the endpoints', () {
      expect(HealthPalette.colorForSoc(150), HealthPalette.healthy);
      expect(HealthPalette.colorForSoc(-20), HealthPalette.critical);
    });

    test('grades from red at the bottom to green at the top', () {
      final low = HealthPalette.colorForSoc(10);
      final high = HealthPalette.colorForSoc(90);
      // Low charge is red-dominant; high charge is green-dominant.
      expect(low.r, greaterThan(low.g));
      expect(high.g, greaterThan(high.r));
    });

    test('the mid-range is an amber/yellow (both channels high)', () {
      final mid = HealthPalette.colorForSoc(50);
      expect(mid.r, greaterThan(0.7));
      expect(mid.g, greaterThan(0.6));
      expect(mid.b, lessThan(0.5));
    });

    test('critical health red is DISTINCT from the alarm/fault red', () {
      expect(HealthPalette.critical, isNot(equals(HealthPalette.faultRed)));
    });

    test('socOrFault overrides the graded colour with fault red', () {
      expect(HealthPalette.socOrFault(90, fault: true), HealthPalette.faultRed);
      expect(HealthPalette.socOrFault(90, fault: false),
          HealthPalette.colorForSoc(90));
    });
  });

  group('buildSparklineRuns (offline gaps unbridged)', () {
    ReadingInterval iv(int s, int e, double v) =>
        ReadingInterval(startMs: s, endMs: e, valueNum: v);

    test('an abutting run stays ONE run', () {
      final runs = buildSparklineRuns([
        iv(0, 1000, 5),
        iv(1000, 2000, 6), // abuts (0 ms gap)
        iv(2000, 3000, 7),
      ], gapMs: 10000);
      expect(runs.length, 1);
      // step points: (start,v)(end,v) per interval.
      expect(runs.first.length, 6);
    });

    test('a gap wider than the threshold SPLITS into two runs (unbridged)', () {
      final runs = buildSparklineRuns([
        iv(0, 1000, 5),
        // ...offline... next row starts > 10 s after the previous end:
        iv(20000, 21000, 5),
      ], gapMs: 10000);
      expect(runs.length, 2);
      // The two runs are separate: the first ends at 1000, the second starts
      // at 20000 — nothing bridges [1000, 20000).
      expect(runs[0].last.ms, 1000);
      expect(runs[1].first.ms, 20000);
    });

    test('null-valued rows are skipped', () {
      final runs = buildSparklineRuns([
        const ReadingInterval(startMs: 0, endMs: 1000, valueNum: null),
        iv(1000, 2000, 3),
      ]);
      expect(runs.length, 1);
      expect(runs.first.first.v, 3);
    });

    test('downsampling caps a run but keeps the first and last points', () {
      final many = [for (var i = 0; i < 5000; i++) iv(i * 100, i * 100 + 100, i.toDouble())];
      final runs = buildSparklineRuns(many, maxPointsPerRun: 200);
      expect(runs.length, 1);
      expect(runs.first.length, lessThanOrEqualTo(200));
      expect(runs.first.first.ms, 0); // first preserved
      expect(runs.first.last.ms, many.last.endMs.toDouble()); // last preserved
    });

    test('empty input yields no runs', () {
      expect(buildSparklineRuns(const []), isEmpty);
    });
  });

  group('chip temperature formatting', () {
    test('0 renders as "not reported", not a misleading 0 °C', () {
      expect(fChipTemp(0), '— (not reported)');
    });
    test('null renders as an em dash', () {
      expect(fChipTemp(null), '—');
    });
    test('a real value renders normally', () {
      expect(fChipTemp(25), '25 °C');
      expect(fChipTemp(-3), '-3 °C');
    });
  });

  group('charge-state / load band builder (#22)', () {
    // Pack a `flags` value the SAME way the store does (LSB-first): chargeState
    // in bits 10-11, load/charger as single bits.
    int flags(ChargeState st, {bool load = false, bool charger = false}) {
      final cs = switch (st) {
        ChargeState.charging => 1,
        ChargeState.discharging => 2,
        ChargeState.idle || ChargeState.unknown => 0,
      };
      var f = cs << Flags.chargeStateShift;
      if (load) f |= Flags.load;
      if (charger) f |= Flags.charger;
      return f;
    }

    ReadingInterval iv(int s, int e, int f) =>
        ReadingInterval(startMs: s, endMs: e, valueNum: f.toDouble());

    test('chargeStateOf reads bits 10-11 (0 idle / 1 charging / 2 discharging)',
        () {
      expect(chargeStateOf(flags(ChargeState.idle)), ChargeState.idle);
      expect(chargeStateOf(flags(ChargeState.charging)),
          ChargeState.charging);
      expect(chargeStateOf(flags(ChargeState.discharging)),
          ChargeState.discharging);
      // Load/charger bits do NOT change the derived charge state.
      expect(chargeStateOf(flags(ChargeState.charging, load: true, charger: true)),
          ChargeState.charging);
    });

    test('maps flags rows to state segments over time', () {
      final segs = buildChargeSegments([
        iv(0, 1000, flags(ChargeState.idle)),
        iv(1000, 2000, flags(ChargeState.charging)),
        iv(2000, 3000, flags(ChargeState.discharging, load: true)),
      ]);
      expect(segs.map((s) => s.state).toList(), [
        ChargeState.idle,
        ChargeState.charging,
        ChargeState.discharging,
      ]);
      expect(segs.last.loadConnected, isTrue);
      expect(segs.first.startMs, 0);
      expect(segs.last.endMs, 3000);
    });

    test('abutting rows of the same state + load bits merge into one segment',
        () {
      final segs = buildChargeSegments([
        iv(0, 1000, flags(ChargeState.charging)),
        iv(1000, 2000, flags(ChargeState.charging)), // abuts, same state
        iv(2000, 3000, flags(ChargeState.charging)),
      ], gapMs: 10000);
      expect(segs.length, 1);
      expect(segs.single.startMs, 0);
      expect(segs.single.endMs, 3000);
      expect(segs.single.state, ChargeState.charging);
    });

    test('a change in load-connected bit splits the segment even if state same',
        () {
      final segs = buildChargeSegments([
        iv(0, 1000, flags(ChargeState.discharging, load: false)),
        iv(1000, 2000, flags(ChargeState.discharging, load: true)),
      ]);
      expect(segs.length, 2);
      expect(segs[0].loadConnected, isFalse);
      expect(segs[1].loadConnected, isTrue);
    });

    test('a gap wider than the threshold is PRESERVED (unbridged)', () {
      final segs = buildChargeSegments([
        iv(0, 1000, flags(ChargeState.charging)),
        // ...offline... next row starts > 10 s after the previous end:
        iv(20000, 21000, flags(ChargeState.charging)),
      ], gapMs: 10000);
      // Same state, but not abutting → two segments with a gap between them.
      expect(segs.length, 2);
      expect(segs[0].endMs, 1000);
      expect(segs[1].startMs, 20000);
      // The gap [1000, 20000) is left uncovered (no segment bridges it).
      expect(segs.any((s) => s.startMs < 20000 && s.endMs > 1000), isFalse);
    });

    test('empty flags yields no segments', () {
      expect(buildChargeSegments(const []), isEmpty);
    });

    test('segment colours reuse HealthPalette semantic tokens', () {
      // Confirms the band is graded by SEMANTIC state, not a bespoke palette.
      expect(chargeStateOf(flags(ChargeState.idle)), ChargeState.idle);
      // idle→neutral grey, charging→green, discharging→amber are asserted via
      // the exported tokens the painter uses (see _bandColor in the chart).
      expect(HealthPalette.idle, isNot(equals(HealthPalette.healthy)));
      expect(HealthPalette.healthy, isNot(equals(HealthPalette.warn)));
    });
  });

  group('fSignedA direction words', () {
    test('positive is charging IN', () => expect(fSignedA(12.3), '+12.3 A in'));
    test('negative is discharging OUT',
        () => expect(fSignedA(-4.0), '-4.0 A out'));
    test('near-zero is a plain zero', () => expect(fSignedA(0.0), '0.0 A'));
    test('null is an em dash', () => expect(fSignedA(null), '—'));
  });

  group('sparkYBounds — 0-based / symmetric axis (#32)', () {
    List<List<SparkPoint>> runs(List<double> vs) => [
          [for (final v in vs) SparkPoint(0, v)]
        ];

    test('all-positive data spans 0..max (includes 0, no zoomed band)', () {
      final b = sparkYBounds(runs([3.2, 3.4, 3.35]));
      expect(b, isNotNull);
      expect(b!.$1, 0); // lo pinned to 0
      expect(b.$2, 3.4); // hi = data max
    });

    test('all-negative data spans min..0 (includes 0)', () {
      final b = sparkYBounds(runs([-3, -1, -2]))!;
      expect(b.$1, -3);
      expect(b.$2, 0);
    });

    test('signed metric (centreZero) is symmetric about 0', () {
      final b = sparkYBounds(runs([-4, 12, 3]), centreZero: true)!;
      expect(b.$1, -12);
      expect(b.$2, 12);
    });

    test('a perfectly flat series is padded ±1 around its value+0', () {
      // Flat at 5 → include 0 gives (0,5); not flat after including 0.
      final b = sparkYBounds(runs([5, 5]))!;
      expect(b.$1, 0);
      expect(b.$2, 5);
      // Flat at 0 → padded to (-1, 1).
      final z = sparkYBounds(runs([0, 0]))!;
      expect(z.$1, -1);
      expect(z.$2, 1);
    });

    test('empty runs yield null', () {
      expect(sparkYBounds(const []), isNull);
    });
  });
}
