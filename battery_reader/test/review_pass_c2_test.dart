import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/alert_notifications.dart';
import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_charts.dart' show sameIntervals;
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/ble_transport.dart' show discoveryRetryDelay;
import 'package:battery_reader/bms_families.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/fmt.dart';
import 'package:battery_reader/main.dart' show listPageSignature;
import 'package:battery_reader/raw_log.dart';

import 'fakes.dart';

/// Review-fix Pass C2 (GitHub #51): the remaining LOW items + the shared
/// formatters.
///
///  * L8  — the rolling hour buffer folds INCREMENTALLY (bit-identical to a
///          re-fold of the raw points, including the hour cutoff and the size
///          cap) and keeps its snapshot identity until the next reading;
///          `sameIntervals` is the charts' cheap change check.
///  * L12 — detected other-family devices are pruned after 3 unseen scans.
///  * L13 — no sleep after the final failed discovery attempt.
///  * L14 — notification ids use FNV-1a, stable across Dart SDK upgrades.
///  * L16 — the list page's render signature only changes when something it
///          shows changes.
///  * fmt — one stamp / hex / unit formatter set, delegated to everywhere.
void main() {
  group('L8: incremental hour buffer == buildIntervals over the raw points',
      () {
    List<(int, int, double?)> shape(List<ReadingInterval> ivs) =>
        [for (final iv in ivs) (iv.startMs, iv.endMs, iv.valueNum)];

    /// Feed [obs] through a memory-only logger as `soc` readings and return
    /// what `hourSegments` reports afterwards.
    List<ReadingInterval> viaLogger(List<Obs> obs) {
      final log = BatteryLogger.custom();
      final c = BatteryConnection(transport: NoopTransport())
        ..state.serial = 'JS-H';
      for (final o in obs) {
        c.state.socPercent = o.value?.toInt();
        log.observeConnection(c, nowMs: o.ms);
      }
      return log.hourSegments('JS-H', Metric.soc);
    }

    test('extend / change / gap match the pure fold exactly', () {
      final obs = <Obs>[
        const Obs(0, value: 50),
        const Obs(1000, value: 50), // extend
        const Obs(2000, value: 51), // change
        const Obs(3000, value: 51),
        const Obs(20000, value: 51), // gap > 10 s: new run, same value
        const Obs(21000, value: 52),
      ];
      expect(shape(viaLogger(obs)),
          shape(buildIntervals(obs, gapMs: BatteryLogger.gapMs)));
      expect(viaLogger(obs).length, 4);
    });

    test('the hour cutoff drops whole runs AND trims the straddling run to '
        'the first surviving reading', () {
      const h = BatteryLogger.hourMs;
      final obs = <Obs>[
        for (var k = 0; k < 6; k++) Obs(k * 1000, value: 1),
        const Obs(h + 2500, value: 1), // now: cutoff = 2500
      ];
      final got = viaLogger(obs);
      final expected = buildIntervals(
          obs.where((o) => o.ms >= h + 2500 - h).toList(),
          gapMs: BatteryLogger.gapMs);
      expect(shape(got), shape(expected));
      expect(shape(got), [(3000, 5000, 1.0), (h + 2500, h + 2500, 1.0)]);

      // A run that is entirely older than an hour is gone.
      final old = <Obs>[
        const Obs(0, value: 7),
        const Obs(1000, value: 7),
        const Obs(h + 100000, value: 7),
      ];
      expect(shape(viaLogger(old)), [(h + 100000, h + 100000, 7.0)]);
    });

    test('the 8000-point cap trims from the front exactly like the raw list',
        () {
      // 8100 readings, 100 ms apart, the value changing every 3 samples.
      final obs = [
        for (var i = 0; i < 8100; i++) Obs(i * 100, value: (i ~/ 3) % 50),
      ];
      final got = viaLogger(obs);
      // Only the last 8000 raw points survive; the fold over them is the
      // expected shape — the first surviving run starts mid-run at point 100.
      final expected =
          buildIntervals(obs.sublist(100), gapMs: BatteryLogger.gapMs);
      expect(shape(got), shape(expected));
      expect(got.first.startMs, 100 * 100);
    });

    test('the snapshot keeps its identity until the next reading', () {
      final log = BatteryLogger.custom();
      final c = BatteryConnection(transport: NoopTransport())
        ..state.serial = 'JS-I'
        ..state.socPercent = 5;
      log.observeConnection(c, nowMs: 1000);
      final a = log.hourSegments('JS-I', Metric.soc);
      final b = log.hourSegments('JS-I', Metric.soc);
      expect(identical(a, b), isTrue, reason: 'no push in between');
      log.observeConnection(c, nowMs: 2000);
      final d = log.hourSegments('JS-I', Metric.soc);
      expect(identical(a, d), isFalse);
      expect(d.single.endMs, 2000);
      expect(a.single.endMs, 1000, reason: 'the old snapshot is immutable');
      expect(() => d.add(d.first), throwsUnsupportedError);
    });

    test('sameIntervals: identity, then per-row identity-or-value', () {
      ReadingInterval iv(int s, int e, double v) =>
          ReadingInterval(startMs: s, endMs: e, valueNum: v);
      final body = [iv(0, 1000, 1), iv(1000, 2000, 2)];
      final a = [...body, iv(2000, 3000, 3)];
      final b = [...body, iv(2000, 3000, 3)]; // tail rebuilt, same values
      final c = [...body, iv(2000, 3500, 3)]; // tail grew
      expect(sameIntervals(a, a), isTrue);
      expect(sameIntervals(a, b), isTrue);
      expect(sameIntervals(a, c), isFalse);
      expect(sameIntervals(a, body), isFalse);
      expect(sameIntervals(const [], const []), isTrue);
    });
  });

  group('L12: detected other-family devices are pruned when not re-sighted', () {
    DetectedDevice dev(String id, int seen) => DetectedDevice(
        deviceId: id, family: families[1], name: 'JBD-$id', rssi: -70,
        lastSeenScan: seen);

    test('a device unseen for 3 scan windows is dropped; a re-sighted one '
        'stays', () {
      final m = BatteryManager();
      m.detectedOthers.addAll([dev('old', 0), dev('fresh', 3)]);
      m.scanGeneration = 3;
      m.pruneStaleDetected();
      expect(m.detectedOthers.map((d) => d.deviceId), ['fresh']);
      m.scanGeneration = 5; // fresh last seen at 3: 2 windows unseen -> kept
      m.pruneStaleDetected();
      expect(m.detectedOthers.map((d) => d.deviceId), ['fresh']);
      m.scanGeneration = 6; // 3 windows unseen -> pruned
      m.pruneStaleDetected();
      expect(m.detectedOthers, isEmpty);
      expect(BatteryManager.detectedStaleScans, 3);
    });

    test('a completed scan window ages the cards; a pruned device can be '
        're-detected', () async {
      final t = NoopTransport();
      final m = BatteryManager(
          transport: t,
          scanWindow: const Duration(milliseconds: 5),
          rescanInterval: const Duration(hours: 1));
      await m.startLive(); // one scan window -> generation 1
      expect(m.scanGeneration, 1);
      m.detectedOthers.add(dev('x', 0)); // sighted during scan 0
      await m.scanOnceForTest(); // scan 1: 1 window unseen -> kept
      await m.scanOnceForTest(); // scan 2: 2 windows unseen -> kept
      expect(m.scanGeneration, 3);
      expect(m.detectedOthers.length, 1);
      await m.scanOnceForTest(); // scan 3: 3 windows unseen -> pruned
      expect(m.scanGeneration, 4);
      expect(m.detectedOthers, isEmpty);
      // A failed scan neither ages nor prunes.
      m.detectedOthers.add(dev('y', 4));
      t.scanError = StateError('adapter off');
      await m.scanOnceForTest();
      expect(m.scanGeneration, 4);
      expect(m.detectedOthers.length, 1);
      m.stopLive();
      m.disposeAll();
    });
  });

  group('L13: discovery retry delays', () {
    test('200/400/600/800 ms between five attempts, none after the last', () {
      expect(discoveryRetryDelay(0), const Duration(milliseconds: 200));
      expect(discoveryRetryDelay(1), const Duration(milliseconds: 400));
      expect(discoveryRetryDelay(2), const Duration(milliseconds: 600));
      expect(discoveryRetryDelay(3), const Duration(milliseconds: 800));
      expect(discoveryRetryDelay(4), isNull, reason: 'throw immediately');
      expect(discoveryRetryDelay(0, attempts: 1), isNull);
    });
  });

  group('L14: FNV-1a notification ids', () {
    test('matches the published 32-bit FNV-1a vectors', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(fnv1a32('foobar'), 0xbf9cf968);
    });

    test('ids are the masked FNV-1a of "serial|condition": stable, positive, '
        'distinct', () {
      expect(notificationIdFor('JS-1', AlertCondition.fault),
          fnv1a32('JS-1|fault') & 0x7fffffff);
      expect(notificationIdFor('JS-1', AlertCondition.disconnect),
          fnv1a32('JS-1|disconnect') & 0x7fffffff);
      final ids = {
        notificationIdFor('JS-1', AlertCondition.fault),
        notificationIdFor('JS-1', AlertCondition.unknownChange),
        notificationIdFor('JS-1', AlertCondition.disconnect),
        notificationIdFor('JS-2', AlertCondition.fault),
      };
      expect(ids.length, 4);
      expect(ids.every((i) => i >= 0), isTrue);
    });
  });

  group('L16: the list page repaints only when something shown changed', () {
    BatteryConnection make(String serial, {int soc = 50}) {
      final c = BatteryConnection(transport: NoopTransport());
      c.state
        ..serial = serial
        ..socPercent = soc
        ..fullAh = 100
        ..remainingAh = soc.toDouble()
        ..packVoltage = 13.2;
      c.connState = ConnState.connected;
      return c;
    }

    test('identical state -> identical signature; a shown value -> differs',
        () {
      final m = BatteryManager();
      final a = make('JS-A');
      m.batteries.add(a);
      m.setInFleet(a, true);
      final aliases = AliasStore();
      final s1 = listPageSignature(m, aliases, demoMode: false, nowMs: 1000);
      final s2 = listPageSignature(m, aliases, demoMode: false, nowMs: 1000);
      expect(listEquals(s1, s2), isTrue);

      a.state.socPercent = 51;
      final s3 = listPageSignature(m, aliases, demoMode: false, nowMs: 1000);
      expect(listEquals(s1, s3), isFalse, reason: 'SOC % is shown');

      a.state.socPercent = 50;
      a.alarmActive = true;
      expect(
          listEquals(s1,
              listPageSignature(m, aliases, demoMode: false, nowMs: 1000)),
          isFalse,
          reason: 'the alarm border/colour is shown');
      a.alarmActive = false;
      expect(
          listEquals(s1,
              listPageSignature(m, aliases, demoMode: false, nowMs: 1000)),
          isTrue,
          reason: 'back to the painted state');
    });

    test('an offline favourite\'s "last seen" text ages the signature', () {
      final m = BatteryManager();
      final a = make('JS-A')
        ..isRemembered = true
        ..connState = ConnState.disconnected
        ..lastSeenMs = 5000;
      m.batteries.add(a);
      final aliases = AliasStore();
      final now = listPageSignature(m, aliases, demoMode: false, nowMs: 10000);
      final later = listPageSignature(m, aliases,
          demoMode: false, nowMs: 10000 + 5 * 60 * 1000);
      expect(listEquals(now, later), isFalse,
          reason: '"just now" became "5 min ago"');
      expect(relativeTime(5000, nowMs: 10000), 'just now');
      expect(relativeTime(5000, nowMs: 10000 + 5 * 60 * 1000), '5 min ago');
    });

    test('detected cards and the fleet lock reason are part of it', () {
      final m = BatteryManager();
      final aliases = AliasStore();
      final s1 = listPageSignature(m, aliases, demoMode: false);
      m.detectedOthers.add(DetectedDevice(
          deviceId: 'd', family: families[1], name: 'JBD-1', rssi: -70));
      final s2 = listPageSignature(m, aliases, demoMode: false);
      expect(listEquals(s1, s2), isFalse);
      expect(
          listEquals(s2, listPageSignature(m, aliases, demoMode: true)), isFalse);
    });
  });

  group('fmt: the shared formatters', () {
    test('fmtStamp is the one zero-padded stamp every log uses', () {
      final d = DateTime(2026, 1, 2, 3, 4, 5, 7);
      expect(fmtStamp(d), '2026-01-02 03:04:05.007');
      expect(fmtStampMs(d.millisecondsSinceEpoch), fmtStamp(d));
      expect(BatteryLogger.fmtTime(d.millisecondsSinceEpoch), fmtStamp(d));
      expect(RawLogger.fmtTime(d), fmtStamp(d));
      expect(AppLogEntry.fmtStamp(d), fmtStamp(d));
    });

    test('hexOf is shared by the raw log and the connection console line', () {
      expect(hexOf([0x00, 0xFF, 0x30, 0x9]), '00 ff 30 09');
      expect(RawLogger.hexOf([0xA2, 0x57]), 'a2 57');
      expect(BatteryConnection.hex([0xA2, 0x57]), 'a2 57');
      expect(hexOf(const []), '');
    });

    test('chart tick / axis labels', () {
      final t = DateTime(2026, 9, 20, 14, 5).millisecondsSinceEpoch;
      expect(fmtTick(t, 3600 * 1000), '14:05');
      expect(fmtTick(t, 3 * 24 * 3600 * 1000), '20/9');
      expect(fmtAxis(123.456), '123');
      expect(fmtAxis(12.345), '12.3');
      expect(fmtAxis(1.2345), '1.23');
      expect(fmtAxis(-0.5), '-0.50');
      expect(pad(7), '07');
      expect(pad(7, 3), '007');
    });

    test('unit formatters', () {
      expect(fPct(93), '93%');
      expect(fV(13.256), '13.26 V');
      expect(fA(12.34), '12.3 A');
      expect(fAh(87.06), '87.1 Ah');
      expect(fW(164.6), '165 W');
      expect(fBool(true), 'On');
      expect(fBool(false), 'Off');
      expect(fTime(3661), '01:01:01');
      expect(fRssi(-61), '-61 dBm');
      expect(fCycles(1.234), '1.23');
      for (final s in [fPct(null), fV(null), fA(null), fAh(null), fW(null),
          fBool(null), fTime(null), fRssi(null), fCycles(null)]) {
        expect(s, '—');
      }
    });

    test('relativeTime', () {
      expect(relativeTime(null), 'unknown');
      expect(relativeTime(0), 'unknown');
      expect(relativeTime(5000, nowMs: 4000), 'just now');
      expect(relativeTime(1000, nowMs: 1000 + 44 * 1000), 'just now');
      expect(relativeTime(1000, nowMs: 1000 + 90 * 1000), '1 min ago');
      expect(relativeTime(1000, nowMs: 1000 + 3 * 3600 * 1000), '3 h ago');
      expect(relativeTime(1000, nowMs: 1000 + 50 * 3600 * 1000), '2 d ago');
    });
  });
}
