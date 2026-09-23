/// Pure-Dart codec for the JoySuny BMS BLE protocol (Sphere Battery / RV Battery).
///
/// Reverse-engineered from the 1.0.24 (Sphere) decompile:
///   com/joysuny/batteryutil/blemanager/BatteryManager.java  (ProcessWatchRunnable)
///   com/joysuny/batteryutil/blemanager/BatteryCMD.java       (frame sentinels)
///   com/joysuny/batteryutil/util/ByteUtils.java              (all little-endian)
///
/// Nothing here has been checked against a live battery. All integer math
/// mirrors the app exactly, including its truncating divisions.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Little-endian helpers, matching ByteUtils.java exactly.
// ---------------------------------------------------------------------------

/// ByteUtils.byteToInt: unsigned 16-bit little-endian.
int _u16le(int b0, int b1) => (b0 & 0xff) | ((b1 & 0xff) << 8);

/// ByteUtils.byteToLong over 3 bytes: unsigned 24-bit little-endian.
int _u24le(int b0, int b1, int b2) =>
    (b0 & 0xff) | ((b1 & 0xff) << 8) | ((b2 & 0xff) << 16);

/// Signed 8-bit (temperature bytes: `if (v > 127) v += 0xFFFFFF00`).
int _s8(int b) {
  final v = b & 0xff;
  return v > 127 ? v - 256 : v;
}

/// ByteUtils.secondToTime: "HH:MM:SS", hours zero-padded to at least 2 digits.
String secondsToHms(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds - h * 3600) ~/ 60;
  final s = seconds - h * 3600 - m * 60;
  String p(int v) => v < 10 ? '0$v' : '$v';
  return '${p(h)}:${p(m)}:${p(s)}';
}

// ---------------------------------------------------------------------------
// Device profiles. Reading telemetry is identical across apps; only the
// BLE-rename prefix and default passwords differ (see PROVENANCE.md).
// ---------------------------------------------------------------------------

class DeviceProfile {
  final String name;

  /// Advertised-name prefix used for scan filtering (Global.DEFAULT_BLUE_HEAD).
  final String advPrefix;

  /// Prefix for the "set BLE name" ASCII command. `AT+=` on all builds
  /// (deep reverse pass: the command tables are byte-identical).
  final List<int> renamePrefix;

  const DeviceProfile({
    required this.name,
    required this.advPrefix,
    required this.renamePrefix,
  });

  static const sphere = DeviceProfile(
    name: 'Sphere Battery',
    advPrefix: 'JS',
    renamePrefix: [0x41, 0x54, 0x2B, 0x3D], // "AT+="
  );

  static const rv = DeviceProfile(
    name: 'RV Battery',
    // Deep reverse pass: all three builds' BatteryCMD.java are byte-identical;
    // the BLE-rename command is "AT+=" (0x3D) in RV too, not "AT+@". See
    // ../../PROTOCOL.md and artifacts/reverse/04-history-versions.md.
    advPrefix: 'RV',
    renamePrefix: [0x41, 0x54, 0x2B, 0x3D], // "AT+="
  );
}

// ---------------------------------------------------------------------------
// BLE UUIDs (PROTOCOL.md).
// ---------------------------------------------------------------------------

class BleUuids {
  static const service = '0000fcf0-0000-1000-8000-00805f9b34fb';
  static const writeChar = '0000fcf1-0000-1000-8000-00805f9b34fb';
  static const notifyChar = '0000fcf2-0000-1000-8000-00805f9b34fb';
}

// ---------------------------------------------------------------------------
// TX command builders (app -> BMS).
// ---------------------------------------------------------------------------

class BatteryCommands {
  final DeviceProfile profile;
  const BatteryCommands([this.profile = DeviceProfile.sphere]);

  /// Handshake opener. After this the BMS streams telemetry unsolicited.
  static const begin = <int>[0xFB, 0xC8, 0x7C, 0x9D, 0x26, 0xEC];

  /// Request estimated remaining/charge time.
  static const getEst = <int>[0xC4, 0x7D, 0xF4, 0xD5, 0x86];

  /// ASCII "AT+V\r\n" — request firmware version.
  static const getVersion = <int>[0x41, 0x54, 0x2B, 0x56, 0x0D, 0x0A];

  static const getHistory = <int>[0xC6, 0x7C, 0xCF, 0x00, 0xD7, 0x52];
  static const clearHistory = <int>[0xC7, 0x46, 0xD8, 0x82];
  static const openSleep = <int>[0xAA, 0xCC, 0x00, 0x01, 0xDD, 0xEE];
  static const closeSleep = <int>[0xAA, 0xCC, 0x01, 0x01, 0xDD, 0xEE];

  /// The handshake's 4th frame (BatteryManager.setLowTemProtect).
  ///
  /// WARNING: this is a CMD_GATE_CONTROL write. Its payload has charge-MOS,
  /// discharge-MOS and temp-control gate all set to 1, so sending it can flip
  /// gates on the battery. It is NOT needed to read telemetry. Only send it if
  /// a particular BMS refuses to stream without the full handshake.
  static const lowTempGateFrame = <int>[
    0xC3, 0x1E, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD4, 0x3B,
  ];

  // Documented but UNUSED by this app (no caller; builders removed in review
  // pass B, L5). Kept here as protocol reference only:
  //   CMD_SEND_MTU  : `C3 F2 <mtu> ED CE`
  //   BLE rename    : [DeviceProfile.renamePrefix] ("AT+=") + ASCII name + CR LF
}

// ---------------------------------------------------------------------------
// CMD_GATE_CONTROL — the only *state-changing* write the app makes to the pack.
//
// Frame: begin sentinel C3 1E + 8 payload bytes + end sentinel D4 3B. The 8
// payload bytes, in order (verified against ../../docs/PROTOCOL.md
// "CMD_GATE_CONTROL payload" and artifacts/reverse/01-ble-protocol.md §1.5):
//   [0] chargeMos       1=on   0=off   (the "Charge" switch, #58)
//   [1] dischargeMos    1=on   0=off   (the "Output" switch, #58)
//   [2] tempControlGate 1=on   0=off
//   [3] smokeGate       1=on   0=off
//   [4] heatGate        1=on   0=off
//   [5] restart         1=perform (transient one-shot; the pack reboots)
//   [6] passiveBalance  1=on   0=off
//   [7] factory         1=perform (transient one-shot; factory reset)
//
// The vendor app re-sends the WHOLE frame on every setter, filling the untouched
// fields from the CURRENT cached gate values and flipping only the targeted
// byte. We replicate that from the live BAL_STATUS decode
// (chgMos/disMos/tempControlGate/smokeGate/heatGate/passiveBalancing) so a
// control write never clobbers the other gates. Restart and factory are
// transient one-shots and are never part of the base (0 unless requested).
// ---------------------------------------------------------------------------

/// Which gate a [buildGateControlFrame] call targets.
///
/// #58: the BMS has two independent MOSFET switches, carried as separate
/// bytes — [chargeMos] is byte[0] (the "Charge" switch: current INTO the
/// pack) and [dischargeMos] is byte[1] (the "Output" switch: current OUT of
/// the pack). Each flips ONLY its own byte. [bothMos] is the convenience
/// "Both on / Both off" that writes byte[0] AND byte[1] to the same value —
/// the vendor app's setMos (issue #26).
enum GateAction {
  chargeMos,
  dischargeMos,
  bothMos,
  tempControlGate,
  smokeGate,
  heatGate,
  restart,
  passiveBalance,
  factory,
}

/// #58: the user-facing name of the switch a MOS action drives — "charge"
/// (byte[0]), "output" (byte[1]) or "charge + output" (both). Other actions
/// give their enum name. Nothing user-facing says just "MOS".
String mosSwitchName(GateAction action) => switch (action) {
      GateAction.chargeMos => 'charge',
      GateAction.dischargeMos => 'output',
      GateAction.bothMos => 'charge + output',
      _ => action.name,
    };

/// #58: true for the three actions that drive a MOSFET switch.
bool isMosAction(GateAction action) =>
    action == GateAction.chargeMos ||
    action == GateAction.dischargeMos ||
    action == GateAction.bothMos;

/// CMD_GATE_CONTROL sentinels and payload byte positions.
class GateControl {
  /// Begin sentinel (`C3 1E`, BatteryCMD CMD_GATE_CONTROL_BEGIN).
  static const begin = <int>[0xC3, 0x1E];

  /// End sentinel (`D4 3B`, BatteryCMD CMD_GATE_CONTROL_END).
  static const end = <int>[0xD4, 0x3B];

  static const iChargeMos = 0;
  static const iDischargeMos = 1;
  static const iTempControlGate = 2;
  static const iSmokeGate = 3;
  static const iHeatGate = 4;
  static const iRestart = 5;
  static const iPassiveBalance = 6;
  static const iFactory = 7;
}

/// The six persistent gate values the BMS reports in BAL_STATUS, used as the
/// base for a gate-control write. Restart and factory are transient one-shots
/// and are never part of the base.
class GateSnapshot {
  final bool chargeMos;
  final bool dischargeMos;
  final int tempControlGate;
  final int smokeGate;
  final int heatGate;
  final bool passiveBalancing;

  const GateSnapshot({
    this.chargeMos = false,
    this.dischargeMos = false,
    this.tempControlGate = 0,
    this.smokeGate = 0,
    this.heatGate = 0,
    this.passiveBalancing = false,
  });

  /// Read the current known gate state from a decoded [BatteryState].
  ///
  /// SAFETY (audit C1): returns **null** when ANY of the six gates is still
  /// unknown (no BAL_STATUS decoded yet on this link). It must never default an
  /// unknown gate to 0 — a frame built from zeros writes chargeMos =
  /// dischargeMos = 0 (cutting the pack's output) or tempControlGate = 0
  /// (disabling low-temperature protection) as a side effect of an unrelated
  /// toggle. A null base means "refuse the write", never "assume off".
  static GateSnapshot? fromState(BatteryState s) {
    final chargeMos = s.chargeMos;
    final dischargeMos = s.dischargeMos;
    final tempControlGate = s.tempControlGate;
    final smokeGate = s.smokeGate;
    final heatGate = s.heatGate;
    final passiveBalancing = s.passiveBalancing;
    if (chargeMos == null ||
        dischargeMos == null ||
        tempControlGate == null ||
        smokeGate == null ||
        heatGate == null ||
        passiveBalancing == null) {
      return null;
    }
    return GateSnapshot(
      chargeMos: chargeMos,
      dischargeMos: dischargeMos,
      tempControlGate: tempControlGate,
      smokeGate: smokeGate,
      heatGate: heatGate,
      passiveBalancing: passiveBalancing,
    );
  }
}

/// Build a CMD_GATE_CONTROL frame that flips ONLY [action] to [on], keeping
/// every other gate at its current [base] value. Restart and factory ignore
/// [on] and are always set to 1. Returns begin + 8 payload bytes + end (12 B).
List<int> buildGateControlFrame({
  required GateSnapshot base,
  required GateAction action,
  bool on = true,
}) {
  // Start from the current cached gate values (only the target byte changes).
  final p = <int>[
    base.chargeMos ? 1 : 0, // [0]
    base.dischargeMos ? 1 : 0, // [1]
    base.tempControlGate == 0 ? 0 : 1, // [2]
    base.smokeGate == 0 ? 0 : 1, // [3]
    base.heatGate == 0 ? 0 : 1, // [4]
    0, // [5] restart (transient)
    base.passiveBalancing ? 1 : 0, // [6]
    0, // [7] factory (transient)
  ];
  final v = on ? 1 : 0;
  switch (action) {
    case GateAction.chargeMos:
      p[GateControl.iChargeMos] = v;
    case GateAction.dischargeMos:
      p[GateControl.iDischargeMos] = v;
    case GateAction.bothMos:
      // "Both on / off" (#58; the vendor setMos of issue #26): byte[0] AND
      // byte[1] move together to v; every other gate keeps its cached value.
      p[GateControl.iChargeMos] = v;
      p[GateControl.iDischargeMos] = v;
    case GateAction.tempControlGate:
      p[GateControl.iTempControlGate] = v;
    case GateAction.smokeGate:
      p[GateControl.iSmokeGate] = v;
    case GateAction.heatGate:
      p[GateControl.iHeatGate] = v;
    case GateAction.restart:
      p[GateControl.iRestart] = 1;
    case GateAction.passiveBalance:
      p[GateControl.iPassiveBalance] = v;
    case GateAction.factory:
      p[GateControl.iFactory] = 1;
  }
  return [...GateControl.begin, ...p, ...GateControl.end];
}

// ---------------------------------------------------------------------------
// CMD_BATTERY — rated-capacity (Ah) write (issue #38).
//
// Frame: begin sentinel C5 60 + 3 payload bytes + end sentinel D6 2A. The 3
// payload bytes are the rated capacity in mAh (capacityAh * 1000) as a 24-bit
// LITTLE-ENDIAN integer. Example: 100 Ah -> 100000 mAh -> 0x0186A0 -> A0 86 01,
// giving the full frame  C5 60 A0 86 01 D6 2A.
//
// Ack / read-back: the BMS replies with a SETTING_RESPOND frame (AB BA .. CD DC)
// whose type byte is 4 (capacity). The parser already records that as
// [BatteryState.capacityWriteAck]; the UI also watches [BatteryState.fullAh]
// updating to the written value. This is the ONLY parameter write the app makes.
// ---------------------------------------------------------------------------

class CapacityWrite {
  /// Begin sentinel (`C5 60`, BatteryCMD CMD_BATTERY begin).
  static const begin = <int>[0xC5, 0x60];

  /// End sentinel (`D6 2A`, BatteryCMD CMD_BATTERY end).
  static const end = <int>[0xD6, 0x2A];

  /// SETTING_RESPOND type byte that confirms a capacity write (byte0 == 4).
  static const ackType = 4;

  /// Sane rated-capacity bounds, in Ah, enforced before a write is ever built.
  static const minAh = 1.0;
  static const maxAh = 1000.0;
}

/// Build a CMD_BATTERY capacity-write frame for [capacityAh] rated amp-hours.
/// The payload is (capacityAh * 1000) rounded to mAh, encoded as a 24-bit
/// little-endian integer. Returns begin + 3 payload bytes + end (7 bytes).
///
/// Throws [ArgumentError] unless [capacityAh] is a finite value in the sane
/// range [CapacityWrite.minAh]..[CapacityWrite.maxAh], so an out-of-range or
/// nonsensical capacity can never be written to a pack.
List<int> buildCapacityWriteFrame(double capacityAh) {
  if (!capacityAh.isFinite ||
      capacityAh < CapacityWrite.minAh ||
      capacityAh > CapacityWrite.maxAh) {
    throw ArgumentError.value(capacityAh, 'capacityAh',
        'must be between ${CapacityWrite.minAh} and ${CapacityWrite.maxAh} Ah');
  }
  final mah = (capacityAh * 1000).round();
  return [
    ...CapacityWrite.begin,
    mah & 0xff, // 24-bit little-endian mAh
    (mah >> 8) & 0xff,
    (mah >> 16) & 0xff,
    ...CapacityWrite.end,
  ];
}

// ---------------------------------------------------------------------------
// Frame sentinels (BatteryCMD.java). Stored unsigned. Begin sentinels are
// `(b0, b1)` records so they can key the parser's dispatch table (records have
// value equality; const lists do not); end sentinels stay byte lists because
// they are matched positionally inside the buffer.
// ---------------------------------------------------------------------------

/// A 2-byte begin sentinel.
typedef _Begin = (int, int);

class _Cmd {
  static const _Begin volBegin = (0xA0, 0xC1);
  static const volEnd = [0xB1, 0xD2];
  static const _Begin tempBegin = (0xA1, 0x4F);
  static const tempEnd = [0xB2, 0xE3];
  static const _Begin allBegin = (0xA2, 0x57);
  static const allEnd = [0xB3, 0x6C];
  static const _Begin mosBegin = (0xA3, 0x9F);
  static const mosEnd = [0xB4, 0xC7];
  static const _Begin balBegin = (0xA8, 0xAC);
  static const balEnd = [0xB9, 0x21];
  static const _Begin socBegin = (0xA9, 0x64);
  static const socEnd = [0xBA, 0x5E];
  static const _Begin estBegin = (0xAA, 0xAF);
  static const estEnd = [0xBB, 0x22];
  static const _Begin verBegin = (0xAC, 0x9A);
  static const verEnd = [0xBD, 0x10];
  static const _Begin warnCurBegin = (0xA4, 0x8B);
  static const warnCurEnd = [0xB5, 0xDD];
  static const _Begin warnVolBegin = (0xA5, 0x99);
  static const warnVolEnd = [0xB6, 0x17];
  static const _Begin warnTempBegin = (0xA6, 0xC0);
  static const warnTempEnd = [0xB7, 0x72];
  static const _Begin otherBegin = (0xA7, 0x4E);
  static const _Begin gateSetBegin = (0xD2, 0x7E); // gate-control ack
  static const gateSetEnd = [0xFA, 0x4B];
  static const _Begin settingRespondBegin = (0xAB, 0xBA);
  static const settingRespondEnd = [0xCD, 0xDC];
  static const _Begin sleepBegin = (0xAC, 0xCA);
  static const sleepEnd = [0xDE, 0xED];
  static const _Begin historyBegin1 = (0xFE, 0xC9);
  static const _Begin historyBegin2 = (0xBD, 0x8A);
  static const historyEnd = [0xEA, 0x4F, 0x80, 0xDE];
  // #41 OTA replies (BatteryCMD.java:30-31, 67-69). Only consulted while
  // [BatteryParser.otaActive].
  static const _Begin otaRecallBegin = (0xFF, 0x01); // CMD_UPDATE_RECALL_1
  static const otaRecallTail = [0xB1, 0x02, 0xEF]; // CMD_UPDATE_RECALL_2
  static const _Begin otaAckBegin = (0x01, 0x01); // CMD_ACK_HEAD
  static const _Begin otaSuccessBegin = (0xAA, 0xBB); // CMD_UPDATE_SUCCESS_1
  static const otaSuccessTail = [0x01, 0x02, 0xEF]; // CMD_UPDATE_SUCCESS_2
}

/// SETTING_RESPOND (AB BA) type byte -> what was set, as the vendor app and
/// the Python reader name them. Only [CapacityWrite.ackType] (4) is acted on;
/// the rest are surfaced in the raw log for completeness (L2).
const settingAckTypes = <int, String>{
  1: 'voltage',
  2: 'current',
  3: 'temperature',
  4: 'capacity',
};

// ---------------------------------------------------------------------------
// Warning text, matching res/values/strings.xml.
// ---------------------------------------------------------------------------

// Only GENUINE (live) temperature faults live here. Temperature-alarm byte [2]
// is now understood (#50, live-confirmed): it is a LATCHED over-temperature
// protection flag — set by a PAST over-temp event, it stays at 1 (inhibiting
// charging while latched) until the BMS is restarted, which clears it. It is
// decoded as the first-class status [BatteryState.overTempLatched] and shown as
// a warning, NOT as a live fault (it does not set faultTemperature). Bytes [3]
// and [6] remain persistent firmware/MOS status bits of unknown meaning: they
// are captured as unknown-byte metrics (see _onWarnTemp) so any change is
// caught, and are likewise kept OUT of faultTemperature. Genuine faults: chip
// over/under = [0],[1]; under-temp discharge/charge = [4],[5].
const _warnTemp = <int, String>{
  0: 'Chip over temperature protection',
  1: 'Chip under temperature protection',
  4: 'Under temperature discharge protection',
  5: 'Under temperature charge protection',
};
const _warnCur = <int, String>{
  0: 'Over current discharge protection',
  1: 'Over current charge protection',
  2: 'Short circuit protection',
};
const _warnVol = <int, String>{
  0: 'Single cell over charge protection',
  1: 'Single cell over discharge protection',
  3: 'Voltage difference alarm',
  6: 'Overall voltage over charge protection',
  7: 'Overall voltage over discharge protection',
};

/// #67: every documented alarm byte by frame name (`'current'` /
/// `'voltage'` / `'temperature'`, the `WarningEvent.category` words), for the
/// alarm EVENT records. The temperature frame's latched byte [2] is named here
/// too (it is not a live fault, so it stays out of [_warnTemp]); any byte not
/// listed is an unknown byte.
const alarmBitNames = <String, Map<int, String>>{
  'current': _warnCur,
  'voltage': _warnVol,
  'temperature': {..._warnTemp, 2: 'Latched over-temperature protection'},
};

// ---------------------------------------------------------------------------
// Decoded telemetry, accumulated across frames.
// ---------------------------------------------------------------------------

enum ChargeState { idle, charging, discharging, unknown }

class BatteryState {
  // ALL_DATA (A2 57)
  double? packVoltage; // V
  double? packCurrent; // A (magnitude)
  double? power; // W
  bool? loadConnected;
  bool? chargerConnected;
  int? chipTemperature; // deg C
  double? cellSum; // V
  double? cellMax; // V
  double? cellMin; // V
  double? cellDiff; // V
  double? cellAvg; // V
  int? cycleCount;

  // VOL (A0 C1)
  List<int> cellsMv = const [];

  // TEMP (A1 4F): the frame carries FOUR signed-int8 temperature bytes. temp1
  // (byte[1]) and temp2 (byte[3]) are the primary probe pair; temp0 (byte[0])
  // and temp3 (byte[2]) are a second real pair (verified on hardware: they
  // track temp1/temp2 within +/-1 C and vary with temperature) — likely a
  // second probe pair or a min/max reading.
  int? temp0; // deg C, signed (byte[0])
  int? temp1; // deg C, signed (byte[1])
  int? temp2; // deg C, signed (byte[3])
  int? temp3; // deg C, signed (byte[2])

  // SOC (A9 64)
  int? socPercent;
  double? remainingAh;
  double? fullAh;

  // EST_TIME (AA AF)
  int? timeToFullSec;
  int? timeToEmptySec;

  // MOS_STATUS (A3 9F)
  bool? mosOn;

  // BAL_STATUS (A8 AC)
  ChargeState chargeState = ChargeState.unknown;
  bool? chargeMos;
  bool? dischargeMos;
  bool? passiveBalancing;
  int? tempControlGate;
  int? smokeGate;
  int? heatGate;

  // Alarms. The *Warnings lists hold only GENUINE fault text (temperature
  // excludes the persistent MOS/status bits [2],[3],[6] — see _warnTemp). The
  // fault* booleans are recomputed every cycle the alarm frame is seen, so an
  // alarm that clears is recorded as false (0), not left stuck.
  List<String> currentWarnings = const [];
  List<String> voltageWarnings = const [];
  List<String> temperatureWarnings = const [];
  bool faultCurrent = false;
  bool faultVoltage = false;
  bool faultTemperature = false;

  /// CMD_WARN_TEMP_ALARM byte[2] (#50): a LATCHED over-temperature protection.
  /// Set by a past over-temp event and held at 1 until the BMS is restarted;
  /// while latched the BMS inhibits charging (live-confirmed: a restart cleared
  /// it 1 -> 0). A WARNING, not a live fault — the pack is not over-temperature
  /// now — so it is deliberately separate from [faultTemperature].
  bool overTempLatched = false;

  /// True once at least one temperature-alarm frame has been decoded, so a
  /// logger can tell "latched = false" from "not reported yet".
  bool temperatureAlarmSeen = false;

  /// True once at least one current- / voltage-alarm frame has been decoded
  /// (M8): the packed `flags` row is only written once EVERY fault category has
  /// been reported, so a 0 fault bit means "clear", never "not yet known".
  bool currentAlarmSeen = false;
  bool voltageAlarmSeen = false;

  /// Frame bytes whose meaning is still unknown, captured verbatim as their own
  /// additive metrics (metric name -> raw unsigned byte). These are constant on
  /// current hardware; a decoder/logger watches them and raises a MAJOR alert
  /// the first time a previously-stable one changes. See the `unknown*` keys in
  /// [_onMos], [_onWarnCur], [_onWarnVol], [_onWarnTemp] and the OTHER handler.
  Map<String, int> unknownBytes = {};

  /// Count of stray bytes the parser has dropped on resync (issue #20). Every
  /// increment corresponds to one `UNRECOGNISED` line in the raw log — no byte
  /// is ever silently discarded. #60: the AT+V status byte '0' (0x30, after
  /// AT+V was sent on the link) is classified separately and NOT counted here.
  /// Includes any other stray byte and any
  /// byte that never forms a recognised frame.
  int unrecognisedBytes = 0;

  // VERSION (AC 9A)
  String? firmwareVersion;

  // SLEEP_SET_SUCCESS (AC CA): app sets sleep-mode pref true iff byte0 == 0.
  bool? sleepModeOn;

  // SETTING_RESPOND (AB BA): the app fires batteryRes(true) ONLY when byte0 == 4
  // (the capacity-write ack). Other values (1/2/3) are defined but never acted on.
  bool? capacityWriteAck;

  // GATE_SET (D2 7E): echo of the 8 CMD_GATE_CONTROL fields, in payload order:
  // [chargeMos, dischargeMos, tempGate, smokeGate, heatGate, restart,
  //  passiveBalance, factoryReset].
  List<bool> gateAck = const [];

  // Signal strength from the BLE scan advertisement (not part of the frame
  // protocol). Captured from ScanResult.rssi.
  int? rssi;

  // Identity (from BLE advertised name; not part of the frame protocol).
  String? serial;
}

// ---------------------------------------------------------------------------
// Events emitted per parsed frame (for logging / reactive UIs).
// ---------------------------------------------------------------------------

sealed class BatteryEvent {
  const BatteryEvent();

  /// Plain-English, human-readable name for this frame/event. These replace the
  /// vendor's RX_*/CMD_* constant names everywhere a label is shown or logged.
  String get label;
}

class AllDataEvent extends BatteryEvent {
  const AllDataEvent();
  @override
  String get label => 'Battery data';
}

class VoltageEvent extends BatteryEvent {
  const VoltageEvent();
  @override
  String get label => 'Cell voltages';
}

class TempEvent extends BatteryEvent {
  const TempEvent();
  @override
  String get label => 'Temperatures';
}

class SocEvent extends BatteryEvent {
  const SocEvent();
  @override
  String get label => 'State of charge';
}

class EstTimeEvent extends BatteryEvent {
  const EstTimeEvent();
  @override
  String get label => 'Time estimate';
}

class MosEvent extends BatteryEvent {
  const MosEvent();
  @override
  String get label => 'MOS status';
}

class BalancerEvent extends BatteryEvent {
  const BalancerEvent();
  @override
  String get label => 'Balancer status';
}

class WarningEvent extends BatteryEvent {
  final String category; // current | voltage | temperature
  const WarningEvent(this.category);
  @override
  String get label => switch (category) {
        'current' => 'Current alarm',
        'voltage' => 'Voltage alarm',
        'temperature' => 'Temperature alarm',
        _ => 'Alarm',
      };
}

class VersionEvent extends BatteryEvent {
  const VersionEvent();
  @override
  String get label => 'Firmware version';
}

class SleepEvent extends BatteryEvent {
  const SleepEvent();
  @override
  String get label => 'Sleep';
}

/// SETTING_RESPOND (AB BA): emitted for EVERY setting ack (L2, matching the
/// Python reader) carrying the raw [type] byte — 1 voltage, 2 current,
/// 3 temperature, 4 capacity (see [settingAckTypes]). Only type 4 also sets
/// [BatteryState.capacityWriteAck]; the others just reach the raw log.
class SettingRespondEvent extends BatteryEvent {
  final int type;
  const SettingRespondEvent([this.type = 0]);

  /// Human name for [type], or 'unknown'.
  String get typeName => settingAckTypes[type] ?? 'unknown';

  @override
  String get label => 'Setting ack';
}

class GateSetEvent extends BatteryEvent {
  const GateSetEvent();
  @override
  String get label => 'Gate set';
}

/// OTHER (A7 4E): a 9-byte blob whose meaning is UNDETERMINED. All 9 bytes after
/// the begin are captured as unknown-byte metrics so any change is caught.
///
/// The trailing `b8 29` of the blob is only an UNPROVEN end-sentinel HYPOTHESIS
/// (a pattern-match: begin A7 + 0x11 = B8), NOT confirmed framing. We deliberately
/// do NOT treat those two bytes as an end sentinel — they are captured as data
/// (bytes [7] and [8]) like the rest. The meaning of CMD_OTHER stays undetermined
/// pending a live test.
class OtherEvent extends BatteryEvent {
  const OtherEvent();
  @override
  String get label => 'Other data';
}

// ---------------------------------------------------------------------------
// Firmware-update (OTA) replies — #41. Decoded ONLY while
// [BatteryParser.otaActive] is set by an [OtaSession]; outside an update these
// byte patterns stay unrecognised exactly as before, so the telemetry decoder
// is untouched. The full derived spec is at the top of ota_update.dart.
// ---------------------------------------------------------------------------

/// CMD_UPDATE_RECALL `FF 01 B1 02 EF` (BatteryCMD.java:67-68; handled at
/// BatteryManager.java:825-834): the BMS's "go" after CMD_BEGIN_UPDATE. Also
/// restarts the transfer from chunk 0 if it arrives mid-transfer.
class OtaRecallEvent extends BatteryEvent {
  const OtaRecallEvent();
  @override
  String get label => 'OTA recall';
}

/// Per-chunk ACK `01 01 <numHi> <numLo> <status> <sum>` (BatteryCMD.java:69
/// CMD_ACK_HEAD; BatteryManager.java:835-862): 2-byte head + 4 bytes. The
/// app compares the BIG-endian chunk number ([chunk], ByteUtils:45-47
/// byteToIntHigh) and [checksum] against getRecallSum (BM:982-984);
/// [status] (the 3rd byte) is read but NEVER compared by the vendor.
class OtaAckEvent extends BatteryEvent {
  final int chunk;
  final int status;
  final int checksum;
  const OtaAckEvent(this.chunk, this.status, this.checksum);
  @override
  String get label => 'OTA chunk ack';
}

/// CMD_UPDATE_SUCCESS `AA BB 01 02 EF` (BatteryCMD.java:30-31; handled at
/// BatteryManager.java:864-873): the BMS accepted the whole image.
class OtaSuccessEvent extends BatteryEvent {
  const OtaSuccessEvent();
  @override
  String get label => 'OTA success';
}

/// True for the three firmware-update replies — answers to the OTA session,
/// never part of the telemetry stream.
bool isOtaEvent(BatteryEvent e) =>
    e is OtaRecallEvent || e is OtaAckEvent || e is OtaSuccessEvent;

// ---------------------------------------------------------------------------
// Streaming parser with byte-level resync.
//
// The wire protocol has no length or checksum: each frame is a 2-byte begin
// sentinel, a fixed (or count-prefixed) payload, and a 2-byte end sentinel.
// The BMS streams frames back-to-back over FCF2 notifications. Notifications
// can split or coalesce frames, so we buffer and drain.
//
// Unlike the app's pair-aligned reader (which desyncs permanently on a dropped
// byte), this drops a single byte and rescans on any mismatch, so it recovers.
// ---------------------------------------------------------------------------

class BatteryParser {
  final BatteryState state;
  final void Function(BatteryEvent event)? onEvent;

  /// Called with each stray byte the resync path drops (issue #20), so the raw
  /// log can record it as an UNRECOGNISED line. The per-battery running total is
  /// also kept in [BatteryState.unrecognisedBytes].
  final void Function(int byte)? onUnrecognisedByte;

  final List<int> _buf = [];

  /// Raw bytes of the frame most recently parsed (begin + payload + end). Valid
  /// synchronously inside an [onEvent] callback, so a logger can show the exact
  /// bytes that produced the decoded line.
  List<int> lastFrameBytes = const [];

  /// #60: called with the ASCII '0' (0x30) status byte the firmware's AT
  /// bridge returns for `AT+V` (proven by the live A/B test, #23). Only
  /// classified as such once [atVersionSent] is true for this link; it is
  /// NOT counted in [BatteryState.unrecognisedBytes] and NOT reported through
  /// [onUnrecognisedByte].
  final void Function(int byte)? onAtStatusByte;

  /// #60: set by the connection once `AT+V` has been sent on the current
  /// link; cleared by [reset] (a new link). While false, a stray 0x30 is
  /// still an unrecognised byte.
  bool atVersionSent = false;

  /// #41: set by an [OtaSession] for the duration of a firmware update. While
  /// true the three OTA replies (RECALL `FF 01 B1 02 EF`, per-chunk ACK
  /// `01 01 + 4`, SUCCESS `AA BB 01 02 EF`) are decoded; while false those
  /// byte patterns are unrecognised exactly as before, so the telemetry
  /// decoder is unchanged outside an update. Cleared by [reset] (a new link).
  bool otaActive = false;

  BatteryParser({
    BatteryState? state,
    this.onEvent,
    this.onUnrecognisedByte,
    this.onAtStatusByte,
  }) : state = state ?? BatteryState();

  void addBytes(List<int> data) {
    _buf.addAll(data);
    _drain();
  }

  void reset() {
    _buf.clear();
    atVersionSent = false;
    otaActive = false;
  }

  /// The AT bridge's status/return-code character for `AT+V` (#60).
  static const int atStatusByte = 0x30;

  bool _match(int at, List<int> sentinel) {
    if (at + sentinel.length > _buf.length) return false;
    for (var i = 0; i < sentinel.length; i++) {
      if ((_buf[at + i] & 0xff) != sentinel[i]) return false;
    }
    return true;
  }

  void _emit(BatteryEvent e) => onEvent?.call(e);

  /// Table-driven dispatch for every FIXED-length frame (L4, mirroring the
  /// Python reader's `Parser.FIXED`): begin sentinel -> (payload length
  /// INCLUDING the 2 end bytes, end sentinel, handler). VOL (count-prefixed),
  /// OTHER (no end sentinel) and HISTORY (4-byte end, variable) are the only
  /// frames handled outside this table — see [_tryFrameAt0].
  late final Map<_Begin, (int, List<int>, void Function(Uint8List))> _fixed = {
    _Cmd.tempBegin: (6, _Cmd.tempEnd, _onTemp),
    _Cmd.allBegin: (24, _Cmd.allEnd, _onAll),
    _Cmd.mosBegin: (8, _Cmd.mosEnd, _onMos),
    _Cmd.balBegin: (9, _Cmd.balEnd, _onBal),
    _Cmd.socBegin: (9, _Cmd.socEnd, _onSoc),
    _Cmd.estBegin: (8, _Cmd.estEnd, _onEst),
    _Cmd.verBegin: (7, _Cmd.verEnd, _onVer),
    _Cmd.warnCurBegin: (7, _Cmd.warnCurEnd, _onWarnCur),
    _Cmd.warnVolBegin: (11, _Cmd.warnVolEnd, _onWarnVol),
    _Cmd.warnTempBegin: (9, _Cmd.warnTempEnd, _onWarnTemp),
    // SLEEP_SET_SUCCESS: the app reads 3 bytes and does NOT check the end
    // sentinel, but the reference decoder validates it for resync safety.
    _Cmd.sleepBegin: (3, _Cmd.sleepEnd, _onSleep),
    // SETTING_RESPOND: setting ack; the capacity ack is type [0]==4.
    _Cmd.settingRespondBegin: (3, _Cmd.settingRespondEnd, _onSetting),
    // GATE_SET: gate-control ack, echoing the 8 gate fields.
    _Cmd.gateSetBegin: (10, _Cmd.gateSetEnd, _onGateSet),
  };

  /// The begin sentinels the parser recognises (fixed table + the three
  /// specially-framed ones). Exposed for tests / the protocol audit.
  Set<(int, int)> get knownBegins => {
        ..._fixed.keys,
        _Cmd.volBegin,
        _Cmd.otherBegin,
        _Cmd.historyBegin1,
        _Cmd.historyBegin2,
      };

  /// #41: the OTA reply begin sentinels, recognised ONLY while [otaActive].
  Set<(int, int)> get otaBegins =>
      {_Cmd.otaRecallBegin, _Cmd.otaAckBegin, _Cmd.otaSuccessBegin};

  void _drain() {
    while (_buf.length >= 2) {
      final consumed = _tryFrameAt0();
      if (consumed == 0) {
        // Not enough bytes yet for a recognised frame: wait for more.
        return;
      }
      if (consumed < 0) {
        // Unknown begin or bad end sentinel: drop one byte, resync. Every frame
        // in the spec is decoded above, so a dropped byte is either the KNOWN
        // AT+V status byte '0' (#60 — once AT+V went out on this link) or
        // genuinely unrecognised data (an undocumented frame). Either way it
        // is surfaced — no byte is ever silently dropped.
        final dropped = _buf[0] & 0xff;
        if (dropped == atStatusByte && atVersionSent) {
          onAtStatusByte?.call(dropped);
        } else {
          state.unrecognisedBytes++;
          onUnrecognisedByte?.call(dropped);
        }
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, consumed);
    }
    // #62: a LONE trailing 0x30 — the bridge's whole answer to AT+V on a
    // pack whose BMS is not running — would otherwise sit here waiting for a
    // second byte that never comes. No frame begins with 0x30, so once AT+V
    // has gone out it is consumed as the status byte at once.
    if (_buf.length == 1 &&
        (_buf[0] & 0xff) == atStatusByte &&
        atVersionSent) {
      onAtStatusByte?.call(atStatusByte);
      _buf.clear();
    }
  }

  /// Returns bytes consumed (>0), 0 if it needs more bytes, or -1 to resync.
  int _tryFrameAt0() {
    final begin = (_buf[0] & 0xff, _buf[1] & 0xff);

    // #41: OTA replies, only during a firmware update (see [otaActive]).
    if (otaActive) {
      if (begin == _Cmd.otaRecallBegin) {
        return _parseOtaTail(_Cmd.otaRecallTail, const OtaRecallEvent());
      }
      if (begin == _Cmd.otaSuccessBegin) {
        return _parseOtaTail(_Cmd.otaSuccessTail, const OtaSuccessEvent());
      }
      if (begin == _Cmd.otaAckBegin) return _parseOtaAck();
    }

    // Fixed-length frames: [begin(2)] + payloadLen (which already includes the
    // 2 end bytes) — one table lookup (L4).
    final fixed = _fixed[begin];
    if (fixed != null) {
      final (len, end, handler) = fixed;
      return _parseFixed(len, end, handler);
    }
    // VOL (A0 C1): count-prefixed, variable length.
    if (begin == _Cmd.volBegin) return _parseVol();
    // OTHER (A7 4E): 9-byte blob of UNDETERMINED meaning. The app discards it;
    // here we capture ALL 9 bytes as unknown-byte metrics so a change is caught.
    // The trailing `b8 29` is only an UNPROVEN end-sentinel hypothesis (A7 +
    // 0x11 = B8 pattern-match), NOT confirmed framing, so bytes [7]/[8] are
    // captured as data, not treated as a sentinel. See [_parseOther].
    if (begin == _Cmd.otherBegin) return _parseOther();
    // HISTORY (FE C9 / BD 8A): recognised only to stay aligned; not decoded.
    if (begin == _Cmd.historyBegin1 || begin == _Cmd.historyBegin2) {
      return _parseHistory();
    }

    return -1; // unknown begin
  }

  /// #41: RECALL / SUCCESS — a 2-byte head then a fixed 3-byte tail that the
  /// vendor reads and byte-compares whole (BatteryManager.java:828, 867). A
  /// mismatching tail is a resync (-1), never a decoded frame.
  int _parseOtaTail(List<int> tail, BatteryEvent event) {
    final total = 2 + tail.length;
    if (_buf.length < total) return 0;
    if (!_match(2, tail)) return -1;
    lastFrameBytes = _buf.sublist(0, total);
    _emit(event);
    return total;
  }

  /// #41: per-chunk ACK — `01 01` then exactly 4 bytes
  /// (BatteryManager.java:836-837 `mIO.read(bArr31, 0, 4)`): chunk number
  /// (u16 BIG-endian), a status byte the vendor never checks, and the
  /// checksum. There is no end sentinel, so nothing here can be validated;
  /// the session does the number/checksum comparison.
  int _parseOtaAck() {
    const total = 6;
    if (_buf.length < total) return 0;
    lastFrameBytes = _buf.sublist(0, total);
    final chunk = ((_buf[2] & 0xff) << 8) | (_buf[3] & 0xff);
    _emit(OtaAckEvent(chunk, _buf[4] & 0xff, _buf[5] & 0xff));
    return total;
  }

  /// payloadLen = bytes after the 2 begin bytes, INCLUDING the 2 end bytes.
  int _parseFixed(int payloadLen, List<int> end, void Function(Uint8List) f) {
    final total = 2 + payloadLen;
    if (_buf.length < total) return 0; // need more
    // end sentinel occupies the last 2 bytes of the payload
    final endAt = 2 + payloadLen - 2;
    if (!_match(endAt, end)) return -1; // bad frame, resync
    lastFrameBytes = _buf.sublist(0, total); // full frame, for the raw log
    final payload = Uint8List.fromList(_buf.sublist(2, 2 + payloadLen));
    f(payload);
    return total;
  }

  /// OTHER (A7 4E): begin + 9 bytes of UNDETERMINED meaning. Capture ALL 9 as
  /// unknown-byte metrics — including bytes [7]/[8]. The trailing `b8 29` is only
  /// an UNPROVEN end-sentinel hypothesis (A7 + 0x11 = B8 pattern-match), NOT
  /// confirmed framing, so it is NOT stripped as a sentinel; the meaning of
  /// CMD_OTHER stays undetermined pending a live test.
  int _parseOther() {
    const payloadLen = 9;
    const total = 2 + payloadLen;
    if (_buf.length < total) return 0;
    lastFrameBytes = _buf.sublist(0, total); // full blob, for the raw log
    for (var i = 0; i < payloadLen; i++) {
      _unknown('unknownOtherB$i', _buf[2 + i]);
    }
    _emit(const OtherEvent());
    return total;
  }

  /// Record a raw unsigned byte whose meaning is unknown as its own metric.
  void _unknown(String name, int b) => state.unknownBytes[name] = b & 0xff;

  // --- HISTORY (FE C9 / BD 8A): variable length, ends at a 4-byte sentinel ---
  // The app has no history decoder at all; it can only request history. Here we
  // recognise a history frame and consume up to its 4-byte end sentinel so the
  // stream stays aligned. The payload is never decoded.
  int _parseHistory() {
    final endIdx = _indexOf(_Cmd.historyEnd, 2);
    if (endIdx < 0) {
      // End not yet in the buffer: wait for more, unless it is implausibly long.
      return _buf.length > 1024 ? -1 : 0;
    }
    final total = endIdx + _Cmd.historyEnd.length;
    lastFrameBytes = _buf.sublist(0, total); // full frame, for the raw log
    return total;
  }

  int _indexOf(List<int> pattern, int from) {
    for (var i = from; i + pattern.length <= _buf.length; i++) {
      var ok = true;
      for (var j = 0; j < pattern.length; j++) {
        if ((_buf[i + j] & 0xff) != pattern[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  // --- VOL (A0 C1): [begin][count][count*2 cells LE][end] ------------------
  int _parseVol() {
    if (_buf.length < 3) return 0;
    final count = _buf[2] & 0xff;
    final total = 2 + 1 + count * 2 + 2;
    if (_buf.length < total) return 0;
    final endAt = 2 + 1 + count * 2;
    if (!_match(endAt, _Cmd.volEnd)) return -1;
    lastFrameBytes = _buf.sublist(0, total); // full frame, for the raw log
    final cells = <int>[];
    for (var i = 0; i < count; i++) {
      final o = 3 + i * 2;
      cells.add(_u16le(_buf[o], _buf[o + 1]));
    }
    state.cellsMv = cells;
    _emit(const VoltageEvent());
    return total;
  }

  // --- TEMP (A1 4F): payload[6], end at [4],[5] ----------------------------
  // Four signed-int8 temperature bytes. temp1 = [1], temp2 = [3] (primary
  // pair); temp0 = [0], temp3 = [2] are a second real pair on hardware.
  void _onTemp(Uint8List p) {
    state.temp0 = _s8(p[0]);
    state.temp1 = _s8(p[1]);
    state.temp3 = _s8(p[2]);
    state.temp2 = _s8(p[3]);
    _emit(const TempEvent());
  }

  // --- ALL_DATA (A2 57): payload[24], end at [22],[23] ---------------------
  void _onAll(Uint8List p) {
    final s = state;
    s.packVoltage = _u16le(p[0], p[1]) / 10.0;
    // allCur = (uint24LE(p2,p3,p4) / 100) / 10.0  — integer /100 then float /10
    s.packCurrent = (_u24le(p[2], p[3], p[4]) ~/ 100) / 10.0;
    s.loadConnected = p[5] != 0;
    s.chargerConnected = p[6] != 0;
    s.chipTemperature = p[7] & 0xff;
    s.cellSum = _u16le(p[8], p[9]) / 10.0;
    s.cellMax = (_u16le(p[10], p[11]) ~/ 10) / 100.0;
    s.cellMin = (_u16le(p[12], p[13]) ~/ 10) / 100.0;
    s.cellDiff = (_u16le(p[14], p[15]) ~/ 10) / 100.0;
    s.power = _u16le(p[16], p[17]) / 10.0;
    s.cycleCount = _u16le(p[18], p[19]);
    s.cellAvg = (_u16le(p[20], p[21]) ~/ 10) / 100.0;
    _emit(const AllDataEvent());
  }

  // --- MOS_STATUS (A3 9F): payload[8], end at [6],[7]; on iff [0]==1 && [1]==1
  // Bytes [2],[3],[4],[5] are unknown — captured verbatim.
  void _onMos(Uint8List p) {
    state.mosOn = p[0] == 1 && p[1] == 1;
    _unknown('unknownMosB2', p[2]);
    _unknown('unknownMosB3', p[3]);
    _unknown('unknownMosB4', p[4]);
    _unknown('unknownMosB5', p[5]);
    _emit(const MosEvent());
  }

  // --- BAL_STATUS (A8 AC): payload[9], end at [7],[8] ----------------------
  void _onBal(Uint8List p) {
    final s = state;
    s.chargeState = switch (p[0] & 0xff) {
      0 => ChargeState.idle,
      1 => ChargeState.charging,
      2 => ChargeState.discharging,
      _ => ChargeState.unknown,
    };
    s.chargeMos = p[1] == 1;
    s.dischargeMos = p[2] == 1;
    s.passiveBalancing = p[3] == 1;
    s.tempControlGate = p[4] & 0xff;
    s.smokeGate = p[5] & 0xff;
    s.heatGate = p[6] & 0xff;
    _emit(const BalancerEvent());
  }

  // --- SOC (A9 64): payload[9], end at [7],[8] -----------------------------
  void _onSoc(Uint8List p) {
    // Unsigned byte: only the upper clamp can ever apply (L1).
    var soc = p[0] & 0xff;
    if (soc > 100) soc = 100;
    state.socPercent = soc;
    // getSOC(soc, fByteToLong2/1000, fByteToLong/1000):
    //   fByteToLong2 = bytes[4,5,6] -> remaining Ah (shown as "x.xx AH")
    //   fByteToLong  = bytes[1,2,3] -> full/rated Ah
    state.remainingAh = _u24le(p[4], p[5], p[6]) / 1000.0;
    state.fullAh = _u24le(p[1], p[2], p[3]) / 1000.0;
    _emit(const SocEvent());
  }

  // --- EST_TIME (AA AF): payload[8], end at [6],[7] ------------------------
  void _onEst(Uint8List p) {
    // secondToTime(jByteToLong2=bytes0-2) shown when charging (time to full),
    // secondToTime(jByteToLong=bytes3-5) shown when discharging (time to empty)
    state.timeToFullSec = _u24le(p[0], p[1], p[2]);
    state.timeToEmptySec = _u24le(p[3], p[4], p[5]);
    _emit(const EstTimeEvent());
  }

  // --- VERSION (AC 9A): payload[7], 5 ASCII chars then end -----------------
  void _onVer(Uint8List p) {
    state.firmwareVersion = String.fromCharCodes(p.sublist(0, 5));
    _emit(const VersionEvent());
  }

  // --- SLEEP_SET_SUCCESS (AC CA): payload[3], sleep on iff [0]==0 ----------
  void _onSleep(Uint8List p) {
    state.sleepModeOn = p[0] == 0; // app: byte0 == 0 => sleep mode on
    _emit(const SleepEvent());
  }

  // --- SETTING_RESPOND (AB BA): payload[3]; [0] = setting type ------------
  void _onSetting(Uint8List p) {
    final type = p[0] & 0xff;
    // The app calls batteryRes(true) only for the capacity-write ack ([0]==4);
    // every other type is still emitted (L2) so it reaches the raw log.
    if (type == CapacityWrite.ackType) state.capacityWriteAck = true;
    _emit(SettingRespondEvent(type));
  }

  // --- GATE_SET (D2 7E): payload[10], [0..7] echo gate fields as booleans --
  void _onGateSet(Uint8List p) {
    state.gateAck = [for (var i = 0; i < 8; i++) p[i] == 1];
    _emit(const GateSetEvent());
  }

  // Current alarm (A4 8B): payload[7], end at [5],[6]. Bytes [3],[4] unknown.
  void _onWarnCur(Uint8List p) {
    state.currentWarnings = _collect(p, _warnCur);
    state.faultCurrent = state.currentWarnings.isNotEmpty; // cleared -> false
    state.currentAlarmSeen = true;
    _unknown('unknownCurB3', p[3]);
    _unknown('unknownCurB4', p[4]);
    _emit(const WarningEvent('current'));
  }

  // Voltage alarm (A5 99): payload[11], end at [9],[10]. Bytes [2],[4],[5],[8]
  // unknown.
  void _onWarnVol(Uint8List p) {
    state.voltageWarnings = _collect(p, _warnVol);
    state.faultVoltage = state.voltageWarnings.isNotEmpty; // cleared -> false
    state.voltageAlarmSeen = true;
    _unknown('unknownVolB2', p[2]);
    _unknown('unknownVolB4', p[4]);
    _unknown('unknownVolB5', p[5]);
    _unknown('unknownVolB8', p[8]);
    _emit(const WarningEvent('voltage'));
  }

  // Temperature alarm (A6 C0): payload[9], end at [7],[8]. Only GENUINE bits
  // ([0],[1],[4],[5]) set faultTemperature. Byte [2] is the LATCHED
  // over-temperature protection (#50: set by a past over-temp event, inhibits
  // charging, cleared by a BMS restart) — decoded as [BatteryState.overTempLatched]
  // and NOT counted as a live fault nor as an unknown byte. Bytes [3],[6] are
  // still-unexplained status bits — captured as unknown metrics, not a fault.
  void _onWarnTemp(Uint8List p) {
    state.temperatureWarnings = _collect(p, _warnTemp);
    state.faultTemperature =
        state.temperatureWarnings.isNotEmpty; // cleared -> false
    state.overTempLatched = p[2] == 1; // cleared (by restart) -> false
    state.temperatureAlarmSeen = true;
    _unknown('unknownTempB3', p[3]);
    _unknown('unknownTempB6', p[6]);
    _emit(const WarningEvent('temperature'));
  }

  List<String> _collect(Uint8List p, Map<int, String> table) {
    final out = <String>[];
    table.forEach((idx, text) {
      if (idx < p.length && p[idx] == 1 && !out.contains(text)) out.add(text);
    });
    return out;
  }
}
