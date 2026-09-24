/// Pack card Status and Current, from REAL frames (#114 follow-up, #120).
///
/// #114: the row "Charge state" read "Idle" while a load drew 19 W. BAL s0
/// stays 0 ("idle") through low-current discharge on this firmware, so the
/// row is now "Status" and shows [BatteryState.status]: s0 corrected by the
/// ALL_DATA current / power and the load / charger flags.
///
/// #120: the offline card showed "Current 0.0 A" beside "Power 19 W". The
/// last-known snapshot stored the DIRECTION-SIGNED current, which was 0 while
/// s0 read idle; power was stored unsigned. Both came from the same A2 57
/// frame, which carries a consistent current and power.
///
/// Every frame below is quoted verbatim from the raw log in
/// logs/pull-20260924-1458/merged.db (phone, JS-2C14B8 unless noted). The
/// charger-flag rows are constructed from a real frame by setting byte p6:
/// no real frame in that data has the charger flag set while current flows.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/last_known.dart';
import 'package:battery_reader/metrics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

List<int> hex(String s) =>
    s.split(' ').map((b) => int.parse(b, radix: 16)).toList();

// BAL_STATUS s0 = 0 / 1 / 2 (real frames).
final bal0 = hex('a8 ac 00 01 01 00 01 00 00 b9 21');
final bal1 = hex('a8 ac 01 01 01 00 01 00 00 b9 21');
final bal2 = hex('a8 ac 02 01 01 00 01 00 00 b9 21');

/// 2026-09-21 13:20:13.409 — 1.433 A (raw 1433), 19.2 W, 13.4 V, load = 1.
/// The BAL frames either side (13:20:12.748, 13:20:13.586) both read s0 = 0.
final a19w = hex('a2 57 86 00 99 05 00 01 00 00 86 00 25 0d 23 0d 01 00 '
    'c0 00 00 00 24 0d b3 6c');

/// 2026-09-21 13:16:03.313 — 0 A, 0 W, load = 1 (a load attached, idle).
final aZeroLoad = hex('a2 57 8a 00 00 00 00 01 00 00 8a 00 85 0d 80 0d 04 00 '
    '00 00 00 00 82 0d b3 6c');

/// JS-2C14AA 2026-09-19 20:38:47.142 — 0 A, 0 W, no flags.
final aZero = hex('a2 57 85 00 00 00 00 00 00 00 85 00 07 0d 05 0d 02 00 '
    '00 00 00 00 06 0d b3 6c');

/// 2026-09-21 13:19:48.131 — 86.183 A, 1166.5 W, load = 1, with s0 = 2.
final aHeavy = hex('a2 57 87 00 a7 50 01 01 00 00 87 00 3e 0d 32 0d 0c 00 '
    '91 2d 00 00 37 0d b3 6c');

/// 2026-09-21 10:27:11.144 — 13.816 A, 191.5 W, load = charger = 0 (real
/// charging; s0 = 1 from 10:27:11.393, the BAL before it read 0).
final aNoFlags = hex('a2 57 8a 00 f8 35 00 00 00 00 8a 00 8f 0d 85 0d 09 00 '
    '7b 07 00 00 8a 0d b3 6c');

/// [aNoFlags] with the charger flag p6 set (constructed, see library note).
final aChargerFlag = [...aNoFlags]..[8] = 1;

/// Decode [frames] into a fresh state.
BatteryState decode(List<List<int>> frames, [BatteryState? into]) {
  final p = BatteryParser(state: into);
  for (final f in frames) {
    p.addBytes(f);
  }
  return p.state;
}

void main() {
  group('#114 Status truth table (real frames)', () {
    final cases = <(String, List<List<int>>, ChargeState, String)>[
      ('no frames', [], ChargeState.unknown, '—'),
      ('BAL only, s0 = 0', [bal0], ChargeState.idle, 'Idle'),
      ('BAL only, s0 = 2', [bal2], ChargeState.discharging, 'Discharging'),
      ('0 A, no flags, s0 = 0', [bal0, aZero], ChargeState.idle, 'Idle'),
      ('0 A, load on, s0 = 0', [bal0, aZeroLoad], ChargeState.idle, 'Idle'),
      // s0 lags the current: 2 on a 0 A frame (15:05:38.932) — nothing flows.
      ('0 A, load on, s0 = 2', [bal2, aZeroLoad], ChargeState.idle, 'Idle'),
      // THE #114 case: 1.4 A / 19 W out, load on, BMS still says s0 = 0.
      (
        '1.4 A, load on, s0 = 0',
        [bal0, a19w],
        ChargeState.discharging,
        'Discharging'
      ),
      (
        '86 A, load on, s0 = 2',
        [bal2, aHeavy],
        ChargeState.discharging,
        'Discharging'
      ),
      (
        '13.8 A, no flags, s0 = 1',
        [bal1, aNoFlags],
        ChargeState.charging,
        'Charging'
      ),
      // s0 wins over the flags when it gives a direction.
      (
        '1.4 A, load on, s0 = 1',
        [bal1, a19w],
        ChargeState.charging,
        'Charging'
      ),
      (
        '13.8 A, charger on, s0 = 0',
        [bal0, aChargerFlag],
        ChargeState.charging,
        'Charging'
      ),
      // Flow with no direction reported: never "Idle", never "0.0 A".
      (
        '13.8 A, no flags, s0 = 0',
        [bal0, aNoFlags],
        ChargeState.unknown,
        'Active'
      ),
      ('13.8 A, no flags, no BAL', [aNoFlags], ChargeState.unknown, 'Active'),
    ];
    for (final (name, frames, want, text) in cases) {
      test(name, () {
        final s = decode(frames);
        expect(s.status, want);
        expect(statusText(s), text);
      });
    }

    test('the raw s0 byte is kept verbatim (flags / alarm rows record it)', () {
      final s = decode([bal0, a19w]);
      expect(s.chargeState, ChargeState.idle);
      expect(s.status, ChargeState.discharging);
    });

    test('the Pack row is labelled "Status"', () {
      expect(metricDef(Metric.displayChargeState)!.labelOnDetail, 'Status');
      expect(
          metricTable.where((m) => m.labelOnDetail == 'Charge state'), isEmpty);
    });
  });

  group('#120 current and power agree (real 19 W frame)', () {
    BatteryConnection conn() {
      final c = BatteryConnection(transport: FakeTransport());
      decode([bal0, a19w], c.state);
      return c;
    }

    test('one A2 57 frame carries both; P / V matches I within 0.1 A', () {
      final s = decode([bal0, a19w]);
      expect(s.packVoltage, 13.4);
      expect(s.packCurrent, 1.4); // raw 1433 mA, truncated to 0.1 A
      expect(s.power, 19.2);
      expect(s.loadConnected, isTrue);
      // The vendor's truncating ÷100 then ÷10 costs < 0.1 A; P / V = 1.43 A.
      expect((s.power! / s.packVoltage! - s.packCurrent!).abs(), lessThan(0.1));
    });

    test('live: signed current and power are both "out", neither 0', () {
      final c = conn();
      expect(c.signedCurrent, -1.4);
      expect(c.signedPower, -19.2);
      expect(metricDef(Metric.packCurrent)!.format(c), '-1.4 A out');
      final pack = {
        for (final m in detailMetrics(DetailSection.pack))
          m.labelOnDetail: m.detailValue(c),
      };
      expect(pack['Current'], '1.4 A');
      expect(pack['Power'], '19 W');
      expect(pack['Status'], 'Discharging');
      expect(pack['Load'], 'On');
    });

    test('last-known: the snapshot restores 1.4 A beside 19 W, not 0.0 A', () {
      final c = conn();
      final k = LastKnownState.capture(c.state, signedCurrent: c.signedCurrent);
      expect(k.packCurrent, -1.4);
      final back = LastKnownState.fromJson(k.toJson());
      final placeholder = BatteryConnection(transport: FakeTransport());
      back.applyTo(placeholder.state);
      expect(placeholder.state.packCurrent, 1.4);
      expect(placeholder.state.power, 19.2);
      expect(placeholder.state.status, ChargeState.discharging);
      expect(placeholder.signedCurrent, -1.4);
    });

    test('flow with no direction: the snapshot keeps the magnitude', () {
      final s = decode([bal0, aNoFlags]);
      final k = LastKnownState.capture(s, signedCurrent: 0);
      expect(k.packCurrent, 13.8);
      final c = BatteryConnection(transport: FakeTransport());
      decode([bal0, aNoFlags], c.state);
      expect(c.signedCurrentOrNull, isNull, reason: 'never "0.0 A" here');
    });

    test('a pre-fix record (0 A beside 19 W) restores no current, not 0.0 A',
        () {
      // What the old capture wrote for the 19 W frame: s0 idle -> signed 0.
      final legacy = LastKnownState.fromJson({
        'packV': 13.4,
        'packI': 0.0,
        'power': 19.2,
        'chargeState': 'idle',
        'load': true,
        'charger': false,
      });
      final c = BatteryConnection(transport: FakeTransport());
      legacy.applyTo(c.state);
      expect(c.state.packCurrent, isNull);
      expect(c.state.power, 19.2);
      expect(c.state.status, ChargeState.discharging);
      expect(metricDef(Metric.packCurrent)!.detailValue(c), '—');
      expect(c.signedPower, -19.2);
    });

    test('a genuine idle record (0 A, 0 W) still restores 0.0 A', () {
      final k = LastKnownState.fromJson(
          {'packI': 0.0, 'power': 0.0, 'chargeState': 'idle', 'load': true});
      final s = BatteryState();
      k.applyTo(s);
      expect(s.packCurrent, 0.0);
      expect(s.status, ChargeState.idle);
    });
  });
}
