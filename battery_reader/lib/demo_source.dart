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

  DemoBattery(this.onFrame, {this.startSoc = 50, this.mode = DemoMode.charging});

  void start({Duration interval = const Duration(seconds: 1)}) {
    _timer?.cancel();
    _emitCycle();
    _timer = Timer.periodic(interval, (_) => _emitCycle());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
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
    const fullAh = 100.0;
    final remainingAh = fullAh * soc / 100.0;
    final toFullSec = charging ? ((100 - soc) * 90) : 0;
    final toEmptySec = discharging ? (soc * 120) : 0;
    final chargeState = charging ? 1 : (discharging ? 2 : 0);

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
    onFrame(_mos(chargeMos: true, dischargeMos: !charging));
    onFrame(_bal(
      chargeState: chargeState,
      chargeMos: true,
      dischargeMos: !charging,
    ));
    onFrame(_soc(soc: soc, remainingAh: remainingAh, fullAh: fullAh));
    onFrame(_est(toFullSec: toFullSec, toEmptySec: toEmptySec));
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

  List<int> _bal({
    required int chargeState,
    required bool chargeMos,
    required bool dischargeMos,
  }) =>
      [
        0xA8, 0xAC,
        chargeState & 0xff,
        chargeMos ? 1 : 0,
        dischargeMos ? 1 : 0,
        0, 0, 0, 0,
        0xB9, 0x21,
      ];

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
