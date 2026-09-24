import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_protocol.dart';

/// Pass 10 write frames: the SAFETY-CRITICAL capacity write (#38), the sleep
/// ON/OFF command bytes (#42), and the heat-up gate builder (only the heat byte
/// flips). Frames verified against the vendor apps; all little-endian.
void main() {
  // Decode the 3 little-endian payload bytes of a capacity frame back to mAh.
  int mahOf(List<int> f) => f[2] | (f[3] << 8) | (f[4] << 16);

  group('#38 capacity write (CMD_BATTERY)', () {
    test('100 Ah -> C5 60 A0 86 01 D6 2A (exact bytes)', () {
      expect(buildCapacityWriteFrame(100),
          [0xC5, 0x60, 0xA0, 0x86, 0x01, 0xD6, 0x2A]);
    });

    test('frame is begin C5 60 + 3 payload bytes + end D6 2A (7 bytes)', () {
      final f = buildCapacityWriteFrame(100);
      expect(f.length, 7);
      expect(f.sublist(0, 2), [0xC5, 0x60]); // CapacityWrite.begin
      expect(f.sublist(5), [0xD6, 0x2A]); // CapacityWrite.end
      expect(CapacityWrite.begin, [0xC5, 0x60]);
      expect(CapacityWrite.end, [0xD6, 0x2A]);
      expect(CapacityWrite.ackType, 4);
    });

    test('payload is (Ah * 1000) as 24-bit little-endian mAh — round-trip', () {
      for (final ah in [1.0, 50.0, 100.0, 200.0, 280.5, 512.0, 1000.0]) {
        final f = buildCapacityWriteFrame(ah);
        expect(f.sublist(0, 2), [0xC5, 0x60]);
        expect(f.sublist(5), [0xD6, 0x2A]);
        expect(mahOf(f), (ah * 1000).round(),
            reason: '$ah Ah should encode to ${(ah * 1000).round()} mAh');
      }
    });

    test('200 Ah encodes to 200000 mAh = 0x030D40 -> 40 0D 03', () {
      final f = buildCapacityWriteFrame(200);
      expect(f, [0xC5, 0x60, 0x40, 0x0D, 0x03, 0xD6, 0x2A]);
    });

    test('rejects out-of-range / non-finite capacities (no write is built)', () {
      expect(() => buildCapacityWriteFrame(0), throwsArgumentError);
      expect(() => buildCapacityWriteFrame(0.5), throwsArgumentError);
      expect(() => buildCapacityWriteFrame(1000.1), throwsArgumentError);
      expect(() => buildCapacityWriteFrame(-5), throwsArgumentError);
      expect(() => buildCapacityWriteFrame(double.nan), throwsArgumentError);
      expect(() => buildCapacityWriteFrame(double.infinity), throwsArgumentError);
    });

    test('the type-4 SETTING_RESPOND ack is the read-back', () {
      final state = BatteryState();
      final parser = BatteryParser(state: state);
      parser.addBytes([0xAB, 0xBA, CapacityWrite.ackType, 0xCD, 0xDC]);
      expect(state.capacityWriteAck, isTrue);
    });
  });

  group('#42 sleep ON/OFF command bytes', () {
    test('sleep ON = AA CC 00 01 DD EE (00 byte = sleep on)', () {
      expect(BatteryCommands.openSleep, [0xAA, 0xCC, 0x00, 0x01, 0xDD, 0xEE]);
    });

    test('sleep OFF / wake = AA CC 01 01 DD EE', () {
      expect(BatteryCommands.closeSleep, [0xAA, 0xCC, 0x01, 0x01, 0xDD, 0xEE]);
    });

    test('SLEEP_SET_SUCCESS decodes byte0==0 as asleep, else awake', () {
      final state = BatteryState();
      final parser = BatteryParser(state: state);
      parser.addBytes([0xAC, 0xCA, 0x00, 0xDE, 0xED]);
      expect(state.sleepModeOn, isTrue);
      parser.addBytes([0xAC, 0xCA, 0x01, 0xDE, 0xED]);
      expect(state.sleepModeOn, isFalse);
    });
  });

  group('#42 heat-up gate builder (only the heat byte flips)', () {
    // A base with a mix of gates so a clobbered byte would be visible.
    const base = GateSnapshot(
      chargeMos: true,
      dischargeMos: true,
      tempControlGate: 1,
      smokeGate: 1,
      heatGate: 0,
      passiveBalancing: true,
    );
    List<int> payload(List<int> f) => f.sublist(2, f.length - 2);

    test('enabling the heater flips ONLY payload[4]', () {
      final f = buildGateControlFrame(
          base: base, action: GateAction.heatGate, on: true);
      // base -> [1,1,1,1,0,0,1,0]; only index 4 (heat) rises to 1.
      expect(payload(f), [1, 1, 1, 1, 1, 0, 1, 0]);
      expect(GateControl.iHeatGate, 4);
    });

    test('disabling the heater flips ONLY payload[4] back to 0', () {
      const heatOn = GateSnapshot(
        chargeMos: true,
        dischargeMos: true,
        tempControlGate: 1,
        smokeGate: 1,
        heatGate: 1,
        passiveBalancing: true,
      );
      final f = buildGateControlFrame(
          base: heatOn, action: GateAction.heatGate, on: false);
      expect(payload(f), [1, 1, 1, 1, 0, 0, 1, 0]);
    });

    test('heat toggle never sets restart[5] or factory[7]', () {
      final f = buildGateControlFrame(
          base: base, action: GateAction.heatGate, on: true);
      final p = payload(f);
      expect(p[GateControl.iRestart], 0);
      expect(p[GateControl.iFactory], 0);
    });
  });
}
