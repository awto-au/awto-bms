/// Read-only telemetry codecs for the non-JoySuny BMS families (issue #75).
///
/// [bms_families.dart] recognises these families at scan time. This module adds
/// what a connection needs to actually READ them: the GATT UUIDs, the poll
/// commands, a streaming frame assembler with checksum validation, and a decoder
/// into a family-neutral [FamilySample] that [FamilySample.applyTo] maps onto the
/// app's [BatteryState].
///
/// Every protocol is ported from `patman15/aiobmsble` (Apache-2.0), file noted
/// per codec; the offsets there are the ground truth. The unit tests
/// (`test/bms_codecs_test.dart`) replay that project's captured frames and check
/// the values its own tests expect. NOT verified against a physical pack of any
/// of these families.
///
/// READ-ONLY by design: no codec builds a switch, gate, OTA or settings frame.
/// JoySuny keeps its own full-featured path ([BatteryParser]); it has no codec.
///
/// Pure Dart (no Flutter import), like battery_protocol.dart.
library;

import 'dart:convert' show ascii;

import 'battery_protocol.dart';
import 'bms_families.dart';

// ---------------------------------------------------------------------------
// Family-neutral sample
// ---------------------------------------------------------------------------

/// One decoded reply. Every field is optional: a family that splits its data
/// over several replies (JBD info + cells, Daly MOS + main, SmartBat registers)
/// emits one partial sample per reply and [applyTo] merges only what is set.
class FamilySample {
  double? voltage; // V
  double? current; // A, signed: + charging, − discharging (aiobmsble sign)
  double? socPercent;
  double? remainingAh;
  double? fullAh; // design capacity
  int? cycles;
  List<int>? cellsMv;
  List<double>? temps; // cell / generic sensors, °C
  double? mosTemp; // MOSFET sensor, °C
  bool? chargeMos;
  bool? dischargeMos;
  int? problemCode; // raw vendor alarm bits; 0 = none
  String? firmware;

  bool get isEmpty =>
      voltage == null &&
      current == null &&
      socPercent == null &&
      remainingAh == null &&
      fullAh == null &&
      cycles == null &&
      cellsMv == null &&
      temps == null &&
      mosTemp == null &&
      chargeMos == null &&
      dischargeMos == null &&
      problemCode == null &&
      firmware == null;

  /// Merge the fields this sample carries into [s]. Current is split into the
  /// app's magnitude + direction ([BatteryState.packCurrent] is a magnitude and
  /// [BatteryState.chargeState] carries the sign). Temperatures map onto the
  /// two display sensors: the first reading is "Temp A", the second "Temp B".
  void applyTo(BatteryState s) {
    final v = voltage;
    final i = current;
    if (v != null) s.packVoltage = v;
    if (i != null) {
      s.packCurrent = i.abs();
      s.chargeState = i > currentDeadbandA
          ? ChargeState.charging
          : i < -currentDeadbandA
              ? ChargeState.discharging
              : ChargeState.idle;
    }
    if (v != null || i != null) {
      final pv = s.packVoltage, pi = s.packCurrent;
      if (pv != null && pi != null) s.power = pv * pi;
    }
    if (socPercent != null) s.socPercent = socPercent!.round();
    if (remainingAh != null) s.remainingAh = remainingAh;
    if (fullAh != null) s.fullAh = fullAh;
    if (cycles != null) s.cycleCount = cycles;
    final cells = cellsMv;
    if (cells != null && cells.isNotEmpty) {
      s.cellsMv = List.unmodifiable(cells);
      final max = cells.reduce((a, b) => a > b ? a : b);
      final min = cells.reduce((a, b) => a < b ? a : b);
      final sum = cells.fold<int>(0, (a, b) => a + b);
      s.cellMax = max / 1000;
      s.cellMin = min / 1000;
      s.cellDiff = (max - min) / 1000;
      s.cellSum = sum / 1000;
      s.cellAvg = sum / cells.length / 1000;
    }
    final t = temps;
    if (t != null) {
      s.temp2 = t.isNotEmpty ? t[0].round() : null; // Temp A
      s.temp1 = t.length > 1 ? t[1].round() : null; // Temp B
    }
    if (mosTemp != null) s.chipTemperature = mosTemp!.round();
    if (chargeMos != null) s.chargeMos = chargeMos;
    if (dischargeMos != null) {
      s.dischargeMos = dischargeMos;
      s.mosOn = dischargeMos;
    }
    if (firmware != null && firmware!.isNotEmpty) s.firmwareVersion = firmware;
  }

  /// Below this |current| the pack is shown idle, not charging/discharging.
  static const double currentDeadbandA = 0.05;

  @override
  String toString() => [
        if (voltage != null) 'V=$voltage',
        if (current != null) 'I=$current',
        if (socPercent != null) 'SOC=$socPercent',
        if (remainingAh != null) 'rem=${remainingAh}Ah',
        if (fullAh != null) 'full=${fullAh}Ah',
        if (cycles != null) 'cyc=$cycles',
        if (cellsMv != null) 'cells=$cellsMv',
        if (temps != null) 'T=$temps',
        if (mosTemp != null) 'Tmos=$mosTemp',
        if (chargeMos != null) 'chg=$chargeMos',
        if (dischargeMos != null) 'dis=$dischargeMos',
        if (problemCode != null) 'prob=$problemCode',
        if (firmware != null) 'fw=$firmware',
      ].join(' ');
}

// ---------------------------------------------------------------------------
// Codec interface + factory
// ---------------------------------------------------------------------------

/// What a connection needs to poll and decode one family.
abstract class BmsCodec {
  /// Family label, matching [BmsFamily.name].
  String get family;

  /// 128-bit lowercase GATT UUIDs.
  String get serviceUuid;
  String get notifyUuid;
  String get writeUuid;

  /// How often [pollCommands] is asked for the next cycle.
  Duration get pollInterval => const Duration(seconds: 2);

  /// Gap between two writes of one cycle, so a slow BMS answers each in turn.
  Duration get commandGap => const Duration(milliseconds: 300);

  /// The commands to write for the next poll cycle, in order (may be empty
  /// when the BMS streams on its own).
  List<List<int>> pollCommands();

  /// Feed one notification. Returns every sample completed by these bytes.
  List<FamilySample> addBytes(List<int> data);

  /// Forget buffered bytes and per-link state (called on every (re)connect).
  void reset();
}

/// The codec for [f], or null when the family has none (JoySuny uses the
/// dedicated [BatteryParser] path; an unknown family stays detect-only).
/// [name] is the advertised name; SmartBat derives its cipher key from it.
BmsCodec? codecForFamily(BmsFamily f, {String name = ''}) => switch (f.name) {
      'JBD / Xiaoxiang' || 'Stealth BMS' => JbdCodec(),
      'JK-BMS' => JkCodec(),
      'ANT-BMS' => AntCodec(),
      'Daly BMS' => DalyCodec(),
      'Redodo / LiTime' => RedodoCodec(),
      'LiFePO4POWER / Offgridtec' => OgtCodec.forName(name).orNullIfUnknown,
      _ => null,
    };

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

int _u(List<int> b, int pos, int size, {bool little = false}) {
  var v = 0;
  for (var k = 0; k < size; k++) {
    final byte = b[little ? pos + size - 1 - k : pos + k];
    v = (v << 8) | (byte & 0xFF);
  }
  return v;
}

int _s(List<int> b, int pos, int size, {bool little = false}) {
  final v = _u(b, pos, size, little: little);
  final bit = 1 << (size * 8 - 1);
  return (v & bit) != 0 ? v - (bit << 1) : v;
}

bool _fits(List<int> b, int pos, int size) => pos >= 0 && pos + size <= b.length;

int _sum(Iterable<int> b) => b.fold(0, (a, x) => a + (x & 0xFF));

/// CRC-16/MODBUS (poly 0xA001 reflected, init 0xFFFF).
int crcModbus(Iterable<int> data) {
  var crc = 0xFFFF;
  for (final b in data) {
    crc ^= b & 0xFF;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}

/// ASCII up to the first non-printable byte, trimmed (aiobmsble `b2str`).
String _b2str(List<int> b) {
  final out = StringBuffer();
  for (final c in b) {
    if (c < 0x20 || c > 0x7E) break;
    out.writeCharCode(c);
  }
  return out.toString().trim();
}

/// Leading decimal digits as an int, 0 when there are none.
int _leadingInt(String s) {
  final m = RegExp(r'^\d+').firstMatch(s);
  return m == null ? 0 : int.parse(m.group(0)!);
}

/// Cell voltages in mV: [count] values of [size] bytes from [start]; zero
/// readings (unpopulated slots) are skipped, as aiobmsble does.
List<int> _cells(List<int> b, int start, int count,
    {bool little = false, int size = 2}) {
  final out = <int>[];
  for (var k = 0; k < count; k++) {
    final pos = start + k * size;
    if (!_fits(b, pos, size)) break;
    final v = _u(b, pos, size, little: little);
    if (v != 0) out.add(v);
  }
  return out;
}

// ---------------------------------------------------------------------------
// JBD / Xiaoxiang / Stealth — aiobmsble/bms/jbd_bms.py
// FF00 service, FF01 notify, FF02 write. Big-endian.
// Request  DD A5 reg 00 crcHi crcLo 77
// Response DD reg status len data… crcHi crcLo 77, crc = 0x10000 − Σ(status..data)
// ---------------------------------------------------------------------------

class JbdCodec implements BmsCodec {
  @override
  String get family => 'JBD / Xiaoxiang';
  @override
  String get serviceUuid => u16('ff00');
  @override
  String get notifyUuid => u16('ff01');
  @override
  String get writeUuid => u16('ff02');
  @override
  Duration get pollInterval => const Duration(seconds: 2);
  @override
  Duration get commandGap => const Duration(milliseconds: 300);

  static const int regInfo = 0x03;
  static const int regCells = 0x04;

  static List<int> command(int reg) {
    final body = [reg, 0x00];
    final crc = (0x10000 - _sum(body)) & 0xFFFF;
    return [0xDD, 0xA5, ...body, crc >> 8, crc & 0xFF, 0x77];
  }

  @override
  List<List<int>> pollCommands() => [command(regInfo), command(regCells)];

  final List<int> _buf = [];

  @override
  void reset() => _buf.clear();

  @override
  List<FamilySample> addBytes(List<int> data) {
    _buf.addAll(data);
    final out = <FamilySample>[];
    while (true) {
      final start = _buf.indexOf(0xDD);
      if (start < 0) {
        _buf.clear();
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      if (_buf.length < 7) break;
      final total = 7 + _buf[3];
      if (_buf.length < total) break;
      final frame = _buf.sublist(0, total);
      final crc = (0x10000 - _sum(frame.sublist(2, total - 3))) & 0xFFFF;
      if (frame[total - 1] != 0x77 || _u(frame, total - 3, 2) != crc) {
        _buf.removeAt(0); // resync on the next 0xDD
        continue;
      }
      _buf.removeRange(0, total);
      if (frame[2] != 0x00) continue; // error status
      final s = decode(frame);
      if (s != null) out.add(s);
    }
    return out;
  }

  /// Decode one checked frame (header included, as aiobmsble's offsets are).
  static FamilySample? decode(List<int> f) {
    switch (f[1]) {
      case regInfo:
        if (f.length < 7 + 23) return null;
        final ntc = f[26];
        return FamilySample()
          ..voltage = _u(f, 4, 2) / 100
          ..current = _s(f, 6, 2) / 100
          ..remainingAh = _u(f, 8, 2) / 100
          ..fullAh = (_u(f, 10, 2) ~/ 100).toDouble()
          ..cycles = _u(f, 12, 2)
          ..problemCode = _u(f, 20, 2)
          ..firmware = '${f[22] >> 4}.${f[22] & 0xF}'
          ..socPercent = f[23].toDouble()
          ..chargeMos = f[24] & 0x1 != 0
          ..dischargeMos = f[24] & 0x2 != 0
          ..temps = [
            for (var k = 0; k < ntc && _fits(f, 27 + 2 * k, 2) &&
                    27 + 2 * k + 2 <= f.length - 3;
                k++)
              (_u(f, 27 + 2 * k, 2) - 2731) / 10,
          ];
      case regCells:
        final n = f[3] ~/ 2;
        return FamilySample()..cellsMv = _cells(f, 4, n > 32 ? 32 : n);
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// JK (Jikong) JK02 — aiobmsble/bms/jikong_bms.py
// FFE0 service, FFE1 notify + write. Little-endian, 300-byte replies with
// header 55 AA EB 90, type at [4] (0x02 cell info, 0x03 device info),
// crc = Σ[0..298] & 0xFF at [299]. Request 20 B: AA 55 90 EB cmd len 0×13 crc.
// 24S layout (firmware < 11) is the 32S layout shifted −32 after the cells.
// ---------------------------------------------------------------------------

class JkCodec implements BmsCodec {
  @override
  String get family => 'JK-BMS';
  @override
  String get serviceUuid => u16('ffe0');
  @override
  String get notifyUuid => u16('ffe1');
  @override
  String get writeUuid => u16('ffe1');
  @override
  Duration get pollInterval => const Duration(seconds: 2);
  @override
  Duration get commandGap => const Duration(milliseconds: 300);

  static const List<int> _head = [0x55, 0xAA, 0xEB, 0x90];
  static const List<int> _at = [0x41, 0x54, 0x0D, 0x0A]; // "AT\r\n"
  static const int frameLen = 300;
  static const int cmdCellInfo = 0x96;
  static const int cmdDeviceInfo = 0x97;

  static List<int> command(int cmd) {
    final frame = [0xAA, 0x55, 0x90, 0xEB, cmd, 0x00, ...List.filled(13, 0)];
    return [...frame, _sum(frame) & 0xFF];
  }

  /// Firmware major version from the device-info reply; null until seen.
  int? swVersion;
  bool _cellSeenSincePoll = false;
  final List<int> _buf = [];

  @override
  void reset() {
    _buf.clear();
    swVersion = null;
    _cellSeenSincePoll = false;
  }

  @override
  List<List<int>> pollCommands() {
    if (swVersion == null) {
      return [command(cmdDeviceInfo), command(cmdCellInfo)];
    }
    // The BMS keeps streaming cell info after one request; re-ask only when
    // nothing arrived since the last poll.
    final seen = _cellSeenSincePoll;
    _cellSeenSincePoll = false;
    return seen ? const [] : [command(cmdCellInfo)];
  }

  static bool _startsWith(List<int> b, List<int> p) {
    if (b.length < p.length) return false;
    for (var k = 0; k < p.length; k++) {
      if (b[k] != p[k]) return false;
    }
    return true;
  }

  @override
  List<FamilySample> addBytes(List<int> data) {
    var d = data;
    if (_startsWith(d, _at)) d = d.sublist(4); // BLE module chatter
    if (_startsWith(d, _head)) _buf.clear();
    if (_buf.isEmpty && !_startsWith(d, _head)) return const [];
    _buf.addAll(d);
    if (_buf.length < frameLen) return const [];
    final frame = _buf.sublist(0, frameLen);
    _buf.clear();
    if (_sum(frame.sublist(0, frameLen - 1)) & 0xFF != frame[frameLen - 1]) {
      return const [];
    }
    final s = decode(frame);
    return s == null ? const [] : [s];
  }

  FamilySample? decode(List<int> f) {
    switch (f[4]) {
      case 0x03:
        final fw = _b2str(f.sublist(30, 38));
        swVersion = _leadingInt(fw);
        return FamilySample()..firmware = fw;
      case 0x02:
        final sw = swVersion;
        if (sw == null) return null; // layout unknown until device info
        _cellSeenSincePoll = true;
        return decodeCells(f, sw);
    }
    return null;
  }

  /// Decode a cell-info frame for firmware major [sw].
  static FamilySample decodeCells(List<int> f, int sw) {
    final o = sw < 11 ? -32 : 0;
    final h = o ~/ 2;
    int u(int pos, int size) => _u(f, pos + o, size, little: true);
    final cellMask = _u(f, 70 + h, 4, little: true);
    var cellCount = 0;
    for (var m = cellMask; m != 0; m >>= 1) {
      cellCount += m & 1;
    }
    final tempMask = _s(f, 214 + o, 2, little: true);
    final positions = sw >= 14
        ? const [(144, true), (162, false), (164, false), (254, true), (256, false), (258, false)]
        : sw >= 11
            ? const [(144, true), (162, false), (164, false), (254, true)]
            : const [(130, false), (132, false), (134, true)];
    final temps = <double>[];
    double? mos;
    for (var k = 0; k < positions.length; k++) {
      if (tempMask & (1 << k) == 0) continue;
      final (pos, isMos) = positions[k];
      final raw = _s(f, pos, 2, little: true);
      if (raw == -2000) continue;
      if (isMos) {
        mos ??= raw / 10;
      } else {
        temps.add(raw / 10);
      }
    }
    return FamilySample()
      ..voltage = u(150, 4) / 1000
      ..current = _s(f, 158 + o, 4, little: true) / 1000
      ..problemCode = o != 0 ? u(166, 4) >> 16 : u(166, 4) & 0xFFFF
      ..socPercent = f[173 + o].toDouble()
      ..remainingAh = u(174, 4) / 1000
      ..fullAh = (u(178, 4) ~/ 1000).toDouble()
      ..cycles = u(182, 4)
      ..chargeMos = f[198 + o] != 0
      ..dischargeMos = f[199 + o] != 0
      ..cellsMv = _cells(f, 6, cellCount, little: true)
      ..temps = temps
      ..mosTemp = mos;
  }
}

// ---------------------------------------------------------------------------
// ANT — aiobmsble/bms/ant_bms.py
// FFE0 service, FFE1 notify + write. Little-endian.
// Frame 7E A1 type adrLo adrHi len data… crcLo crcHi AA 55,
// crc = CRC-16/MODBUS over [1 .. end−4). Reply type = request | 0x10.
// ---------------------------------------------------------------------------

class AntCodec implements BmsCodec {
  @override
  String get family => 'ANT-BMS';
  @override
  String get serviceUuid => u16('ffe0');
  @override
  String get notifyUuid => u16('ffe1');
  @override
  String get writeUuid => u16('ffe1');
  @override
  Duration get pollInterval => const Duration(seconds: 2);
  @override
  Duration get commandGap => const Duration(milliseconds: 300);

  static const int cmdStatus = 0x01;
  static const int cmdDevice = 0x02;
  static const int _minLen = 10;

  static List<int> command(int cmd, int adr, int len) {
    final frame = [0x7E, 0xA1, cmd, adr & 0xFF, adr >> 8, len];
    final crc = crcModbus(frame.sublist(1));
    return [...frame, crc & 0xFF, crc >> 8, 0xAA, 0x55];
  }

  bool _deviceAsked = false;
  final List<int> _buf = [];

  @override
  void reset() {
    _buf.clear();
    _deviceAsked = false;
  }

  @override
  List<List<int>> pollCommands() => [
        if (!_deviceAsked) command(cmdDevice, 0x026C, 0x20),
        command(cmdStatus, 0x0000, 0xBE),
      ].also((_) => _deviceAsked = true);

  @override
  List<FamilySample> addBytes(List<int> data) {
    _buf.addAll(data);
    final out = <FamilySample>[];
    while (true) {
      var start = -1;
      for (var k = 0; k + 1 < _buf.length; k++) {
        if (_buf[k] == 0x7E && _buf[k + 1] == 0xA1) {
          start = k;
          break;
        }
      }
      if (start < 0) {
        if (_buf.length > 1) _buf.removeRange(0, _buf.length - 1);
        break;
      }
      if (start > 0) _buf.removeRange(0, start);
      if (_buf.length < _minLen) break;
      final exp = _buf[5] + _minLen;
      if (_buf.length < exp) break;
      final f = _buf.sublist(0, exp);
      final crc = crcModbus(f.sublist(1, exp - 4));
      if (f[exp - 2] != 0xAA || f[exp - 1] != 0x55 ||
          _u(f, exp - 4, 2, little: true) != crc) {
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, exp);
      final s = decode(f);
      if (s != null) out.add(s);
    }
    return out;
  }

  static FamilySample? decode(List<int> f) {
    if (f[2] == (cmdDevice | 0x10)) {
      return FamilySample()..firmware = _b2str(f.sublist(22, f.length < 38 ? f.length : 38));
    }
    if (f[2] != (cmdStatus | 0x10)) return null;
    final cells = f[9] > 32 ? 32 : f[9];
    final ntc = f[8] > 6 ? 6 : f[8];
    final tStart = 34 + cells * 2;
    final raw = [
      for (var k = 0; k < ntc + 2 && _fits(f, tStart + 2 * k, 2); k++)
        _s(f, tStart + 2 * k, 2, little: true).toDouble(),
    ];
    final o = (ntc + cells) * 2;
    return FamilySample()
      ..cellsMv = _cells(f, 34, cells, little: true)
      ..temps = raw.take(ntc).toList()
      ..mosTemp = raw.length > ntc ? raw[ntc] : null
      ..voltage = _u(f, 38 + o, 2, little: true) / 100
      ..current = _s(f, 40 + o, 2, little: true) / 10
      ..socPercent = _u(f, 42 + o, 2, little: true).toDouble()
      ..fullAh = (_u(f, 50 + o, 4, little: true) ~/ 1000000).toDouble()
      ..remainingAh = _u(f, 54 + o, 4, little: true) / 1e6
      ..chargeMos = f[46 + o] == 0x1
      ..dischargeMos = f[47 + o] == 0x1
      ..problemCode = _antProblem(_u(f, 46 + o, 2, little: true));
  }

  /// The two nibbles of the MOS-state word that are real faults
  /// (aiobmsble's `problem_code` mask: 1 / 4 / 0xB / 0xF are normal states).
  static int _antProblem(int x) =>
      (![0x1, 0x4, 0xF].contains(x >> 8) ? x & 0xF00 : 0) |
      (![0x1, 0x4, 0xB, 0xF].contains(x & 0xF) ? x & 0xF : 0);
}

extension _Also<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

// ---------------------------------------------------------------------------
// Daly — aiobmsble/bms/daly_bms.py
// FFF0 service, FFF1 notify, FFF2 write. Modbus-style, big-endian.
// Request  dev 03 addrHi addrLo cntHi cntLo crcLo crcHi (CRC-16/MODBUS)
// Reply    resp 03 byteCount data… crcLo crcHi
// Two variants: D2 (dev/resp 0xD2) and the newer 0x81 (dev 0x81, resp 0x51).
// The variant is unknown until one of them answers; both are probed.
// ---------------------------------------------------------------------------

enum DalyVariant { d2, x81 }

class DalyCodec implements BmsCodec {
  @override
  String get family => 'Daly BMS';
  @override
  String get serviceUuid => u16('fff0');
  @override
  String get notifyUuid => u16('fff1');
  @override
  String get writeUuid => u16('fff2');
  @override
  Duration get pollInterval => const Duration(seconds: 3);
  @override
  Duration get commandGap => const Duration(milliseconds: 400);

  static List<int> command(int dev, int addr, int count) {
    final f = [dev, 0x03, addr >> 8, addr & 0xFF, count >> 8, count & 0xFF];
    final crc = crcModbus(f);
    return [...f, crc & 0xFF, crc >> 8];
  }

  static const int _d2Dev = 0xD2, _x81Dev = 0x81, _x81Resp = 0x51;

  DalyVariant? variant;
  bool _infoAsked = false;

  /// D2: whether the MOS-temperature block is worth reading (null: unknown).
  bool? _mosAvail;
  final List<int> _buf = [];

  @override
  void reset() {
    _buf.clear();
    variant = null;
    _infoAsked = false;
    _mosAvail = null;
  }

  @override
  List<List<int>> pollCommands() {
    switch (variant) {
      case null:
        return [command(_d2Dev, 0x00, 62), command(_x81Dev, 0x00, 64)];
      case DalyVariant.d2:
        return [
          if (!_infoAsked) command(_d2Dev, 0xA9, 32),
          if (_mosAvail != false) command(_d2Dev, 0x3E, 9),
          command(_d2Dev, 0x00, 62),
        ].also((_) => _infoAsked = true);
      case DalyVariant.x81:
        return [
          if (!_infoAsked) command(_x81Dev, 0x178, 74),
          command(_x81Dev, 0x00, 64),
          command(_x81Dev, 0x41, 62),
        ].also((_) => _infoAsked = true);
    }
  }

  @override
  List<FamilySample> addBytes(List<int> data) {
    _buf.addAll(data);
    final out = <FamilySample>[];
    while (_buf.isNotEmpty) {
      final head = _buf[0];
      if (head != _d2Dev && head != _x81Resp) {
        _buf.removeAt(0);
        continue;
      }
      if (_buf.length < 3) break;
      if (_buf[1] != 0x03) {
        _buf.removeAt(0);
        continue;
      }
      final total = _buf[2] + 5;
      if (_buf.length < total) break;
      final f = _buf.sublist(0, total);
      if (_u(f, total - 2, 2, little: true) != crcModbus(f.sublist(0, total - 2))) {
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, total);
      variant ??= head == _d2Dev ? DalyVariant.d2 : DalyVariant.x81;
      final s = decode(f);
      if (s != null && !s.isEmpty) out.add(s);
    }
    return out;
  }

  FamilySample? decode(List<int> f) {
    final regs = f[2] ~/ 2;
    if (f[0] == _d2Dev) {
      switch (regs) {
        case 62:
          return decodeD2Main(f);
        case 9:
          final raw = f.sublist(11, 13);
          if ((raw[0] == 0 && raw[1] == 0) || (raw[0] == 0xFF && raw[1] == 0xFF)) {
            _mosAvail = false;
            return null;
          }
          _mosAvail = true;
          return FamilySample()..mosTemp = (_u(f, 11, 2) - 40).toDouble();
        case 32:
          return FamilySample()..firmware = _b2str(f.sublist(3, 19));
      }
      return null;
    }
    switch (regs) {
      case 64:
        return decodeX81Live(f);
      case 62:
        return decodeX81Status(f);
      case 74:
        return FamilySample()..firmware = _b2str(f.sublist(3, 31));
    }
    return null;
  }

  static List<double> _temps(List<int> f, int start, int count) => [
        for (var k = 0; k < count && _fits(f, start + 2 * k, 2); k++)
          if (_s(f, start + 2 * k, 2) != 0) (_s(f, start + 2 * k, 2) - 40).toDouble(),
      ];

  /// D2 main block (62 registers). Field offsets are relative to the data
  /// start (3), exactly as aiobmsble's `start=_HEAD_LEN`.
  static FamilySample decodeD2Main(List<int> f) {
    int u(int pos, [int size = 2]) => _u(f, 3 + pos, size);
    final cells = u(98) > 32 ? 32 : u(98);
    final ntc = u(100) > 8 ? 8 : u(100);
    return FamilySample()
      ..voltage = u(80) / 10
      ..current = (u(82) - 30000) / 10
      ..socPercent = u(84) / 10
      ..remainingAh = u(96) / 10
      ..cycles = u(102)
      ..problemCode = u(116, 8)
      ..chargeMos = u(106) != 0
      ..dischargeMos = u(108) != 0
      ..cellsMv = _cells(f, 3, cells)
      ..temps = _temps(f, 3 + 32 * 2, ntc);
  }

  /// 0x81 live block (64 registers at 0x00): voltage, current, SOC, cells, temps.
  static FamilySample decodeX81Live(List<int> f) {
    int u(int pos) => _u(f, 3 + pos, 2);
    final cells = u(120) > 48 ? 48 : u(120);
    final ntc = u(122) > 8 ? 8 : u(122);
    return FamilySample()
      ..voltage = u(112) / 10
      ..current = (u(114) - 30000) / 10
      ..socPercent = u(116) / 10
      ..cellsMv = _cells(f, 3, cells)
      ..temps = _temps(f, 3 + 48 * 2, ntc);
  }

  /// 0x81 status block (62 registers at 0x41): capacity, cycles, MOS, alarms.
  static FamilySample decodeX81Status(List<int> f) {
    int u(int pos, [int size = 2]) => _u(f, 3 + pos, size);
    return FamilySample()
      ..remainingAh = u(20) / 10
      ..cycles = u(22)
      ..problemCode = u(88, 4)
      ..chargeMos = u(34) != 0
      ..dischargeMos = u(36) != 0;
  }
}

// ---------------------------------------------------------------------------
// Redodo / LiTime / Power Queen — aiobmsble/bms/redodo_bms.py
// FFE0 service, FFE1 notify, FFE2 write. Little-endian.
// Request 00 00 04 01 13 55 AA 17. Reply 00 00 len data… crc, crc = Σ[..−1].
// ---------------------------------------------------------------------------

class RedodoCodec implements BmsCodec {
  @override
  String get family => 'Redodo / LiTime';
  @override
  String get serviceUuid => u16('ffe0');
  @override
  String get notifyUuid => u16('ffe1');
  @override
  String get writeUuid => u16('ffe2');
  @override
  Duration get pollInterval => const Duration(seconds: 2);
  @override
  Duration get commandGap => const Duration(milliseconds: 300);

  static const List<int> request = [0x00, 0x00, 0x04, 0x01, 0x13, 0x55, 0xAA, 0x17];

  int _sensors = 1;
  final List<int> _buf = [];

  @override
  void reset() {
    _buf.clear();
    _sensors = 1;
  }

  @override
  List<List<int>> pollCommands() => const [request];

  @override
  List<FamilySample> addBytes(List<int> data) {
    _buf.addAll(data);
    final out = <FamilySample>[];
    while (_buf.length >= 3) {
      if (_buf[0] != 0 || _buf[1] != 0) {
        _buf.removeAt(0);
        continue;
      }
      final total = _buf[2] + 4;
      if (_buf.length < total) break;
      final f = _buf.sublist(0, total);
      if (_sum(f.sublist(0, total - 1)) & 0xFF != f[total - 1]) {
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, total);
      if (total < 100) continue; // an ack / short reply, not the status block
      out.add(decode(f));
    }
    return out;
  }

  FamilySample decode(List<int> f) {
    final raw = [
      for (var k = 0; k < 5; k++) _s(f, 52 + 2 * k, 2, little: true).toDouble(),
    ];
    for (var i = 5; i > 1; i--) {
      if (raw[i - 1] != 0) {
        if (i > _sensors) _sensors = i;
        break;
      }
    }
    return FamilySample()
      ..voltage = _u(f, 12, 2, little: true) / 1000
      ..current = _s(f, 48, 4, little: true) / 1000
      ..socPercent = _u(f, 90, 2, little: true).toDouble()
      ..remainingAh = _u(f, 62, 2, little: true) / 100
      ..fullAh = (_u(f, 64, 4, little: true) ~/ 100).toDouble()
      ..cycles = _u(f, 96, 4, little: true)
      ..problemCode = _u(f, 76, 8, little: true)
      ..cellsMv = _cells(f, 16, 16, little: true)
      ..temps = raw.take(_sensors).toList();
  }
}

// ---------------------------------------------------------------------------
// LiFePO4POWER / Offgridtec "SmartBat-A/B" — aiobmsble/bms/ogt_bms.py
// FFF0 service, FFF4 notify, FFF6 write. ASCII register protocol, every byte
// XOR-ed with a key derived from the advertised serial ("SmartBat-B12294").
// Request "+RAA"/"+R16" + reg(2 hex) + len(2 hex). Reply "+RD," + reg + value
// + "\r\n", or "+RD,Err".
// ---------------------------------------------------------------------------

class OgtCodec implements BmsCodec {
  @override
  String get family => 'LiFePO4POWER / Offgridtec';
  @override
  String get serviceUuid => u16('fff0');
  @override
  String get notifyUuid => u16('fff4');
  @override
  String get writeUuid => u16('fff6');
  @override
  Duration get pollInterval => const Duration(seconds: 5);
  @override
  Duration get commandGap => const Duration(milliseconds: 250);

  /// 'A' or 'B', or null when the name carries no usable type/serial.
  final String? type;
  final int key;

  OgtCodec._(this.type, this.key);

  /// Null when the name carried no A/B type + numeric serial: the cipher key
  /// cannot be derived, so the pack stays detect-only.
  OgtCodec? get orNullIfUnknown => type == null ? null : this;

  static const List<int> _crySeq = [2, 5, 4, 3, 1, 4, 1, 6, 8, 3, 7, 2, 5, 8, 9, 3];

  /// Derive type and key from the advertised name, e.g. "SmartBat-B12294".
  factory OgtCodec.forName(String name) {
    final digits = name.length > 10 ? name.substring(10) : '';
    final t = name.length > 10 && RegExp(r'^\d+$').hasMatch(digits) ? name[9] : '?';
    if (t != 'A' && t != 'B') return OgtCodec._(null, 0);
    final hex = int.parse(digits).toRadixString(16).toUpperCase().padLeft(4, '0');
    final k = hex.split('').fold<int>(0, (a, c) => a + _crySeq[int.parse(c, radix: 16)]) +
        (t == 'A' ? 5 : 8);
    return OgtCodec._(t, k);
  }

  /// (register, size) per field; the decoder in [_apply] keys on register.
  List<(int, int)> get _fields => type == 'A'
      ? const [(2, 1), (4, 3), (8, 2), (12, 2), (16, 3), (44, 2), (60, 3)]
      : type == 'B'
          ? const [(8, 2), (9, 2), (10, 3), (13, 1), (15, 3), (23, 2), (24, 3)]
          : const [];

  List<int> command(int reg, int size) {
    final hdr = type == 'A' ? '+RAA' : '+R16';
    final s = '$hdr${_hex2(reg)}${_hex2(size)}';
    return [for (final c in s.codeUnits) c ^ key];
  }

  static String _hex2(int v) => v.toRadixString(16).toUpperCase().padLeft(2, '0');

  /// Registers sent and not yet answered, oldest first (an "Err" reply carries
  /// no register, so it is attributed to the oldest outstanding request).
  final List<int> _pending = [];

  /// Type B: number of cell registers that answered (null: still probing).
  int? _cellCount;
  final Map<int, int> _cellMv = {};

  @override
  void reset() {
    _pending.clear();
    _cellCount = null;
    _cellMv.clear();
  }

  @override
  List<List<int>> pollCommands() {
    if (type == null) return const [];
    _pending.clear();
    final cmds = <List<int>>[];
    for (final (reg, size) in _fields) {
      cmds.add(command(reg, size));
      _pending.add(reg);
    }
    if (type == 'B') {
      for (var i = 0; i < (_cellCount ?? 16); i++) {
        cmds.add(command(63 - i, 2));
        _pending.add(63 - i);
      }
    }
    return cmds;
  }

  /// Decrypt and parse one reply: (register, value), (0, 0) for "Err", or
  /// null when the bytes are not a valid reply.
  (int, int)? parse(List<int> data) {
    final plain = [for (final b in data) b ^ key];
    if (plain.any((c) => c > 0x7F)) return null;
    final msg = ascii.decode(plain);
    if (msg.length < 8 || !msg.startsWith('+RD,')) return null;
    if (msg.substring(4, 7) == 'Err') return (0, 0);
    if (!msg.endsWith('\r\n') ||
        !RegExp(r'^[0-9A-Fa-f]+$').hasMatch(msg.substring(4, msg.length - 2))) {
      return null;
    }
    final signed = msg.length > 12;
    final hex = msg.substring(6, 10);
    final lo = int.parse(hex.substring(0, 2), radix: 16);
    final hi = int.parse(hex.substring(2, 4), radix: 16);
    var v = lo | (hi << 8);
    var mult = 1;
    if (signed) {
      if (v & 0x8000 != 0) v -= 0x10000;
      final m = int.parse(msg.substring(10, 12), radix: 16);
      mult = m > 1 ? m : 1;
    }
    return (int.parse(msg.substring(4, 6), radix: 16), v * mult);
  }

  @override
  List<FamilySample> addBytes(List<int> data) {
    final r = parse(data);
    if (r == null) return const [];
    final (reg, value) = r;
    if (reg == 0) {
      // "Err": the oldest outstanding register has no value.
      if (_pending.isEmpty) return const [];
      final failed = _pending.removeAt(0);
      if (type == 'B' && failed <= 63 && failed >= 48 && _cellCount == null) {
        _cellCount = 63 - failed;
      }
      return const [];
    }
    final at = _pending.indexOf(reg);
    if (at >= 0) _pending.removeRange(0, at + 1);
    final s = _apply(reg, value);
    return s == null ? const [] : [s];
  }

  FamilySample? _apply(int reg, int v) {
    final s = FamilySample();
    if (type == 'A') {
      switch (reg) {
        case 2:
          s.socPercent = v.toDouble();
        case 4:
          s.remainingAh = v / 1000;
        case 8:
          s.voltage = v / 1000;
        case 12:
          s.temps = [_round3(v / 10 - 273.15)];
        case 16:
          s.current = v / 100;
        case 44:
          s.cycles = v;
        case 60:
          s.fullAh = (v ~/ 1000).toDouble();
        default:
          return null;
      }
      return s;
    }
    switch (reg) {
      case 8:
        s.temps = [_round3(v / 10 - 273.15)];
      case 9:
        s.voltage = v / 1000;
      case 10:
        s.current = v / 1000;
      case 13:
        s.socPercent = v.toDouble();
      case 15:
        s.remainingAh = v / 1000;
      case 23:
        s.cycles = v;
      case 24:
        s.fullAh = (v ~/ 1000).toDouble();
      default:
        if (reg < 48 || reg > 63) return null;
        _cellMv[63 - reg] = v;
        final n = _cellMv.keys.fold<int>(-1, (a, b) => a > b ? a : b) + 1;
        s.cellsMv = [for (var i = 0; i < n; i++) _cellMv[i] ?? 0]
            .where((c) => c != 0)
            .toList();
    }
    return s;
  }

  static double _round3(double x) => (x * 1000).round() / 1000;
}
