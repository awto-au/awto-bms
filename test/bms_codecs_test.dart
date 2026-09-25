/// #75: read-only telemetry codecs for the non-JoySuny families.
///
/// Every frame here is a capture copied from patman15/aiobmsble's own tests
/// (test/bms_codec_fixtures.dart), and every expected value is the one that
/// project's tests assert for the same bytes. This proves the port matches the
/// reference decoder; it does NOT prove the reference matches a real pack.
library;

import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/bms_codecs.dart';
import 'package:battery_reader/bms_families.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bms_codec_fixtures.dart';

List<int> hx(String s) => [
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ];

/// Feed [bytes] in BLE-sized [chunk]s and collect every sample.
List<FamilySample> feed(BmsCodec c, List<int> bytes, {int chunk = 20}) => [
      for (var i = 0; i < bytes.length; i += chunk)
        ...c.addBytes(bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk)),
    ];

Matcher near(double v) => closeTo(v, 1e-6);

void main() {
  group('JBD', () {
    test('poll commands match the reference bytes', () {
      expect(JbdCodec.command(0x03), hx('dda50300fffd77'));
      expect(JbdCodec.command(0x04), hx('dda50400fffc77'));
    });

    test('info + cells decode to the reference values (20-byte chunks)', () {
      final c = JbdCodec();
      final s = [...feed(c, hx(jbdInfo)), ...feed(c, hx(jbdCells))];
      expect(s, hasLength(2));
      final info = s[0], cells = s[1];
      expect(info.voltage, near(15.6));
      expect(info.current, near(-2.87));
      expect(info.socPercent, 100);
      expect(info.remainingAh, near(4.98));
      expect(info.fullAh, 5);
      expect(info.cycles, 42);
      expect(info.problemCode, 0);
      expect(info.chargeMos, isTrue);
      expect(info.dischargeMos, isTrue);
      expect(info.temps!.map((t) => (t * 10).round()), [224, 223, 217]);
      expect(cells.cellsMv, [3430, 3425, 3432, 3417]);
    });

    test('leading garbage is skipped and a bad checksum is rejected', () {
      final c = JbdCodec();
      final bad = hx(jbdInfo)..[10] ^= 0xFF;
      expect(feed(c, [0x00, 0x77, ...bad]), isEmpty);
      expect(feed(c, [0x13, ...hx(jbdCells)]), hasLength(1));
    });
  });

  group('JK', () {
    test('cell-info command matches the reference layout', () {
      final cmd = JkCodec.command(0x96);
      expect(cmd, hasLength(20));
      expect(cmd.sublist(0, 6), hx('aa5590eb9600'));
      expect(cmd.last, cmd.sublist(0, 19).fold<int>(0, (a, b) => a + b) & 0xFF);
    });

    test('24S layout (fw 10.x)', () {
      final c = JkCodec();
      final dev = feed(c, hx(jk24sDev), chunk: 128);
      expect(c.swVersion, 10);
      expect(dev.single.firmware, '10.08');
      final s = feed(c, [...hx('41540d0a'), ...hx(jk24sCell)], chunk: 128).single;
      expect(s.voltage, near(52.971));
      expect(s.current, near(2.329));
      expect(s.socPercent, 56);
      expect(s.remainingAh, near(113.245));
      expect(s.fullAh, 202);
      expect(s.cycles, 60);
      expect(s.cellsMv, [3310, 3314, 3313, 3312, 3312, 3308, 3312, 3309, 3309, 3309, 3309, 3312, 3313, 3309, 3310, 3309]);
      expect(s.temps, [near(18.1), near(18.6)]);
      expect(s.mosTemp, near(22.8));
      expect(s.chargeMos, isTrue);
      expect(s.dischargeMos, isTrue);
      expect(s.problemCode, 0);
    });

    test('32S layout (fw 11.x)', () {
      final c = JkCodec();
      feed(c, hx(jk32sDev), chunk: 128);
      expect(c.swVersion, 11);
      final s = feed(c, hx(jk32sCell), chunk: 128).single;
      expect(s.voltage, near(26.509));
      expect(s.current, near(-7.063));
      expect(s.socPercent, 68);
      expect(s.remainingAh, near(142.464));
      expect(s.fullAh, 210);
      expect(s.cycles, 21);
      expect(s.cellsMv, [3315, 3315, 3315, 3312, 3313, 3312, 3313, 3313]);
      expect(s.temps, [near(28.4), near(29.2)]);
      expect(s.mosTemp, near(31.0));
    });

    test('32S layout (fw 15.x, six sensors)', () {
      final c = JkCodec();
      feed(c, hx(jk32sV15Dev), chunk: 128);
      final s = feed(c, hx(jk32sV15Cell), chunk: 128).single;
      expect(s.voltage, near(53.224));
      expect(s.current, near(31.881));
      expect(s.socPercent, 25);
      expect(s.cycles, 9);
      expect(s.cellsMv, hasLength(16));
      expect(s.temps, [near(13.4), near(12.8), near(19.5), near(19.1)]);
      expect(s.mosTemp, near(12.9));
    });

    test('a cell frame before device info is held back (layout unknown)', () {
      final c = JkCodec();
      expect(feed(c, hx(jk32sCell), chunk: 128), isEmpty);
      expect(c.pollCommands().first, JkCodec.command(0x97));
    });
  });

  group('ANT', () {
    test('status command matches the reference bytes', () {
      expect(AntCodec.command(0x01, 0x0000, 0xBE), hx('7ea1010000be1855aa55'));
    });

    test('status frame decodes to the reference values', () {
      final s = feed(AntCodec(), hx(antStatus)).single;
      expect(s.voltage, near(50.88));
      expect(s.current, near(2.1));
      expect(s.socPercent, 10);
      expect(s.remainingAh, near(9.957766));
      expect(s.fullAh, 80);
      expect(s.cellsMv, hasLength(22));
      expect(s.cellsMv!.take(3), [2334, 2331, 2334]);
      expect(s.temps, [29, 29, 29, 29]);
      expect(s.mosTemp, 30);
      expect(s.chargeMos, isTrue);
      expect(s.dischargeMos, isTrue);
      expect(s.problemCode, 0);
    });
  });

  group('Daly', () {
    test('Modbus commands match the reference bytes', () {
      expect(DalyCodec.command(0xD2, 0x00, 62), hx('d2030000003ed7b9'));
      expect(DalyCodec.command(0xD2, 0x3E, 9), hx('d203003e0009f7a3'));
      expect(DalyCodec.command(0x81, 0x00, 64), hx('8103000000405bfa'));
      expect(DalyCodec.command(0x81, 0x41, 62), hx('81030041003e8bce'));
    });

    test('an unknown pack is probed with both variants', () {
      expect(DalyCodec().pollCommands(),
          [hx('d2030000003ed7b9'), hx('8103000000405bfa')]);
    });

    test('D2 variant: main + MOS + info', () {
      final c = DalyCodec();
      final s = feed(c, hx(dalyD2Main)).single;
      expect(c.variant, DalyVariant.d2);
      expect(s.voltage, near(14.0));
      expect(s.current, near(3.0));
      expect(s.socPercent, near(90.0));
      expect(s.cycles, 57);
      expect(s.remainingAh, near(345.6));
      expect(s.cellsMv, [4127, 4137, 4147, 4157]);
      expect(s.temps, [20, 21, 22, 23]);
      expect(s.chargeMos, isFalse);
      expect(s.dischargeMos, isTrue);
      expect(feed(c, hx(dalyD2Mos)).single.mosTemp, 38);
      expect(feed(c, hx(dalyD2Info)).single.firmware, isNotEmpty);
    });

    test('0x81 variant: live + status', () {
      final c = DalyCodec();
      final live = feed(c, hx(dalyX81Live)).single;
      expect(c.variant, DalyVariant.x81);
      expect(live.voltage, near(13.0));
      expect(live.current, near(-0.8));
      expect(live.socPercent, near(11.2));
      expect(live.cellsMv, [3281, 3216, 3235, 3284]);
      expect(live.temps, [215, 215]);
      final st = feed(c, hx(dalyX81Status)).single;
      expect(st.remainingAh, near(20.1));
      expect(st.cycles, 0);
      expect(st.chargeMos, isTrue);
      expect(st.dischargeMos, isTrue);
      expect(c.pollCommands(), anyElement(equals(hx('81030041003e8bce'))));
    });
  });

  group('Redodo / LiTime', () {
    test('status frame decodes to the reference values', () {
      final c = RedodoCodec();
      expect(c.pollCommands().single, hx('000004011355aa17'));
      final s = feed(c, hx(redodoStatus)).single;
      expect(s.voltage, near(26.556));
      expect(s.current, near(-1.435));
      expect(s.socPercent, 65);
      expect(s.remainingAh, near(68.89));
      expect(s.fullAh, 105);
      expect(s.cycles, 3);
      expect(s.cellsMv, [3317, 3319, 3324, 3323, 3320, 3314, 3322, 3317]);
      expect(s.temps, [23, 22, -2]);
      expect(s.problemCode, 0);
    });

    test('a corrupted checksum is rejected', () {
      final bad = hx(redodoStatus)..[20] ^= 0x01; // a data byte, not the checksum
      expect(feed(RedodoCodec(), bad), isEmpty);
    });
  });

  group('Offgridtec SmartBat', () {
    // aiobmsble's mock: both names derive the key 0x10, and every reply is
    // ";BT<" + the request's two register bytes + the payload below.
    List<int> reply(List<int> cmd, String payloadHex) =>
        [...hx('3b42543c'), ...cmd.sublist(4, 6), ...hx(payloadHex)];

    test('the cipher key and command header follow the serial', () {
      final a = OgtCodec.forName('SmartBat-A12345');
      final b = OgtCodec.forName('SmartBat-B12294');
      expect(a.key, 0x10);
      expect(b.key, 0x10);
      expect(a.command(2, 1).sublist(0, 4), hx('3b425151'));
      expect(b.command(8, 2).sublist(0, 4), hx('3b422126'));
      expect(OgtCodec.forName('SmartBat-C12294').pollCommands(), isEmpty);
    });

    test('type A registers', () {
      final c = OgtCodec.forName('SmartBat-A12345');
      const payload = {
        2: '205520201d1a', 4: '2220202320511d1a', 8: '272152221d1a',
        12: '282520521d1a', 16: '2825565620201d1a', 44: '262320201d1a',
        60: '5228205220511d1a',
      };
      final merged = BatteryState();
      for (final cmd in c.pollCommands()) {
        final reg = int.parse(String.fromCharCodes(cmd.sublist(4, 6).map((b) => b ^ 0x10)), radix: 16);
        for (final s in c.addBytes(reply(cmd, payload[reg]!))) {
          s.applyTo(merged);
        }
      }
      expect(merged.socPercent, 14);
      expect(merged.remainingAh, near(8.0));
      expect(merged.packVoltage, near(45.681));
      expect(merged.tempA, 22); // 21.75 °C
      expect(merged.packCurrent, near(1.23));
      expect(merged.chargeState, ChargeState.discharging);
      expect(merged.cycleCount, 99);
      expect(merged.fullAh, 30);
    });

    test('type B registers and cells; Err ends the cell scan', () {
      final c = OgtCodec.forName('SmartBat-B12294');
      const payload = {
        8: '282520521d1a', 9: '272152221d1a', 10: '2752202020511d1a',
        13: '205520201d1a', 15: '2220202320511d1a', 23: '262320201d1a',
        24: '5228205220511d1a', 63: '555120531d1a', 62: '552920531d1a',
        61: '552820531d1a', 60: '552720531d1a',
      };
      final merged = BatteryState();
      for (final cmd in c.pollCommands()) {
        final reg = int.parse(String.fromCharCodes(cmd.sublist(4, 6).map((b) => b ^ 0x10)), radix: 16);
        final p = payload[reg];
        final bytes = p == null ? hx('3b42543c5562627f10') : reply(cmd, p);
        for (final s in c.addBytes(bytes)) {
          s.applyTo(merged);
        }
      }
      expect(merged.packVoltage, near(45.681));
      expect(merged.packCurrent, near(1.23));
      expect(merged.chargeState, ChargeState.charging);
      expect(merged.socPercent, 14);
      expect(merged.cycleCount, 99);
      // aiobmsble asserts 3.305 V for register 62 (its inline comment says 3.300).
      expect(merged.cellsMv, [3306, 3305, 3304, 3303]);
      // The first Err (register 59) fixed the cell count at 4.
      expect(c.pollCommands().length, 7 + 4);
    });
  });

  group('FamilySample.applyTo', () {
    test('signed current becomes magnitude + direction; cells give stats', () {
      final s = BatteryState();
      (FamilySample()
            ..voltage = 13.2
            ..current = -2.5
            ..cellsMv = [3300, 3310, 3290, 3300]
            ..temps = [21.4, 19.6]
            ..mosTemp = 30.2
            ..socPercent = 55.4
            ..chargeMos = true
            ..dischargeMos = false)
          .applyTo(s);
      expect(s.packCurrent, near(2.5));
      expect(s.chargeState, ChargeState.discharging);
      expect(s.status, ChargeState.discharging);
      expect(s.power, near(33.0));
      expect(s.cellMax, near(3.31));
      expect(s.cellMin, near(3.29));
      expect(s.cellDiff, near(0.02));
      expect(s.tempA, 21);
      expect(s.tempB, 20);
      expect(s.chipTemperature, 30);
      expect(s.socPercent, 55);
      expect(s.mosOn, isFalse);
    });

    test('a partial sample leaves the other fields alone', () {
      final s = BatteryState()..packVoltage = 12.0;
      (FamilySample()..cycles = 7).applyTo(s);
      expect(s.packVoltage, 12.0);
      expect(s.cycleCount, 7);
    });
  });

  group('codecForFamily', () {
    test('every recognised non-JoySuny family has a codec', () {
      for (final f in families.where((f) => !f.supported)) {
        final name = f.name.startsWith('LiFePO4') ? 'SmartBat-B12294' : '';
        final c = codecForFamily(f, name: name);
        expect(c, isNotNull, reason: f.name);
        expect(c!.serviceUuid, f.serviceUuid, reason: f.name);
        expect(f.notifyChars, contains(c.notifyUuid), reason: f.name);
        expect(f.writeChars, contains(c.writeUuid), reason: f.name);
      }
    });

    test('JoySuny keeps its own parser (no codec)', () {
      expect(codecForFamily(families.first), isNull);
    });
  });
}
