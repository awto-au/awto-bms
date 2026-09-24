/// #71: the FULL last-known state of one pack — every value the section
/// widgets show — captured from a decoded [BatteryState] and persisted inside
/// the pack's [FleetRecord] so a restart restores it into the remembered
/// placeholder. The sections then render these values in the STALE style
/// (red, dimmed, with a "last known · 3 d ago" caption) instead of a wall of
/// dashes; a value that was never known stays null and still renders "—".
///
/// Pure data: [capture] reads a state, [applyTo] writes one, and the JSON
/// shape is additive (every field optional) so an older record still loads.
library;

import 'battery_protocol.dart';

class LastKnownState {
  final int? soc;
  final double? remainingAh;
  final double? fullAh;
  final double? packVoltage;

  /// SIGNED current (+ in / − out) — the sign carries the direction, so the
  /// magnitude and the charge state restore together. Unsigned (the
  /// magnitude) when current flowed with no direction reported.
  final double? packCurrent;
  final double? power;
  final ChargeState chargeState;
  final bool? loadConnected;
  final bool? chargerConnected;
  final List<int> cellsMv;
  final double? cellSum;
  final double? cellMax;
  final double? cellMin;
  final double? cellDiff;
  final double? cellAvg;
  final int? temp0;
  final int? temp1;
  final int? temp2;
  final int? temp3;
  final int? chipTemperature;
  final int? cycleCount;
  final int? timeToFullSec;
  final int? timeToEmptySec;
  final bool? mosOn;
  final bool? chargeMos;
  final bool? dischargeMos;
  final bool? passiveBalancing;
  final int? tempControlGate;
  final int? smokeGate;
  final int? heatGate;
  final bool overTempLatched;
  final bool temperatureAlarmSeen;
  final bool? sleepModeOn;
  final String? firmwareVersion;

  /// The alarm bytes as decoded: the warning texts per frame and the fault
  /// flags, plus the "seen" flags so "no fault" is never confused with
  /// "never reported".
  final List<String> currentWarnings;
  final List<String> voltageWarnings;
  final List<String> temperatureWarnings;
  final bool faultCurrent;
  final bool faultVoltage;
  final bool faultTemperature;
  final bool currentAlarmSeen;
  final bool voltageAlarmSeen;

  const LastKnownState({
    this.soc,
    this.remainingAh,
    this.fullAh,
    this.packVoltage,
    this.packCurrent,
    this.power,
    this.chargeState = ChargeState.unknown,
    this.loadConnected,
    this.chargerConnected,
    this.cellsMv = const [],
    this.cellSum,
    this.cellMax,
    this.cellMin,
    this.cellDiff,
    this.cellAvg,
    this.temp0,
    this.temp1,
    this.temp2,
    this.temp3,
    this.chipTemperature,
    this.cycleCount,
    this.timeToFullSec,
    this.timeToEmptySec,
    this.mosOn,
    this.chargeMos,
    this.dischargeMos,
    this.passiveBalancing,
    this.tempControlGate,
    this.smokeGate,
    this.heatGate,
    this.overTempLatched = false,
    this.temperatureAlarmSeen = false,
    this.sleepModeOn,
    this.firmwareVersion,
    this.currentWarnings = const [],
    this.voltageWarnings = const [],
    this.temperatureWarnings = const [],
    this.faultCurrent = false,
    this.faultVoltage = false,
    this.faultTemperature = false,
    this.currentAlarmSeen = false,
    this.voltageAlarmSeen = false,
  });

  /// Snapshot [s]; [signedCurrent] is the connection's direction-signed
  /// current (null when the pack never reported one). A signed 0 while the
  /// frame's current is above zero (no direction known) keeps the magnitude:
  /// the current is never recorded as 0.0 A next to a non-zero power.
  factory LastKnownState.capture(BatteryState s, {double? signedCurrent}) =>
      LastKnownState(
        soc: s.socPercent,
        remainingAh: s.remainingAh,
        fullAh: s.fullAh,
        packVoltage: s.packVoltage,
        packCurrent: _capturedCurrent(s.packCurrent, signedCurrent),
        power: s.power,
        chargeState: s.chargeState,
        loadConnected: s.loadConnected,
        chargerConnected: s.chargerConnected,
        cellsMv: List<int>.unmodifiable(s.cellsMv),
        cellSum: s.cellSum,
        cellMax: s.cellMax,
        cellMin: s.cellMin,
        cellDiff: s.cellDiff,
        cellAvg: s.cellAvg,
        temp0: s.temp0,
        temp1: s.temp1,
        temp2: s.temp2,
        temp3: s.temp3,
        chipTemperature: s.chipTemperature,
        cycleCount: s.cycleCount,
        timeToFullSec: s.timeToFullSec,
        timeToEmptySec: s.timeToEmptySec,
        mosOn: s.mosOn,
        chargeMos: s.chargeMos,
        dischargeMos: s.dischargeMos,
        passiveBalancing: s.passiveBalancing,
        tempControlGate: s.tempControlGate,
        smokeGate: s.smokeGate,
        heatGate: s.heatGate,
        overTempLatched: s.overTempLatched,
        temperatureAlarmSeen: s.temperatureAlarmSeen,
        sleepModeOn: s.sleepModeOn,
        firmwareVersion: s.firmwareVersion,
        currentWarnings: List<String>.unmodifiable(s.currentWarnings),
        voltageWarnings: List<String>.unmodifiable(s.voltageWarnings),
        temperatureWarnings: List<String>.unmodifiable(s.temperatureWarnings),
        faultCurrent: s.faultCurrent,
        faultVoltage: s.faultVoltage,
        faultTemperature: s.faultTemperature,
        currentAlarmSeen: s.currentAlarmSeen,
        voltageAlarmSeen: s.voltageAlarmSeen,
      );

  static double? _capturedCurrent(double? magnitude, double? signed) {
    if (magnitude == null) return null;
    if (signed == null || (signed == 0 && magnitude > 0)) return magnitude;
    return signed;
  }

  /// A record written before the status fix stored a signed current of 0
  /// whenever BAL s0 read idle, even with current flowing — "0.0 A" beside
  /// "19 W". No real ALL_DATA frame carries 0 A with power above 0 (13 214 of
  /// 13 214 zero-current frames read 0 W in the 2026-09-24 merged data), so
  /// that pair is the old capture bug, not a reading: the current is dropped
  /// (shown as never known) rather than restored as a false 0.0 A.
  bool get _currentLost => packCurrent == 0 && (power ?? 0) > 0;

  /// True iff at least one value was ever known — a record captured from a
  /// pack that never decoded a frame is all-null and restores nothing.
  bool get hasAnyValue =>
      soc != null ||
      packVoltage != null ||
      packCurrent != null ||
      remainingAh != null ||
      fullAh != null ||
      cellsMv.isNotEmpty ||
      temp1 != null ||
      chargeMos != null ||
      dischargeMos != null ||
      firmwareVersion != null;

  /// Write every known value into [s] (a null here leaves the field alone,
  /// so a never-known value keeps rendering "—").
  void applyTo(BatteryState s) {
    if (soc != null) s.socPercent = soc;
    if (remainingAh != null) s.remainingAh = remainingAh;
    if (fullAh != null) s.fullAh = fullAh;
    if (packVoltage != null) s.packVoltage = packVoltage;
    if (packCurrent != null && !_currentLost) {
      s.packCurrent = packCurrent!.abs();
    }
    if (power != null) s.power = power;
    if (chargeState != ChargeState.unknown) s.chargeState = chargeState;
    if (loadConnected != null) s.loadConnected = loadConnected;
    if (chargerConnected != null) s.chargerConnected = chargerConnected;
    if (cellsMv.isNotEmpty) s.cellsMv = List<int>.from(cellsMv);
    if (cellSum != null) s.cellSum = cellSum;
    if (cellMax != null) s.cellMax = cellMax;
    if (cellMin != null) s.cellMin = cellMin;
    if (cellDiff != null) s.cellDiff = cellDiff;
    if (cellAvg != null) s.cellAvg = cellAvg;
    if (temp0 != null) s.temp0 = temp0;
    if (temp1 != null) s.temp1 = temp1;
    if (temp2 != null) s.temp2 = temp2;
    if (temp3 != null) s.temp3 = temp3;
    if (chipTemperature != null) s.chipTemperature = chipTemperature;
    if (cycleCount != null) s.cycleCount = cycleCount;
    if (timeToFullSec != null) s.timeToFullSec = timeToFullSec;
    if (timeToEmptySec != null) s.timeToEmptySec = timeToEmptySec;
    if (mosOn != null) s.mosOn = mosOn;
    if (chargeMos != null) s.chargeMos = chargeMos;
    if (dischargeMos != null) s.dischargeMos = dischargeMos;
    if (passiveBalancing != null) s.passiveBalancing = passiveBalancing;
    if (tempControlGate != null) s.tempControlGate = tempControlGate;
    if (smokeGate != null) s.smokeGate = smokeGate;
    if (heatGate != null) s.heatGate = heatGate;
    if (temperatureAlarmSeen) {
      s.temperatureAlarmSeen = true;
      s.overTempLatched = overTempLatched;
      s.temperatureWarnings = List<String>.from(temperatureWarnings);
      s.faultTemperature = faultTemperature;
    }
    if (currentAlarmSeen) {
      s.currentAlarmSeen = true;
      s.currentWarnings = List<String>.from(currentWarnings);
      s.faultCurrent = faultCurrent;
    }
    if (voltageAlarmSeen) {
      s.voltageAlarmSeen = true;
      s.voltageWarnings = List<String>.from(voltageWarnings);
      s.faultVoltage = faultVoltage;
    }
    if (sleepModeOn != null) s.sleepModeOn = sleepModeOn;
    if (firmwareVersion != null) s.firmwareVersion = firmwareVersion;
  }

  Map<String, dynamic> toJson() => {
        if (soc != null) 'soc': soc,
        if (remainingAh != null) 'remAh': remainingAh,
        if (fullAh != null) 'fullAh': fullAh,
        if (packVoltage != null) 'packV': packVoltage,
        if (packCurrent != null) 'packI': packCurrent,
        if (power != null) 'power': power,
        if (chargeState != ChargeState.unknown) 'chargeState': chargeState.name,
        if (loadConnected != null) 'load': loadConnected,
        if (chargerConnected != null) 'charger': chargerConnected,
        if (cellsMv.isNotEmpty) 'cellsMv': cellsMv,
        if (cellSum != null) 'cellSum': cellSum,
        if (cellMax != null) 'cellMax': cellMax,
        if (cellMin != null) 'cellMin': cellMin,
        if (cellDiff != null) 'cellDelta': cellDiff,
        if (cellAvg != null) 'cellAvg': cellAvg,
        if (temp0 != null) 'temp0': temp0,
        if (temp1 != null) 'temp1': temp1,
        if (temp2 != null) 'temp2': temp2,
        if (temp3 != null) 'temp3': temp3,
        if (chipTemperature != null) 'chip': chipTemperature,
        if (cycleCount != null) 'cycles': cycleCount,
        if (timeToFullSec != null) 'timeToFullSec': timeToFullSec,
        if (timeToEmptySec != null) 'timeToEmptySec': timeToEmptySec,
        if (mosOn != null) 'mos': mosOn,
        if (chargeMos != null) 'chgMos': chargeMos,
        if (dischargeMos != null) 'disMos': dischargeMos,
        if (passiveBalancing != null) 'passiveBal': passiveBalancing,
        if (tempControlGate != null) 'tempGate': tempControlGate,
        if (smokeGate != null) 'smokeGate': smokeGate,
        if (heatGate != null) 'heatGate': heatGate,
        if (temperatureAlarmSeen) 'tempAlarmSeen': true,
        if (overTempLatched) 'overTempLatched': true,
        if (sleepModeOn != null) 'sleepModeOn': sleepModeOn,
        if (firmwareVersion != null) 'firmware': firmwareVersion,
        if (currentWarnings.isNotEmpty) 'currentWarnings': currentWarnings,
        if (voltageWarnings.isNotEmpty) 'voltageWarnings': voltageWarnings,
        if (temperatureWarnings.isNotEmpty)
          'temperatureWarnings': temperatureWarnings,
        if (faultCurrent) 'faultCurrent': true,
        if (faultVoltage) 'faultVoltage': true,
        if (faultTemperature) 'faultTemperature': true,
        if (currentAlarmSeen) 'currentAlarmSeen': true,
        if (voltageAlarmSeen) 'voltageAlarmSeen': true,
      };

  factory LastKnownState.fromJson(Map<String, dynamic> j) {
    int? i(String k) => (j[k] as num?)?.toInt();
    double? d(String k) => (j[k] as num?)?.toDouble();
    bool? b(String k) => j[k] as bool?;
    bool f(String k) => j[k] == true;
    List<String> strs(String k) =>
        List<String>.unmodifiable((j[k] as List?)?.cast<String>() ?? const []);
    final csName = j['chargeState'] as String?;
    return LastKnownState(
      soc: i('soc'),
      remainingAh: d('remAh'),
      fullAh: d('fullAh'),
      packVoltage: d('packV'),
      packCurrent: d('packI'),
      power: d('power'),
      chargeState: ChargeState.values.firstWhere((c) => c.name == csName,
          orElse: () => ChargeState.unknown),
      loadConnected: b('load'),
      chargerConnected: b('charger'),
      cellsMv: List<int>.unmodifiable(
          (j['cellsMv'] as List?)?.map((v) => (v as num).toInt()) ?? const []),
      cellSum: d('cellSum'),
      cellMax: d('cellMax'),
      cellMin: d('cellMin'),
      cellDiff: d('cellDelta'),
      cellAvg: d('cellAvg'),
      temp0: i('temp0'),
      temp1: i('temp1'),
      temp2: i('temp2'),
      temp3: i('temp3'),
      chipTemperature: i('chip'),
      cycleCount: i('cycles'),
      timeToFullSec: i('timeToFullSec'),
      timeToEmptySec: i('timeToEmptySec'),
      mosOn: b('mos'),
      chargeMos: b('chgMos'),
      dischargeMos: b('disMos'),
      passiveBalancing: b('passiveBal'),
      tempControlGate: i('tempGate'),
      smokeGate: i('smokeGate'),
      heatGate: i('heatGate'),
      overTempLatched: f('overTempLatched'),
      temperatureAlarmSeen: f('tempAlarmSeen'),
      sleepModeOn: b('sleepModeOn'),
      firmwareVersion: j['firmware'] as String?,
      currentWarnings: strs('currentWarnings'),
      voltageWarnings: strs('voltageWarnings'),
      temperatureWarnings: strs('temperatureWarnings'),
      faultCurrent: f('faultCurrent'),
      faultVoltage: f('faultVoltage'),
      faultTemperature: f('faultTemperature'),
      currentAlarmSeen: f('currentAlarmSeen'),
      voltageAlarmSeen: f('voltageAlarmSeen'),
    );
  }

  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is LastKnownState &&
      other.soc == soc &&
      other.remainingAh == remainingAh &&
      other.fullAh == fullAh &&
      other.packVoltage == packVoltage &&
      other.packCurrent == packCurrent &&
      other.power == power &&
      other.chargeState == chargeState &&
      other.loadConnected == loadConnected &&
      other.chargerConnected == chargerConnected &&
      _listEq(other.cellsMv, cellsMv) &&
      other.cellSum == cellSum &&
      other.cellMax == cellMax &&
      other.cellMin == cellMin &&
      other.cellDiff == cellDiff &&
      other.cellAvg == cellAvg &&
      other.temp0 == temp0 &&
      other.temp1 == temp1 &&
      other.temp2 == temp2 &&
      other.temp3 == temp3 &&
      other.chipTemperature == chipTemperature &&
      other.cycleCount == cycleCount &&
      other.timeToFullSec == timeToFullSec &&
      other.timeToEmptySec == timeToEmptySec &&
      other.mosOn == mosOn &&
      other.chargeMos == chargeMos &&
      other.dischargeMos == dischargeMos &&
      other.passiveBalancing == passiveBalancing &&
      other.tempControlGate == tempControlGate &&
      other.smokeGate == smokeGate &&
      other.heatGate == heatGate &&
      other.overTempLatched == overTempLatched &&
      other.temperatureAlarmSeen == temperatureAlarmSeen &&
      other.sleepModeOn == sleepModeOn &&
      other.firmwareVersion == firmwareVersion &&
      _listEq(other.currentWarnings, currentWarnings) &&
      _listEq(other.voltageWarnings, voltageWarnings) &&
      _listEq(other.temperatureWarnings, temperatureWarnings) &&
      other.faultCurrent == faultCurrent &&
      other.faultVoltage == faultVoltage &&
      other.faultTemperature == faultTemperature &&
      other.currentAlarmSeen == currentAlarmSeen &&
      other.voltageAlarmSeen == voltageAlarmSeen;

  @override
  int get hashCode => Object.hash(
        soc,
        remainingAh,
        fullAh,
        packVoltage,
        packCurrent,
        power,
        chargeState,
        Object.hashAll(cellsMv),
        temp1,
        temp2,
        chargeMos,
        dischargeMos,
        firmwareVersion,
        cycleCount,
        Object.hashAll(currentWarnings),
        Object.hashAll(voltageWarnings),
        Object.hashAll(temperatureWarnings),
      );
}
