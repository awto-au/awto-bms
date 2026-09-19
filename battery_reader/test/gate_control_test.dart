import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_protocol.dart';

/// Unit tests for the SAFETY-CRITICAL CMD_GATE_CONTROL frame builder: correct
/// sentinels, correct 8-byte payload layout, and the "only the target byte
/// flips, every other gate keeps its current value" rule the vendor app uses.
void main() {
  // A base with a mix of on/off gates, so a clobbered byte would be visible.
  const base = GateSnapshot(
    chargeMos: true,
    dischargeMos: true,
    tempControlGate: 1,
    smokeGate: 0,
    heatGate: 1,
    passiveBalancing: true,
  );

  // Payload = frame with the 2 begin + 2 end sentinel bytes stripped.
  List<int> payload(List<int> frame) => frame.sublist(2, frame.length - 2);

  test('frame is begin C3 1E + 8 payload bytes + end D4 3B (12 bytes)', () {
    final f = buildGateControlFrame(
        base: const GateSnapshot(), action: GateAction.chargeMos, on: true);
    expect(f.length, 12);
    expect(f.sublist(0, 2), [0xC3, 0x1E]); // GateControl.begin
    expect(f.sublist(f.length - 2), [0xD4, 0x3B]); // GateControl.end
    expect(GateControl.begin, [0xC3, 0x1E]);
    expect(GateControl.end, [0xD4, 0x3B]);
  });

  test('payload byte positions match the protocol map', () {
    // Every gate on, restart+factory requested -> all eight bytes = 1.
    const allOn = GateSnapshot(
      chargeMos: true,
      dischargeMos: true,
      tempControlGate: 1,
      smokeGate: 1,
      heatGate: 1,
      passiveBalancing: true,
    );
    // passiveBalance target keeps everything else; then check indices directly.
    final f = buildGateControlFrame(
        base: allOn, action: GateAction.passiveBalance, on: true);
    final p = payload(f);
    expect(p, [1, 1, 1, 1, 1, 0, 1, 0]); // restart[5]/factory[7] stay 0
    expect(GateControl.iChargeMos, 0);
    expect(GateControl.iDischargeMos, 1);
    expect(GateControl.iTempControlGate, 2);
    expect(GateControl.iSmokeGate, 3);
    expect(GateControl.iHeatGate, 4);
    expect(GateControl.iRestart, 5);
    expect(GateControl.iPassiveBalance, 6);
    expect(GateControl.iFactory, 7);
  });

  test('toggling discharge MOS off flips ONLY byte[1]', () {
    final f = buildGateControlFrame(
        base: base, action: GateAction.dischargeMos, on: false);
    final p = payload(f);
    // base encodes to [1,1,1,0,1,0,1,0]; only index 1 changes to 0.
    expect(p, [1, 0, 1, 0, 1, 0, 1, 0]);
  });

  test('toggling charge MOS off flips ONLY byte[0]', () {
    final f = buildGateControlFrame(
        base: base, action: GateAction.chargeMos, on: false);
    expect(payload(f), [0, 1, 1, 0, 1, 0, 1, 0]);
  });

  test('OUTPUT action sets BOTH FET bytes together to ON (vendor setMos, #26)',
      () {
    // Start from a base with both FETs off; output ON must raise [0] AND [1].
    const bothOff = GateSnapshot(
      chargeMos: false,
      dischargeMos: false,
      tempControlGate: 1,
      smokeGate: 0,
      heatGate: 1,
      passiveBalancing: true,
    );
    final f = buildGateControlFrame(
        base: bothOff, action: GateAction.output, on: true);
    final p = payload(f);
    expect(p[GateControl.iChargeMos], 1);
    expect(p[GateControl.iDischargeMos], 1);
    // Every other gate keeps its cached value; restart/factory stay 0.
    expect(p, [1, 1, 1, 0, 1, 0, 1, 0]);
  });

  test('OUTPUT action sets BOTH FET bytes together to OFF (vendor setMos, #26)',
      () {
    // base has both FETs on; output OFF must clear [0] AND [1] in one frame.
    final f = buildGateControlFrame(
        base: base, action: GateAction.output, on: false);
    final p = payload(f);
    expect(p[GateControl.iChargeMos], 0);
    expect(p[GateControl.iDischargeMos], 0);
    // Other gates untouched (temp[2]=1, smoke[3]=0, heat[4]=1, passive[6]=1).
    expect(p, [0, 0, 1, 0, 1, 0, 1, 0]);
  });

  test('toggling passive balancing off flips ONLY byte[6]', () {
    final f = buildGateControlFrame(
        base: base, action: GateAction.passiveBalance, on: false);
    expect(payload(f), [1, 1, 1, 0, 1, 0, 0, 0]);
  });

  test('restart sets byte[5]=1 and ignores `on`, keeping other gates', () {
    final f = buildGateControlFrame(
        base: base, action: GateAction.restart, on: false);
    expect(payload(f), [1, 1, 1, 0, 1, 1, 1, 0]); // only [5] rises
  });

  test('factory sets byte[7]=1 and ignores `on`, keeping other gates', () {
    final f = buildGateControlFrame(
        base: base, action: GateAction.factory, on: false);
    expect(payload(f), [1, 1, 1, 0, 1, 0, 1, 1]); // only [7] rises
  });

  test('restart and factory are never set by an unrelated toggle', () {
    final f = buildGateControlFrame(
        base: base, action: GateAction.chargeMos, on: true);
    final p = payload(f);
    expect(p[GateControl.iRestart], 0);
    expect(p[GateControl.iFactory], 0);
  });

  test('GateSnapshot.fromState reads the live BAL_STATUS gate values', () {
    final state = BatteryState()
      ..chargeMos = true
      ..dischargeMos = false
      ..tempControlGate = 1
      ..smokeGate = 0
      ..heatGate = 1
      ..passiveBalancing = false;
    final f = buildGateControlFrame(
        base: GateSnapshot.fromState(state)!,
        action: GateAction.dischargeMos,
        on: true);
    // charge[0]=1 kept, discharge[1] flips to 1, temp[2]=1, smoke[3]=0,
    // heat[4]=1, restart[5]=0, passive[6]=0, factory[7]=0.
    expect(payload(f), [1, 1, 1, 0, 1, 0, 0, 0]);
  });

  group('C1: fromState returns null on any unknown gate (never zeros)', () {
    BatteryState full() => BatteryState()
      ..chargeMos = true
      ..dischargeMos = true
      ..tempControlGate = 1
      ..smokeGate = 0
      ..heatGate = 0
      ..passiveBalancing = false;

    test('a fully-known state yields a snapshot', () {
      expect(GateSnapshot.fromState(full()), isNotNull);
    });

    test('nothing known (fresh connect, no BAL_STATUS yet) -> null', () {
      // Before this fix the base defaulted to all-zeros, so "passive balancing
      // ON" wrote C3 1E 00 00 00 00 00 00 01 00 D4 3B — output CUT.
      expect(GateSnapshot.fromState(BatteryState()), isNull);
    });

    test('each single unknown gate -> null', () {
      expect(GateSnapshot.fromState(full()..chargeMos = null), isNull);
      expect(GateSnapshot.fromState(full()..dischargeMos = null), isNull);
      expect(GateSnapshot.fromState(full()..tempControlGate = null), isNull);
      expect(GateSnapshot.fromState(full()..smokeGate = null), isNull);
      expect(GateSnapshot.fromState(full()..heatGate = null), isNull);
      expect(GateSnapshot.fromState(full()..passiveBalancing = null), isNull);
    });
  });
}
