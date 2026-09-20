/// GitHub #53: background power saving — periodic sampling instead of a held
/// connection when backgrounded.
///
///  * [SampleScheduler] — when a sample is due; a failure just waits for the
///    next tick (never an early retry);
///  * [sampleGapMs] / [GapPolicy] — the gap threshold knows the sample
///    interval in effect, so an expected sampling gap is bridged and only a
///    gap wider than (interval + margin) is offline — at BOTH transitions;
///  * the logger tags every reading with `sampleMode` / `sampleIntervalS`
///    and extends (rather than splits) same-value rows across a sampling gap;
///  * lifetime integration holds a sparse sample to the next one;
///  * the manager's enter / sample / exit cycle over a fake transport.
library;

import 'package:battery_reader/battery_charts.dart' show buildChargeSegments;
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/intervals.dart';
import 'package:battery_reader/monitoring_policy.dart';
import 'package:battery_reader/sparkline.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const min5 = 5 * 60 * 1000;
const t0 = 1000000;

ReadingInterval iv(int s, int e, double v, {String metric = 'packI'}) =>
    ReadingInterval(serial: 'JS-A', metric: metric, valueNum: v, startMs: s, endMs: e);

/// sampleIntervalS rows: continuous until t0, 5-min sampling from t0+5min to
/// t0+25min, continuous again from t0+27min.
final modeRows = [
  iv(t0 - 3600000, t0, 0, metric: 'sampleIntervalS'),
  iv(t0 + min5, t0 + 5 * min5, 300, metric: 'sampleIntervalS'),
  iv(t0 + 5 * min5 + 120000, t0 + 6 * min5, 0, metric: 'sampleIntervalS'),
];

List<int> u16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> u24(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff];

/// One full ~1 Hz telemetry cycle: VOL, TEMP, ALL, MOS, BAL, SOC.
final cycle = <List<int>>[
  [0xA0, 0xC1, 4, ...u16(3300), ...u16(3310), ...u16(3305), ...u16(3300), 0xB1, 0xD2],
  [0xA1, 0x4F, 0x20, 28, 0x20, 30, 0xB2, 0xE3],
  [
    0xA2, 0x57,
    ...u16(132), ...u24(1500), 0, 1, 24, ...u16(132), ...u16(3310),
    ...u16(3300), ...u16(10), ...u16(198), ...u16(7), ...u16(3303),
    0xB3, 0x6C,
  ],
  [0xA3, 0x9F, 1, 1, 0, 0, 0, 0, 0xB4, 0xC7],
  [0xA8, 0xAC, 1, 1, 1, 0, 1, 0, 0, 0xB9, 0x21],
  [0xA9, 0x64, 50, ...u24(100000), ...u24(50000), 0xBA, 0x5E],
];

void main() {
  setUp(() {
    AppLog.instance.clear();
    AppLog.instance.echoToConsole = false;
  });

  group('SampleScheduler — when to sample', () {
    test('first sample one interval after entering; not a ms sooner', () {
      final s = SampleScheduler();
      expect(s.nextDueMs, isNull);
      expect(s.isDue(t0), isFalse);
      s.enter(t0, intervalMs: min5);
      expect(s.nextDueMs, t0 + min5);
      expect(s.isDue(t0 + min5 - 1), isFalse);
      expect(s.isDue(t0 + min5), isTrue);
      expect(s.msUntilDue(t0 + 60000), min5 - 60000);
      expect(s.msUntilDue(t0 + min5 + 5), 0);
      expect(s.lastSuccessMs, t0, reason: 'live data was fresh on entry');
    });

    test('a sample in flight is never overlapped; success resets failures',
        () {
      final s = SampleScheduler()..enter(t0, intervalMs: min5);
      s.started(t0 + min5);
      expect(s.inFlight, isTrue);
      expect(s.isDue(t0 + 2 * min5), isFalse);
      s.finished(t0 + min5 + 3000, ok: true);
      expect(s.inFlight, isFalse);
      expect(s.lastSuccessMs, t0 + min5 + 3000);
      expect(s.consecutiveFailures, 0);
      expect(s.nextDueMs, t0 + 2 * min5, reason: 'anchored on the start');
    });

    test('a failed sample waits for the NEXT tick — no early retry', () {
      final s = SampleScheduler()..enter(t0, intervalMs: min5);
      s.started(t0 + min5);
      s.finished(t0 + min5 + 12000, ok: false);
      expect(s.consecutiveFailures, 1);
      expect(s.lastSuccessMs, t0);
      expect(s.nextDueMs, t0 + 2 * min5);
      expect(s.isDue(t0 + min5 + 13000), isFalse);
      s.started(t0 + 2 * min5);
      s.finished(t0 + 2 * min5 + 1, ok: false);
      expect(s.consecutiveFailures, 2);
      s.started(t0 + 3 * min5);
      s.finished(t0 + 3 * min5 + 1, ok: true);
      expect(s.consecutiveFailures, 0);
    });

    test('continuous (interval 0) is never due', () {
      final s = SampleScheduler()..enter(t0, intervalMs: 0);
      expect(s.nextDueMs, isNull);
      expect(s.isDue(t0 + 3600000), isFalse);
    });
  });

  group('MonitoringPolicy.shouldSample + the interval setting', () {
    test('samples only when backgrounded, allowed and not Continuous', () {
      final p = MonitoringPolicy();
      expect(p.sampleInterval, BackgroundSampleInterval.m5, reason: 'default');
      expect(p.shouldSample, isFalse, reason: 'foreground');
      expect(p.continuousShouldRun, isTrue);
      p.setForeground(false);
      expect(p.shouldSample, isTrue);
      expect(p.continuousShouldRun, isFalse);
      p.sampleInterval = BackgroundSampleInterval.continuous;
      expect(p.shouldSample, isFalse);
      expect(p.continuousShouldRun, isTrue);
      p.sampleInterval = BackgroundSampleInterval.m15;
      p.stopByUser();
      expect(p.shouldSample, isFalse);
      p.resume();
      p.setBackgroundMonitoring(false);
      expect(p.shouldSample, isFalse);
      expect(p.continuousShouldRun, isFalse);
      p.setBackgroundMonitoring(true);
      p.setForeground(true);
      expect(p.shouldSample, isFalse, reason: 'foreground is continuous');
    });

    test('the persisted seconds round-trip; unknown -> the 5 min default', () {
      expect(BackgroundSampleInterval.fromSeconds(0).isContinuous, isTrue);
      expect(BackgroundSampleInterval.fromSeconds(60), BackgroundSampleInterval.m1);
      expect(BackgroundSampleInterval.fromSeconds(300), BackgroundSampleInterval.m5);
      expect(BackgroundSampleInterval.fromSeconds(900), BackgroundSampleInterval.m15);
      expect(BackgroundSampleInterval.fromSeconds(null), BackgroundSampleInterval.m5);
      expect(BackgroundSampleInterval.fromSeconds(7), BackgroundSampleInterval.m5);
      expect(BackgroundSampleInterval.m5.latencyNote, contains('up to 5 min late'));
      expect(BackgroundSampleInterval.continuous.latencyNote, contains('instant'));
      expect(BackgroundSampleInterval.m15.ms, 900000);
    });
  });

  group('gap threshold aware of the sample interval', () {
    test('sampleGapMs: continuous keeps 10 s; sampling = interval + margin', () {
      expect(sampleGapMs(0), 10000);
      expect(sampleGapMs(-1), 10000);
      expect(sampleGapMs(min5), min5 + sampleGapMarginMs);
      expect(sampleGapMs(60000, marginMs: 5000), 65000);
      expect(sampleGapMs(0, baseGapMs: 4000), 4000);
    });

    test('GapPolicy.intervalAt: a row holds until the next row starts', () {
      final p = GapPolicy(modeRows);
      expect(p.intervalAt(t0 - 1), 0);
      expect(p.intervalAt(t0 + 1), 0, reason: 'before the first sample');
      expect(p.intervalAt(t0 + min5), min5);
      expect(p.intervalAt(t0 + 5 * min5 + 60000), min5,
          reason: 'holds past its end until the next row');
      expect(p.intervalAt(t0 + 5 * min5 + 120000), 0);
      expect(p.isBackgroundAt(t0 + 2 * min5), isTrue);
      expect(p.isBackgroundAt(t0), isFalse);
      expect(p.hasBackground, isTrue);
      expect(GapPolicy.continuous.hasBackground, isFalse);
      expect(GapPolicy.continuous.intervalAt(t0), 0);
      expect(GapPolicy.continuous.gapAt(t0), 10000);
    });

    test('expected sampling gaps abut at BOTH transitions; wider is offline',
        () {
      final p = GapPolicy(modeRows);
      // continuous -> first sparse sample: 5 min gap, expected.
      expect(p.abuts(t0, t0 + min5), isTrue);
      // between samples.
      expect(p.abuts(t0 + min5, t0 + 2 * min5), isTrue);
      // last sample -> continuous again: 2 min gap, expected.
      expect(p.abuts(t0 + 5 * min5, t0 + 5 * min5 + 120000), isTrue);
      // a missed sample: 10 min > 6 min threshold -> offline.
      expect(p.abuts(t0 + min5, t0 + 3 * min5), isFalse);
      expect(p.gapFor(t0 + min5, t0 + 3 * min5), min5 + sampleGapMarginMs);
      // continuous stretch: the plain 10 s rule still applies.
      expect(p.abuts(t0 - 20000, t0 - 9000), isFalse);
      expect(p.abuts(t0 - 20000, t0 - 10000), isTrue);
    });

    test('splitRuns / uncoveredGaps / buildChargeSegments / sparkline runs '
        'bridge the sampling gaps and keep the offline hole', () {
      final p = GapPolicy(modeRows);
      final rows = [
        iv(t0 - 60000, t0, 13.2),
        iv(t0 + min5, t0 + min5, 13.2),
        iv(t0 + 2 * min5, t0 + 2 * min5, 13.1),
        // a missed sample: nothing at t0 + 3 min5
        iv(t0 + 4 * min5, t0 + 5 * min5, 13.1),
        iv(t0 + 5 * min5 + 120000, t0 + 6 * min5, 13.0),
      ];
      // The old fixed 10 s rule: five separate runs, four false "offline".
      expect(splitRuns(rows, gapMs: 10000).length, 5);
      // Interval-aware: two runs, split only at the missed sample.
      final runs = splitRuns(rows, gapMs: 10000, policy: p);
      expect(runs.length, 2);
      expect(runs.first.length, 3);
      expect(runs.last.length, 2);
      final gaps = uncoveredGaps(rows, t0 - 60000, t0 + 6 * min5,
          gapMs: 10000, policy: p);
      expect(gaps, [(t0 + 2 * min5, t0 + 4 * min5)]);
      final spark = buildSparklineRuns(rows, policy: p);
      expect(spark.length, 2);
      expect(spark.first.first.bg, isFalse, reason: 'continuous point');
      expect(spark.first.last.bg, isTrue, reason: 'a background sample');
      expect(spark.last.last.bg, isFalse, reason: 'continuous again');
      final flags = [for (final r in rows) iv(r.startMs, r.endMs, 1024)];
      expect(buildChargeSegments(flags, gapMs: 10000).length, 5);
      expect(buildChargeSegments(flags, gapMs: 10000, policy: p).length, 2);
    });

    test('lifetime integration holds a sparse sample to the next one', () {
      final p = GapPolicy(modeRows);
      // 10 A logged at each 5-min sample, three samples.
      final rows = [
        iv(t0 + min5, t0 + min5, 10),
        iv(t0 + 2 * min5, t0 + 2 * min5, 10),
        iv(t0 + 3 * min5, t0 + 3 * min5, 10),
      ];
      final fixed = integrateCurrentRows(rows, gapMs: 10000);
      expect(fixed.chargeAh, closeTo(2 * 10 * 10 / 3600, 1e-9),
          reason: 'the old rule holds only 10 s past each sample');
      final aware = integrateCurrentRows(rows, gapMs: 10000, policy: p);
      expect(aware.chargeAh, closeTo(2 * 10 * 300 / 3600, 1e-9),
          reason: 'held to the next sample (5 min each)');
      final lt = foldLifetime(
          prior: const LifetimeTotals(),
          newRows: rows,
          ratedFullAh: 100,
          policy: p);
      expect(lt.chargeAh, closeTo(aware.chargeAh, 1e-9));
      expect(lt.aggregatedUpToMs, t0 + 3 * min5);
    });
  });

  group('logger: sample-mode tagging + the widened rule', () {
    test('sampleMode 0/1 and sampleIntervalS are written; a same-value '
        'reading one interval later EXTENDS the row', () {
      final log = BatteryLogger.custom();
      final c = BatteryConnection(transport: FakeTransport())
        ..state.serial = 'JS-A'
        ..state.packVoltage = 13.2;
      expect(log.sampleIntervalMs, 0);
      expect(log.currentGapMs, BatteryLogger.gapMs);
      log.observeConnection(c, nowMs: t0);
      log.observeConnection(c, nowMs: t0 + 1000);
      expect(log.hourSegments('JS-A', Metric.sampleMode).single.valueNum, 0);
      expect(log.hourSegments('JS-A', Metric.sampleIntervalS).single.valueNum, 0);
      // Background: 5-min interval.
      log.sampleIntervalMs = min5;
      expect(log.currentGapMs, min5 + sampleGapMarginMs);
      log.observeConnection(c, nowMs: t0 + 1000 + min5);
      log.observeConnection(c, nowMs: t0 + 1000 + 2 * min5);
      final modes = log.hourSegments('JS-A', Metric.sampleMode);
      expect(modes.map((r) => r.valueNum), [0, 1]);
      expect(modes.last.startMs, t0 + 1000 + min5);
      expect(modes.last.endMs, t0 + 1000 + 2 * min5,
          reason: 'extended across the expected gap, not split');
      expect(log.hourSegments('JS-A', Metric.sampleIntervalS).last.valueNum, 300);
      final v = log.hourSegments('JS-A', Metric.packVoltage);
      expect(v.length, 1, reason: 'unchanged voltage: ONE held row');
      expect(v.single.endMs, t0 + 1000 + 2 * min5);
      // Foreground again: continuous, the 10 s rule.
      log.sampleIntervalMs = 0;
      log.observeConnection(c, nowMs: t0 + 1000 + 2 * min5 + 120000);
      expect(log.hourSegments('JS-A', Metric.sampleMode).map((r) => r.valueNum),
          [0, 1, 0]);
      expect(log.hourSegments('JS-A', Metric.packVoltage).length, 2,
          reason: 'a 2 min gap under the 10 s rule opens a new row');
      final policy = GapPolicy(log.hourSegments('JS-A', Metric.sampleIntervalS));
      final rows = log.hourSegments('JS-A', Metric.packVoltage);
      expect(policy.abuts(rows.first.endMs, rows.last.startMs), isTrue,
          reason: 'but the chart bridges it: the gap was expected');
    });

    test('the metric keys are additive and byte-exact', () {
      expect(Metric.sampleMode, 'sampleMode');
      expect(Metric.sampleIntervalS, 'sampleIntervalS');
    });
  });

  group('manager: enter -> sample -> exit over a fake transport', () {
    test('full cycle: release, reconnect + capture one cycle + disconnect, '
        'failure backs off, foreground reconnects at once', () async {
      var clock = DateTime.utc(2026, 9, 20, 12);
      final t = FakeTransport();
      final m = BatteryManager(
        transport: t,
        now: () => clock,
        scanWindow: const Duration(milliseconds: 10),
        rescanInterval: const Duration(seconds: 100),
      );
      await m.startLive();
      final c = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'dev-1', profile: DeviceProfile.sphere);
      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(c.connState, ConnState.connected);
      expect(m.isSampling, isFalse);
      expect(m.sampleTargets.map((e) => e.$2), ['dev-1']);

      // Backgrounded: every pack released, nothing held.
      await m.enterSampling(const Duration(minutes: 5));
      expect(m.isSampling, isTrue);
      expect(c.connState, ConnState.disconnected);
      expect(t.lastLink!.disconnected, isTrue);
      expect(c.disconnectExpected, isTrue, reason: 'no alarm');
      expect(m.nextSampleDueMs, clock.millisecondsSinceEpoch + min5);
      expect(BatteryLogger.instance.sampleIntervalMs, min5);
      expect(c.maxIntegrateGapMs, min5 + sampleGapMarginMs);

      // A sample: connect, wait for one full cycle, disconnect.
      clock = clock.add(const Duration(minutes: 5));
      final sample = m.sampleOnce();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(c.connState, ConnState.connected);
      expect(t.connectCalls, 2);
      expect(c.cycleComplete, isFalse);
      for (final f in cycle.take(5)) {
        c.parser.addBytes(f);
      }
      expect(c.cycleComplete, isFalse, reason: 'SOC still missing');
      c.parser.addBytes(cycle.last);
      expect(c.cycleComplete, isTrue);
      expect(await sample, isTrue);
      expect(c.connState, ConnState.disconnected);
      expect(t.lastLink!.disconnected, isTrue);
      expect(m.scheduler.consecutiveFailures, 0);
      expect(m.scheduler.lastSuccessMs, clock.millisecondsSinceEpoch);
      expect(m.nextSampleDueMs, clock.millisecondsSinceEpoch + min5);
      expect(m.sampleInFlight, isFalse);

      // A failed sample: the connect backoff arms; the next tick within the
      // backoff does not even try; nothing retries early.
      clock = clock.add(const Duration(minutes: 5));
      t.failConnect = true;
      expect(await m.sampleOnce(), isFalse);
      expect(m.scheduler.consecutiveFailures, 1);
      expect(m.nextAttemptMsFor('dev-1'), isNotNull);
      expect(t.connectCalls, 3);
      t.failConnect = false;
      expect(await m.sampleOnce(), isFalse, reason: 'inside the backoff');
      expect(t.connectCalls, 3);

      // Foreground: continuous immediately (past the backoff).
      clock = clock.add(const Duration(minutes: 5));
      await m.exitSampling();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(m.isSampling, isFalse);
      expect(BatteryLogger.instance.sampleIntervalMs, 0);
      expect(c.maxIntegrateGapMs, 10000);
      expect(c.connState, ConnState.connected);
      expect(t.connectCalls, 4);
      m.stopLive();
      m.disposeAll();
    });

    test('a pause ends sampling without reconnecting; Continuous never '
        'samples', () async {
      final t = FakeTransport();
      final m = BatteryManager(transport: t);
      final c = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'dev-1', profile: DeviceProfile.sphere);
      await m.connectForTest(c, 'dev-1', 'JS-A');
      await m.enterSampling(Duration.zero);
      expect(m.isSampling, isFalse);
      expect(c.connState, ConnState.connected);
      await m.enterSampling(const Duration(minutes: 1));
      expect(m.isSampling, isTrue);
      await m.pauseLive();
      expect(m.isSampling, isFalse);
      expect(m.isPaused, isTrue);
      expect(c.connState, ConnState.disconnected);
      expect(BatteryLogger.instance.sampleIntervalMs, 0);
      m.disposeAll();
    });
  });
}
