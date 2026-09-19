import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/demo_source.dart';

/// Synthetic frames built to the spec in
/// PROTOCOL.md, so parsing is verified
/// without hardware. Values chosen to survive the app's truncating divisions.
void main() {
  late BatteryState state;
  late BatteryParser parser;

  setUp(() {
    state = BatteryState();
    parser = BatteryParser(state: state);
  });

  // ALL_DATA: A2 57 + 24-byte payload (end B3 6C)
  final allData = <int>[
    0xA2, 0x57, //
    0x85, 0x00, // packVoltage 133 -> 13.3 V
    0x88, 0x13, 0x00, // current u24=5000 -> (5000/100)/10 = 5.0 A
    0x01, // load connected
    0x00, // charger not connected
    0x19, // chip temp 25
    0x85, 0x00, // vsum 133 -> 13.3 V
    0x16, 0x0D, // maxVol 3350 -> 3.35 V
    0xE4, 0x0C, // minVol 3300 -> 3.30 V
    0x32, 0x00, // diff 50 -> 0.05 V
    0x99, 0x02, // power 665 -> 66.5 W
    0x0C, 0x00, // cycles 12
    0xF8, 0x0C, // avg 3320 -> 3.32 V
    0xB3, 0x6C, // end
  ];

  test('ALL_DATA decodes every field', () {
    parser.addBytes(allData);
    expect(state.packVoltage, closeTo(13.3, 1e-6));
    expect(state.packCurrent, closeTo(5.0, 1e-6));
    expect(state.loadConnected, isTrue);
    expect(state.chargerConnected, isFalse);
    expect(state.chipTemperature, 25);
    expect(state.cellSum, closeTo(13.3, 1e-6));
    expect(state.cellMax, closeTo(3.35, 1e-6));
    expect(state.cellMin, closeTo(3.30, 1e-6));
    expect(state.cellDiff, closeTo(0.05, 1e-6));
    expect(state.power, closeTo(66.5, 1e-6));
    expect(state.cycleCount, 12);
    expect(state.cellAvg, closeTo(3.32, 1e-6));
  });

  test('SOC decodes percent and capacities', () {
    parser.addBytes([
      0xA9, 0x64, //
      0x57, // 87 %
      0xA0, 0x86, 0x01, // full u24=100000 -> 100.0 Ah
      0xCC, 0x55, 0x01, // remaining u24=87500 -> 87.5 Ah
      0xBA, 0x5E, // end
    ]);
    expect(state.socPercent, 87);
    expect(state.fullAh, closeTo(100.0, 1e-6));
    expect(state.remainingAh, closeTo(87.5, 1e-6));
  });

  test('SOC clamps percent above 100', () {
    parser.addBytes([
      0xA9, 0x64, 0xFF, 0, 0, 0, 0, 0, 0, 0xBA, 0x5E, //
    ]);
    expect(state.socPercent, 100);
  });

  test('TEMP decodes signed sensors', () {
    parser.addBytes([0xA1, 0x4F, 0x00, 0x19, 0x00, 0xFB, 0xB2, 0xE3]);
    expect(state.temp1, 25);
    expect(state.temp2, -5);
  });

  test('VOL decodes count-prefixed cells (little-endian mV)', () {
    parser.addBytes([0xA0, 0xC1, 0x02, 0xE4, 0x0C, 0xF8, 0x0C, 0xB1, 0xD2]);
    expect(state.cellsMv, [3300, 3320]);
  });

  test('BAL_STATUS decodes charge state and gates', () {
    parser.addBytes([
      0xA8, 0xAC, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0xB9, 0x21, //
    ]);
    expect(state.chargeState, ChargeState.charging);
    expect(state.chargeMos, isTrue);
    expect(state.dischargeMos, isTrue);
    expect(state.passiveBalancing, isTrue);
  });

  test('MOS_STATUS on only when first two bytes are 1', () {
    parser.addBytes([0xA3, 0x9F, 0x01, 0x01, 0, 0, 0, 0, 0xB4, 0xC7]);
    expect(state.mosOn, isTrue);
    parser.addBytes([0xA3, 0x9F, 0x01, 0x00, 0, 0, 0, 0, 0xB4, 0xC7]);
    expect(state.mosOn, isFalse);
  });

  test('EST_TIME decodes to-full and to-empty seconds', () {
    parser.addBytes([
      0xAA, 0xAF, //
      0x4D, 0x0E, 0x00, // to full 3661 s
      0x20, 0x1C, 0x00, // to empty 7200 s
      0xBB, 0x22, // end
    ]);
    expect(state.timeToFullSec, 3661);
    expect(state.timeToEmptySec, 7200);
    expect(secondsToHms(3661), '01:01:01');
    expect(secondsToHms(7200), '02:00:00');
  });

  test('VERSION reads 5 ASCII chars', () {
    parser.addBytes([0xAC, 0x9A, 0x32, 0x33, 0x2E, 0x31, 0x31, 0xBD, 0x10]);
    expect(state.firmwareVersion, '23.11');
  });

  test('temperature alarms map flags to text', () {
    parser.addBytes([
      0xA6, 0xC0, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0xB7, 0x72, //
    ]);
    expect(state.temperatureWarnings, contains('Chip over temperature protection'));
    expect(state.temperatureWarnings,
        contains('Under temperature discharge protection'));
  });

  test('SLEEP_SET_SUCCESS: byte0==0 => on, else off', () {
    parser.addBytes([0xAC, 0xCA, 0x00, 0xDE, 0xED]);
    expect(state.sleepModeOn, isTrue);
    parser.addBytes([0xAC, 0xCA, 0x01, 0xDE, 0xED]);
    expect(state.sleepModeOn, isFalse);
  });

  test('SETTING_RESPOND acks only when byte0==4 (capacity write)', () {
    // Non-capacity type: no ack recorded.
    parser.addBytes([0xAB, 0xBA, 0x01, 0xCD, 0xDC]);
    expect(state.capacityWriteAck, isNull);
    // Capacity ack.
    parser.addBytes([0xAB, 0xBA, 0x04, 0xCD, 0xDC]);
    expect(state.capacityWriteAck, isTrue);
  });

  test('GATE_SET echoes the 8 gate fields as booleans', () {
    parser.addBytes([
      0xD2, 0x7E, //
      0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, // 8 gate fields
      0xFA, 0x4B, // end
    ]);
    expect(state.gateAck,
        [true, true, false, false, true, false, true, false]);
  });

  test('OTHER (A7 4E) is skipped (9 bytes) and stream stays aligned', () {
    parser.addBytes([
      0xA7, 0x4E, 0, 1, 2, 3, 4, 5, 6, 7, 8, // OTHER + 9 discarded bytes
      ...allData,
    ]);
    expect(state.packVoltage, closeTo(13.3, 1e-6));
  });

  test('HISTORY is recognised, skipped to its 4-byte end, then stream aligns',
      () {
    parser.addBytes([
      0xFE, 0xC9, 0x11, 0x22, 0x33, 0x44, // history begin + payload
      0xEA, 0x4F, 0x80, 0xDE, // history end sentinel
      ...allData,
    ]);
    expect(state.packVoltage, closeTo(13.3, 1e-6));
  });

  test('resyncs past leading garbage and a bad end sentinel', () {
    // garbage, then a frame whose end is wrong, then a valid ALL_DATA
    final bad = List<int>.from(allData)..[24] = 0x00; // corrupt end byte
    parser.addBytes([0xFF, 0x12, 0x00, ...bad, ...allData]);
    // The valid frame at the tail must still be decoded.
    expect(state.packVoltage, closeTo(13.3, 1e-6));
    expect(state.cycleCount, 12);
  });

  test('handles frames split across notifications', () {
    parser.addBytes(allData.sublist(0, 5));
    expect(state.packVoltage, isNull); // incomplete
    parser.addBytes(allData.sublist(5));
    expect(state.packVoltage, closeTo(13.3, 1e-6));
  });

  test('back-to-back frames in one buffer both parse', () {
    parser.addBytes([
      ...[0xA1, 0x4F, 0x00, 0x19, 0x00, 0xFB, 0xB2, 0xE3], // temp
      ...allData,
    ]);
    expect(state.temp1, 25);
    expect(state.packVoltage, closeTo(13.3, 1e-6));
  });

  test('DemoBattery frames round-trip through the parser', () {
    // The simulator encodes frames; the parser must decode them back to
    // self-consistent values. This validates the encoders AND the parser.
    final demo = DemoBattery(parser.addBytes);
    demo.start(); // fires one cycle immediately
    demo.stop();

    // A full cycle was emitted, so every frame type should have landed.
    expect(state.cellsMv.length, 4);
    expect(state.socPercent, isNotNull);
    expect(state.fullAh, closeTo(100.0, 1e-6));

    // Cross-frame consistency: ALL_DATA max/min agree with the VOL cells,
    // and remaining tracks SOC against full capacity.
    final maxCellV = state.cellsMv.reduce((a, b) => a > b ? a : b) / 1000.0;
    final minCellV = state.cellsMv.reduce((a, b) => a < b ? a : b) / 1000.0;
    expect(state.cellMax, closeTo(maxCellV, 0.01));
    expect(state.cellMin, closeTo(minCellV, 0.01));
    expect(state.remainingAh,
        closeTo(state.fullAh! * state.socPercent! / 100.0, 0.05));
  });
}
