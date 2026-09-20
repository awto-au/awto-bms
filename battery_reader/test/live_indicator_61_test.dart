/// GitHub #61: the per-battery live-update indicator — live / stale / silent
/// at a glance, ticking with each decoded cycle, tied to the not-streaming
/// watchdog + the #62 verdict, and "sampled … · next in …" in background
/// sampling mode (#53). Plus the frame counter / last-frame age rows.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/fmt.dart';
import 'package:battery_reader/live_indicator.dart';
import 'package:battery_reader/metrics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const bal = [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21];

void main() {
  group('fmtAgeShort', () {
    test('sub-10 s with a decimal, then whole units', () {
      expect(fmtAgeShort(400), '0.4 s');
      expect(fmtAgeShort(9999), '10.0 s');
      expect(fmtAgeShort(12000), '12 s');
      expect(fmtAgeShort(120000), '2 min');
      expect(fmtAgeShort(3900000), '1 h 05 min');
      expect(fmtAgeShort(3 * 86400000), '3 d');
      expect(fmtAgeShort(-5), '0.0 s');
    });
  });

  group('liveStatusFor — the pure decision', () {
    LiveStatus at(int silence, {StreamClass cls = StreamClass.unknown}) =>
        liveStatusFor(
            conn: ConnState.connected,
            silenceMs: silence,
            nowMs: 0,
            streamClass: cls);

    test('live under 3 s, amber to 10 s, red "not streaming" from 10 s', () {
      expect(at(400), const LiveStatus(LiveLevel.live, 'live · updated 0.4 s ago'));
      expect(at(2999).level, LiveLevel.live);
      expect(at(3000), const LiveStatus(LiveLevel.stale, 'updated 3.0 s ago'));
      expect(at(9999).level, LiveLevel.stale);
      expect(at(10000), const LiveStatus(LiveLevel.silent, 'not streaming · 10 s silent'));
      expect(at(10000).level, LiveLevel.silent);
      expect(staleMs, 3000);
      expect(BatteryConnection.notStreamingMs, 10000);
    });

    test('silent text carries the #62 verdict; #63: no reply reads like '
        'dormant (same text, level and colour)', () {
      final dormant = at(15000, cls: StreamClass.dormant);
      final noReply = at(15000, cls: StreamClass.noResponse);
      expect(dormant.text, 'not streaming · BMS not running');
      expect(noReply, dormant);
      expect(dormant.level, LiveLevel.silent);
      expect(noReply.color, dormant.color);
      expect(at(15000, cls: StreamClass.awakeNotStreaming).text,
          'not streaming · ${BatteryConnection.awakeNotStreamingState}');
      expect(at(15000, cls: StreamClass.awakeNotStreaming).level,
          LiveLevel.silent);
    });

    test('a fresh link with no frame yet is stale ("waiting"), not live', () {
      final s = liveStatusFor(
          conn: ConnState.connected,
          silenceMs: 1000,
          nowMs: 0,
          hasFrameOnLink: false);
      expect(s.level, LiveLevel.stale);
      expect(s.text, contains('waiting for the first frame'));
    });

    test('connecting / not connected', () {
      expect(liveStatusFor(conn: ConnState.connecting, silenceMs: null, nowMs: 0),
          const LiveStatus(LiveLevel.connecting, 'connecting…'));
      expect(liveStatusFor(conn: ConnState.disconnected, silenceMs: null, nowMs: 0),
          const LiveStatus(LiveLevel.offline, 'not connected'));
    });

    test('background sampling: "sampled 2 min ago · next in 3 min"', () {
      const now = 10000000;
      final s = liveStatusFor(
        conn: ConnState.disconnected,
        silenceMs: null,
        nowMs: now,
        sampling: true,
        lastFrameEverMs: now - 120000,
        nextDueMs: now + 180000,
      );
      expect(s, const LiveStatus(LiveLevel.sampled, 'sampled 2 min ago · next in 3 min'));
      expect(
          liveStatusFor(
            conn: ConnState.disconnected,
            silenceMs: null,
            nowMs: now,
            sampling: true,
            lastFrameEverMs: null,
            nextDueMs: now - 1,
          ).text,
          'not sampled yet · sampling now');
      // Mid-sample (connected) the normal live rules apply.
      expect(
          liveStatusFor(
            conn: ConnState.connected,
            silenceMs: 500,
            nowMs: now,
            sampling: true,
          ).level,
          LiveLevel.live);
    });

    test('colours: green / amber / red / muted', () {
      expect(at(0).color, isNot(equals(at(5000).color)));
      expect(at(5000).color, isNot(equals(at(20000).color)));
      expect(at(20000).color, isNot(equals(at(0).color)));
    });
  });

  group('liveStatusOf over a real connection + the frame rows', () {
    test('ticks with each decoded frame; frame counter and last-frame age',
        () async {
      var clock = DateTime.utc(2026, 9, 20, 12);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, now: () => clock);
      final frames = metricDef(Metric.displayFrames)!;
      final last = metricDef(Metric.displayLastFrame)!;
      expect(liveStatusOf(c).level, LiveLevel.offline);
      expect(frames.detailValue(c), '—');
      expect(last.detailValue(c), '—');
      await c.connectTo('dev-1', name: 'JS-A');
      clock = clock.add(const Duration(seconds: 1));
      expect(liveStatusOf(c).level, LiveLevel.stale, reason: 'no frame yet');
      expect(last.detailValue(c), contains('none yet'));
      c.parser.addBytes(bal);
      expect(c.frameCount, 1);
      expect(liveStatusOf(c), const LiveStatus(LiveLevel.live, 'live · updated 0.0 s ago'));
      expect(frames.detailValue(c), '1');
      expect(last.detailValue(c), '0.0 s ago');
      clock = clock.add(const Duration(milliseconds: 400));
      expect(liveStatusOf(c).text, 'live · updated 0.4 s ago');
      clock = clock.add(const Duration(seconds: 5));
      expect(liveStatusOf(c).level, LiveLevel.stale);
      clock = clock.add(const Duration(seconds: 5));
      expect(liveStatusOf(c).level, LiveLevel.silent);
      expect(liveStatusOf(c).text, 'not streaming · 10 s silent');
      c.streamClass = StreamClass.dormant;
      expect(liveStatusOf(c).text,
          'not streaming · ${BatteryConnection.bmsNotRunningState}');
      expect(c.gateStatusSummary(), contains('frames 1'));
      expect(c.gateStatusSummary(), contains('last frame 10 s ago'));
      expect(c.gateStatusSummary(), contains('stream dormant'));
      // #63: the same indicator text without the 0x30; Diagnostics differs.
      c.streamClass = StreamClass.noResponse;
      expect(liveStatusOf(c).text,
          'not streaming · ${BatteryConnection.bmsNotRunningState}');
      expect(c.gateStatusSummary(), contains('stream noResponse'));
      // Sampling mode (released): the sample ages instead.
      await c.disconnect();
      final now = clock.millisecondsSinceEpoch;
      expect(
          liveStatusOf(c, sampling: true, nextDueMs: now + 60000).text,
          'sampled 10 s ago · next in 1 min');
    });
  });
}
