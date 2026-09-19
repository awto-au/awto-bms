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

  /// CMD_SEND_MTU: `C3 F2 <mtu> ED CE`.
  List<int> sendMtu(int mtu) => [0xC3, 0xF2, mtu & 0xff, 0xED, 0xCE];

  /// Set the advertised BLE name (profile-specific prefix + ASCII + CRLF).
  List<int> setName(String name) => [
        ...profile.renamePrefix,
        ...name.codeUnits,
        0x0D,
        0x0A,
      ];
}

// ---------------------------------------------------------------------------
// Frame sentinels (BatteryCMD.java). Stored unsigned.
// ---------------------------------------------------------------------------

class _Cmd {
  static const volBegin = [0xA0, 0xC1];
  static const volEnd = [0xB1, 0xD2];
  static const tempBegin = [0xA1, 0x4F];
  static const tempEnd = [0xB2, 0xE3];
  static const allBegin = [0xA2, 0x57];
  static const allEnd = [0xB3, 0x6C];
  static const mosBegin = [0xA3, 0x9F];
  static const mosEnd = [0xB4, 0xC7];
  static const balBegin = [0xA8, 0xAC];
  static const balEnd = [0xB9, 0x21];
  static const socBegin = [0xA9, 0x64];
  static const socEnd = [0xBA, 0x5E];
  static const estBegin = [0xAA, 0xAF];
  static const estEnd = [0xBB, 0x22];
  static const verBegin = [0xAC, 0x9A];
  static const verEnd = [0xBD, 0x10];
  static const warnCurBegin = [0xA4, 0x8B];
  static const warnCurEnd = [0xB5, 0xDD];
  static const warnVolBegin = [0xA5, 0x99];
  static const warnVolEnd = [0xB6, 0x17];
  static const warnTempBegin = [0xA6, 0xC0];
  static const warnTempEnd = [0xB7, 0x72];
  static const otherBegin = [0xA7, 0x4E];
  static const gateSetBegin = [0xD2, 0x7E]; // gate-control ack
  static const gateSetEnd = [0xFA, 0x4B];
  static const settingRespondBegin = [0xAB, 0xBA];
  static const settingRespondEnd = [0xCD, 0xDC];
  static const sleepBegin = [0xAC, 0xCA];
  static const sleepEnd = [0xDE, 0xED];
  static const historyBegin1 = [0xFE, 0xC9];
  static const historyBegin2 = [0xBD, 0x8A];
  static const historyEnd = [0xEA, 0x4F, 0x80, 0xDE];
}

// ---------------------------------------------------------------------------
// Warning text, matching res/values/strings.xml.
// ---------------------------------------------------------------------------

const _warnTemp = <int, String>{
  0: 'Chip over temperature protection',
  1: 'Chip under temperature protection',
  2: 'MOS over temperature protection',
  3: 'MOS over temperature protection',
  4: 'Under temperature discharge protection',
  5: 'Under temperature charge protection',
  6: 'MOS over temperature protection',
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

  // TEMP (A1 4F)
  int? temp1; // deg C, signed
  int? temp2; // deg C, signed

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

  // Alarms
  List<String> currentWarnings = const [];
  List<String> voltageWarnings = const [];
  List<String> temperatureWarnings = const [];

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

  DateTime? lastUpdate;
}

// ---------------------------------------------------------------------------
// Events emitted per parsed frame (for logging / reactive UIs).
// ---------------------------------------------------------------------------

sealed class BatteryEvent {
  const BatteryEvent();
}

class AllDataEvent extends BatteryEvent {
  const AllDataEvent();
}

class VoltageEvent extends BatteryEvent {
  const VoltageEvent();
}

class TempEvent extends BatteryEvent {
  const TempEvent();
}

class SocEvent extends BatteryEvent {
  const SocEvent();
}

class EstTimeEvent extends BatteryEvent {
  const EstTimeEvent();
}

class MosEvent extends BatteryEvent {
  const MosEvent();
}

class BalancerEvent extends BatteryEvent {
  const BalancerEvent();
}

class WarningEvent extends BatteryEvent {
  final String category; // current | voltage | temperature
  const WarningEvent(this.category);
}

class VersionEvent extends BatteryEvent {
  const VersionEvent();
}

class SleepEvent extends BatteryEvent {
  const SleepEvent();
}

class SettingRespondEvent extends BatteryEvent {
  const SettingRespondEvent();
}

class GateSetEvent extends BatteryEvent {
  const GateSetEvent();
}

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

  final List<int> _buf = [];

  BatteryParser({BatteryState? state, this.onEvent})
      : state = state ?? BatteryState();

  void addBytes(List<int> data) {
    _buf.addAll(data);
    _drain();
  }

  void reset() => _buf.clear();

  bool _match(int at, List<int> sentinel) {
    if (at + sentinel.length > _buf.length) return false;
    for (var i = 0; i < sentinel.length; i++) {
      if ((_buf[at + i] & 0xff) != sentinel[i]) return false;
    }
    return true;
  }

  void _emit(BatteryEvent e) {
    state.lastUpdate = DateTime.now();
    onEvent?.call(e);
  }

  void _drain() {
    while (_buf.length >= 2) {
      final consumed = _tryFrameAt0();
      if (consumed == 0) {
        // Not enough bytes yet for a recognised frame: wait for more.
        return;
      }
      if (consumed < 0) {
        // Unknown begin or bad end sentinel: drop one byte, resync.
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, consumed);
    }
  }

  /// Returns bytes consumed (>0), 0 if it needs more bytes, or -1 to resync.
  int _tryFrameAt0() {
    final b0 = _buf[0] & 0xff, b1 = _buf[1] & 0xff;

    // Fixed-length frames: [begin(2)] + payloadLen + [end(2)] already inside n.
    // The map value is the total frame length; the last 2 bytes are the end.
    // VOL is handled separately (count-prefixed, variable).
    if (b0 == 0xA0 && b1 == 0xC1) return _parseVol();
    if (b0 == 0xA1 && b1 == 0x4F) return _parseFixed(6, _Cmd.tempEnd, _onTemp);
    if (b0 == 0xA2 && b1 == 0x57) return _parseFixed(24, _Cmd.allEnd, _onAll);
    if (b0 == 0xA3 && b1 == 0x9F) return _parseFixed(8, _Cmd.mosEnd, _onMos);
    if (b0 == 0xA8 && b1 == 0xAC) return _parseFixed(9, _Cmd.balEnd, _onBal);
    if (b0 == 0xA9 && b1 == 0x64) return _parseFixed(9, _Cmd.socEnd, _onSoc);
    if (b0 == 0xAA && b1 == 0xAF) return _parseFixed(8, _Cmd.estEnd, _onEst);
    if (b0 == 0xAC && b1 == 0x9A) return _parseFixed(7, _Cmd.verEnd, _onVer);
    if (b0 == 0xA4 && b1 == 0x8B) {
      return _parseFixed(7, _Cmd.warnCurEnd, _onWarnCur);
    }
    if (b0 == 0xA5 && b1 == 0x99) {
      return _parseFixed(11, _Cmd.warnVolEnd, _onWarnVol);
    }
    if (b0 == 0xA6 && b1 == 0xC0) {
      return _parseFixed(9, _Cmd.warnTempEnd, _onWarnTemp);
    }
    // SLEEP_SET_SUCCESS (AC CA): the app reads 3 bytes and does NOT check the
    // end sentinel, but the reference decoder validates it for resync safety.
    if (b0 == 0xAC && b1 == 0xCA) {
      return _parseFixed(3, _Cmd.sleepEnd, _onSleep);
    }
    // SETTING_RESPOND (AB BA): capacity-write ack (only meaningful when [0]==4).
    if (b0 == 0xAB && b1 == 0xBA) {
      return _parseFixed(3, _Cmd.settingRespondEnd, _onSetting);
    }
    // GATE_SET (D2 7E): gate-control ack, echoing the 8 gate fields.
    if (b0 == 0xD2 && b1 == 0x7E) {
      return _parseFixed(10, _Cmd.gateSetEnd, _onGateSet);
    }
    // OTHER (A7 4E): 9 bytes read and discarded by the app; no end check.
    if (b0 == 0xA7 && b1 == 0x4E) return _skipFixed(9);
    // HISTORY (FE C9 / BD 8A): recognised only to stay aligned; not decoded.
    if ((b0 == 0xFE && b1 == 0xC9) || (b0 == 0xBD && b1 == 0x8A)) {
      return _parseHistory();
    }

    return -1; // unknown begin
  }

  /// payloadLen = bytes after the 2 begin bytes, INCLUDING the 2 end bytes.
  int _parseFixed(int payloadLen, List<int> end, void Function(Uint8List) f) {
    final total = 2 + payloadLen;
    if (_buf.length < total) return 0; // need more
    // end sentinel occupies the last 2 bytes of the payload
    final endAt = 2 + payloadLen - 2;
    if (!_match(endAt, end)) return -1; // bad frame, resync
    final payload = Uint8List.fromList(_buf.sublist(2, 2 + payloadLen));
    f(payload);
    return total;
  }

  int _skipFixed(int payloadLen) {
    final total = 2 + payloadLen;
    if (_buf.length < total) return 0;
    return total;
  }

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
    return endIdx + _Cmd.historyEnd.length;
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
    final cells = <int>[];
    for (var i = 0; i < count; i++) {
      final o = 3 + i * 2;
      cells.add(_u16le(_buf[o], _buf[o + 1]));
    }
    state.cellsMv = cells;
    _emit(const VoltageEvent());
    return total;
  }

  // --- TEMP (A1 4F): payload[6], end at [4],[5]; temps at [1] and [3] ------
  void _onTemp(Uint8List p) {
    state.temp1 = _s8(p[1]);
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

  // --- MOS_STATUS (A3 9F): payload[8], on iff [0]==1 && [1]==1 -------------
  void _onMos(Uint8List p) {
    state.mosOn = p[0] == 1 && p[1] == 1;
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
    var soc = p[0] & 0xff;
    if (soc > 100) soc = 100;
    if (soc < 0) soc = 0;
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

  // --- SETTING_RESPOND (AB BA): payload[3]; ack only when [0]==4 -----------
  void _onSetting(Uint8List p) {
    // The app calls batteryRes(true) only for the capacity-write ack ([0]==4).
    if (p[0] == 4) {
      state.capacityWriteAck = true;
      _emit(const SettingRespondEvent());
    }
  }

  // --- GATE_SET (D2 7E): payload[10], [0..7] echo gate fields as booleans --
  void _onGateSet(Uint8List p) {
    state.gateAck = [for (var i = 0; i < 8; i++) p[i] == 1];
    _emit(const GateSetEvent());
  }

  void _onWarnCur(Uint8List p) {
    state.currentWarnings = _collect(p, _warnCur);
    _emit(const WarningEvent('current'));
  }

  void _onWarnVol(Uint8List p) {
    state.voltageWarnings = _collect(p, _warnVol);
    _emit(const WarningEvent('voltage'));
  }

  void _onWarnTemp(Uint8List p) {
    state.temperatureWarnings = _collect(p, _warnTemp);
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
