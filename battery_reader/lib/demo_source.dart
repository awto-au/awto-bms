/// Synthetic BMS frame generator, so the app can be exercised with no hardware.
///
/// It builds real, spec-correct frames (the exact inverse of the layouts in
/// battery_protocol.dart) and drives a virtual 4-cell / 100 Ah pack. [DemoMode]
/// selects behaviour so a fleet of demo batteries can differ: one charging,
/// one discharging, others idle at a fixed level.
library;

import 'dart:async';

enum DemoMode { charging, discharging, idle }

// Little-endian encoders (inverse of ByteUtils.byteToInt / byteToLong).
List<int> _u16le(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> _u24le(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff];

class DemoBattery {
  /// Called with each fully-framed packet (begin + payload + end).
  final void Function(List<int> frame) onFrame;

  final int startSoc;
  final DemoMode mode;

  Timer? _timer;
  int _tick = 0;

  /// How long the virtual BMS takes to acknowledge a write (M2): the ack and
  /// the refreshed status frames are emitted after this delay, so a caller's
  /// read-back listener (subscribed right after the send) sees them.
  final Duration ackLatency;

  // Writable virtual state (M2). Gates start as a real pack would report them
  // (charge MOS on; discharge MOS on unless charging), and every accepted write
  // updates them so the next BAL_STATUS reflects the change.
  bool _chargeMos = true;
  late bool _dischargeMos = mode != DemoMode.charging;

  /// #58: the virtual Charge switch (gate byte[0]) as last written.
  bool get chargeMos => _chargeMos;

  /// #58: the virtual Output switch (gate byte[1]) as last written.
  bool get dischargeMos => _dischargeMos;
  bool _passiveBal = false;
  int _heatGate = 0;
  int _tempGate = 1;
  int _smokeGate = 0;
  bool _sleeping = false;
  double _fullAh = 100.0;

  DemoBattery(
    this.onFrame, {
    this.startSoc = 50,
    this.mode = DemoMode.charging,
    this.ackLatency = const Duration(milliseconds: 200),
  });

  void start({Duration interval = const Duration(seconds: 1)}) {
    _timer?.cancel();
    _emitCycle();
    _timer = Timer.periodic(interval, (_) => _emitCycle());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _stopped = true;
  }

  bool _stopped = false;

  /// M2: accept a command frame the app would have written to FCF1 and behave
  /// like the BMS — update the virtual state and, after [ackLatency], emit the
  /// matching ack plus a refreshed status frame so read-backs complete. Frames
  /// the demo does not model (handshake, version, history) are accepted
  /// silently. Never throws.
  void handleWrite(List<int> bytes) {
    if (bytes.length < 2) return;
    final b0 = bytes[0] & 0xff, b1 = bytes[1] & 0xff;
    List<int>? ack;
    if (b0 == 0xC3 && b1 == 0x1E && bytes.length == 12) {
      // CMD_GATE_CONTROL: 8 payload bytes, see battery_protocol.dart. #58:
      // the two MOSFET switches are honoured SEPARATELY — byte[0] sets the
      // Charge switch, byte[1] the Output switch — so a per-switch write is
      // acked and reflected per switch in the next MOS/BAL status.
      final p = bytes.sublist(2, 10);
      _chargeMos = p[0] == 1;
      _dischargeMos = p[1] == 1;
      _tempGate = p[2] & 0xff;
      _smokeGate = p[3] & 0xff;
      _heatGate = p[4] & 0xff;
      _passiveBal = p[6] == 1;
      // restart [5] / factory [7]: a real pack reboots; the demo just acks.
      ack = [0xD2, 0x7E, ...p.map((v) => v == 0 ? 0 : 1), 0xFA, 0x4B];
    } else if (b0 == 0xAA && b1 == 0xCC && bytes.length == 6) {
      // Sleep: AA CC 00 .. = sleep on, AA CC 01 .. = wake. Ack byte0==0 = on.
      _sleeping = bytes[2] == 0;
      ack = [0xAC, 0xCA, _sleeping ? 0 : 1, 0xDE, 0xED];
    } else if (b0 == 0xC5 && b1 == 0x60 && bytes.length == 7) {
      // CMD_BATTERY capacity write: 24-bit LE mAh.
      final mah = (bytes[2] & 0xff) |
          ((bytes[3] & 0xff) << 8) |
          ((bytes[4] & 0xff) << 16);
      _fullAh = mah / 1000.0;
      ack = [0xAB, 0xBA, 0x04, 0xCD, 0xDC]; // SETTING_RESPOND type 4
    }
    if (ack == null) return;
    final frame = ack;
    Timer(ackLatency, () {
      if (_stopped) return;
      onFrame(frame);
      _emitStatus(_socNow());
    });
  }

  int _socNow() {
    switch (mode) {
      case DemoMode.charging:
        final s = startSoc + _tick;
        return s > 100 ? 100 : s;
      case DemoMode.discharging:
        final s = startSoc - _tick;
        return s < 0 ? 0 : s;
      case DemoMode.idle:
        return startSoc.clamp(0, 100);
    }
  }

  void _emitCycle() {
    _tick++;
    final soc = _socNow();

    // Cells climb from ~2.40 V (empty) to ~3.40 V (full) across the range.
    final baseMv = 2400 + soc * 10; // 2400..3400 mV
    final cells = [baseMv, baseMv + 24, baseMv + 8, baseMv + 15];
    final packMv = cells.reduce((a, b) => a + b);
    final maxMv = cells.reduce((a, b) => a > b ? a : b);
    final minMv = cells.reduce((a, b) => a < b ? a : b);
    final avgMv = packMv ~/ cells.length;

    final charging = mode == DemoMode.charging;
    final discharging = mode == DemoMode.discharging;
    final currentA = switch (mode) {
      DemoMode.charging => 15.5,
      DemoMode.discharging => 22.0,
      DemoMode.idle => 0.0,
    };
    final powerW = (packMv / 1000.0) * currentA;
    final toFullSec = charging ? ((100 - soc) * 90) : 0;
    final toEmptySec = discharging ? (soc * 120) : 0;

    onFrame(_vol(cells));
    onFrame(_temp(28, 30));
    onFrame(_allData(
      packMv: packMv,
      currentMilliA: (currentA * 1000).round(),
      load: discharging,
      charger: charging,
      chipTempC: 24,
      maxMv: maxMv,
      minMv: minMv,
      avgMv: avgMv,
      powerDeciW: (powerW * 10).round(),
      cycles: 7,
    ));
    _emitStatus(soc);
    onFrame(_est(toFullSec: toFullSec, toEmptySec: toEmptySec));
    // A real BMS streams all three alarm frames every cycle; the packed
    // `flags` log row is only written once every category is known (M8).
    onFrame(_warnCur());
    onFrame(_warnVol());
    onFrame(_warnTemp());
  }

  /// The status frames that reflect the writable virtual state: MOS, BAL and
  /// SOC. Emitted every cycle and again right after an accepted write.
  void _emitStatus(int soc) {
    final charging = mode == DemoMode.charging;
    final discharging = mode == DemoMode.discharging;
    final chargeState = charging ? 1 : (discharging ? 2 : 0);
    final remainingAh = _fullAh * soc / 100.0;
    onFrame(_mos(chargeMos: _chargeMos, dischargeMos: _dischargeMos));
    onFrame(_bal(chargeState: chargeState));
    onFrame(_soc(soc: soc, remainingAh: remainingAh, fullAh: _fullAh));
  }

  // --- frame builders ------------------------------------------------------

  List<int> _vol(List<int> cellsMv) => [
        0xA0, 0xC1,
        cellsMv.length,
        for (final mv in cellsMv) ..._u16le(mv),
        0xB1, 0xD2,
      ];

  List<int> _temp(int t1, int t2) => [
        0xA1, 0x4F,
        0x20, t1 & 0xff, 0x20, t2 & 0xff,
        0xB2, 0xE3,
      ];

  List<int> _allData({
    required int packMv,
    required int currentMilliA,
    required bool load,
    required bool charger,
    required int chipTempC,
    required int maxMv,
    required int minMv,
    required int avgMv,
    required int powerDeciW,
    required int cycles,
  }) {
    final packRaw = (packMv / 100).round(); // parser: u16/10 -> V (0.1 V units)
    final diffMv = maxMv - minMv;
    return [
      0xA2, 0x57,
      ..._u16le(packRaw),
      ..._u24le(currentMilliA),
      load ? 1 : 0,
      charger ? 1 : 0,
      chipTempC & 0xff,
      ..._u16le(packRaw),
      ..._u16le(maxMv),
      ..._u16le(minMv),
      ..._u16le(diffMv),
      ..._u16le(powerDeciW),
      ..._u16le(cycles),
      ..._u16le(avgMv),
      0xB3, 0x6C,
    ];
  }

  List<int> _mos({required bool chargeMos, required bool dischargeMos}) => [
        0xA3, 0x9F,
        chargeMos ? 1 : 0, dischargeMos ? 1 : 0, 0, 0, 0, 0,
        0xB4, 0xC7,
      ];

  List<int> _bal({required int chargeState}) => [
        0xA8, 0xAC,
        chargeState & 0xff,
        _chargeMos ? 1 : 0,
        _dischargeMos ? 1 : 0,
        _passiveBal ? 1 : 0,
        _tempGate & 0xff,
        _smokeGate & 0xff,
        _heatGate & 0xff,
        0xB9, 0x21,
      ];

  // Alarm frames, all clear (one flag byte per condition; unknown bytes 0).
  List<int> _warnCur() => [0xA4, 0x8B, 0, 0, 0, 0, 0, 0xB5, 0xDD];
  List<int> _warnVol() =>
      [0xA5, 0x99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xB6, 0x17];
  List<int> _warnTemp() => [0xA6, 0xC0, 0, 0, 0, 0, 0, 0, 0, 0xB7, 0x72];

  List<int> _soc({
    required int soc,
    required double remainingAh,
    required double fullAh,
  }) =>
      [
        0xA9, 0x64,
        soc & 0xff,
        ..._u24le((fullAh * 1000).round()),
        ..._u24le((remainingAh * 1000).round()),
        0xBA, 0x5E,
      ];

  List<int> _est({required int toFullSec, required int toEmptySec}) => [
        0xAA, 0xAF,
        ..._u24le(toFullSec),
        ..._u24le(toEmptySec),
        0xBB, 0x22,
      ];
}
