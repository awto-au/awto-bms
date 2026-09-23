/// Alarm EVENT records (GitHub #67).
///
/// The `flags` metric records that a fault category was active over an
/// interval; the measured values live in their own metrics. Correlating an
/// alarm with the current / temperature / MOS state at that instant used to
/// mean a timestamp join across metrics (docs/ALARM-CORRELATION.md). An
/// [AlarmEvent] is the first-class record instead: ONE row per alarm-BYTE
/// transition (0 -> 1 "set", 1 -> 0 "cleared") in any of the three alarm
/// frames — documented bits and unknown bytes alike — with a SNAPSHOT of the
/// pack state, the last command sent to it and the time since connect, all
/// captured in the parser's event hook the moment the frame is decoded.
///
/// The canonical example (B8, 21 Sep 15:06:59): output switched ON into an
/// attached 90 A load — short-circuit protection SET 0.5 s after the gate
/// write while current still read 0 A and the MOS still read off, then
/// CLEARED 1.7 s later as the FETs closed.
///
/// Pure Dart: the model, the DB row mapping and the display text. Captured by
/// `BatteryConnection`, stored by `BatteryLogger` (table `alarm_events`),
/// shown by `AlarmEventsSection`.
library;

import 'battery_protocol.dart';
import 'fmt.dart';

/// The three alarm frames, by the name stored in the `frame` column (the same
/// word `WarningEvent.category` carries).
const alarmFrames = ['current', 'voltage', 'temperature'];

/// The name of alarm byte [byteIndex] of [frame], from the protocol tables
/// ([alarmBitNames]); a byte with no documented meaning is
/// `'unknown byte N'`.
String alarmBitName(String frame, int byteIndex) =>
    alarmBitNames[frame]?[byteIndex] ?? 'unknown byte $byteIndex';

/// One alarm-byte transition with its snapshot. Immutable; [withDuration]
/// returns a copy once the clearing row fixes the duration.
class AlarmEvent {
  final int? id;
  final String serial;
  final int atMs;
  final String frame; // 'current' | 'voltage' | 'temperature'
  final int byteIndex;
  final String bitName;
  final String transition; // 'set' | 'cleared'
  final int fromValue;
  final int toValue;

  /// How long the bit was set: on a `cleared` row the time since its `set`
  /// row; back-filled onto the `set` row when the clear is recorded. Null
  /// while unknown (still set, or the set predates the record).
  final int? durationMs;

  // --- snapshot ---
  final double? packI; // signed, + in / - out
  final double? packV;
  final double? cellMin;
  final double? cellMax;
  final double? cellDelta;
  final int? temp0, temp1, temp2, temp3;
  final int? chip;
  final int? soc;
  final String chargeState;
  final int? chgMos;
  final int? disMos;
  final int? tempGate;
  final int? smokeGate;
  final int? heatGate;
  final int overTempLatched;
  final int? standbyOn; // null = never reported on this link
  final String? lastTxLabel;
  final String? lastTxHex;
  final int? sinceLastTxMs;
  final int? sinceConnectMs;

  const AlarmEvent({
    this.id,
    required this.serial,
    required this.atMs,
    required this.frame,
    required this.byteIndex,
    required this.bitName,
    required this.transition,
    required this.fromValue,
    required this.toValue,
    this.durationMs,
    this.packI,
    this.packV,
    this.cellMin,
    this.cellMax,
    this.cellDelta,
    this.temp0,
    this.temp1,
    this.temp2,
    this.temp3,
    this.chip,
    this.soc,
    this.chargeState = 'unknown',
    this.chgMos,
    this.disMos,
    this.tempGate,
    this.smokeGate,
    this.heatGate,
    this.overTempLatched = 0,
    this.standbyOn,
    this.lastTxLabel,
    this.lastTxHex,
    this.sinceLastTxMs,
    this.sinceConnectMs,
  });

  static const set = 'set';
  static const cleared = 'cleared';

  bool get isSet => transition == set;

  /// Snapshot the decoded [state] (already updated by the alarm frame's
  /// handler) plus the connection's command / link context.
  factory AlarmEvent.capture({
    required String serial,
    required int atMs,
    required String frame,
    required int byteIndex,
    required int fromValue,
    required int toValue,
    required BatteryState state,
    required double signedCurrent,
    int? durationMs,
    String? lastTxLabel,
    List<int> lastTxBytes = const [],
    int? lastTxMs,
    int? connectedAtMs,
  }) {
    int? b(bool? v) => v == null ? null : (v ? 1 : 0);
    return AlarmEvent(
      serial: serial,
      atMs: atMs,
      frame: frame,
      byteIndex: byteIndex,
      bitName: alarmBitName(frame, byteIndex),
      transition: toValue != 0 ? set : cleared,
      fromValue: fromValue,
      toValue: toValue,
      durationMs: durationMs,
      packI: signedCurrent,
      packV: state.packVoltage,
      cellMin: state.cellMin,
      cellMax: state.cellMax,
      cellDelta: state.cellDiff,
      temp0: state.temp0,
      temp1: state.temp1,
      temp2: state.temp2,
      temp3: state.temp3,
      chip: state.chipTemperature,
      soc: state.socPercent,
      chargeState: state.chargeState.name,
      chgMos: b(state.chargeMos),
      disMos: b(state.dischargeMos),
      tempGate: state.tempControlGate,
      smokeGate: state.smokeGate,
      heatGate: state.heatGate,
      overTempLatched: state.overTempLatched ? 1 : 0,
      standbyOn: b(state.sleepModeOn),
      lastTxLabel: lastTxLabel,
      lastTxHex: lastTxBytes.isEmpty ? null : hexOf(lastTxBytes),
      sinceLastTxMs: lastTxMs == null ? null : atMs - lastTxMs,
      sinceConnectMs: connectedAtMs == null ? null : atMs - connectedAtMs,
    );
  }

  AlarmEvent withDuration(int? ms, {int? id}) => AlarmEvent(
        id: id ?? this.id,
        serial: serial,
        atMs: atMs,
        frame: frame,
        byteIndex: byteIndex,
        bitName: bitName,
        transition: transition,
        fromValue: fromValue,
        toValue: toValue,
        durationMs: ms,
        packI: packI,
        packV: packV,
        cellMin: cellMin,
        cellMax: cellMax,
        cellDelta: cellDelta,
        temp0: temp0,
        temp1: temp1,
        temp2: temp2,
        temp3: temp3,
        chip: chip,
        soc: soc,
        chargeState: chargeState,
        chgMos: chgMos,
        disMos: disMos,
        tempGate: tempGate,
        smokeGate: smokeGate,
        heatGate: heatGate,
        overTempLatched: overTempLatched,
        standbyOn: standbyOn,
        lastTxLabel: lastTxLabel,
        lastTxHex: lastTxHex,
        sinceLastTxMs: sinceLastTxMs,
        sinceConnectMs: sinceConnectMs,
      );

  // --- DB mapping (table `alarm_events`) ------------------------------------

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'serial': serial,
        'at_ms': atMs,
        'at_time': fmtStampMs(atMs),
        'frame': frame,
        'byte_index': byteIndex,
        'bit_name': bitName,
        'transition': transition,
        'from_value': fromValue,
        'to_value': toValue,
        'duration_ms': durationMs,
        'pack_i': packI,
        'pack_v': packV,
        'cell_min': cellMin,
        'cell_max': cellMax,
        'cell_delta': cellDelta,
        'temp0': temp0,
        'temp1': temp1,
        'temp2': temp2,
        'temp3': temp3,
        'chip': chip,
        'soc': soc,
        'charge_state': chargeState,
        'chg_mos': chgMos,
        'dis_mos': disMos,
        'temp_gate': tempGate,
        'smoke_gate': smokeGate,
        'heat_gate': heatGate,
        'over_temp_latched': overTempLatched,
        'standby_on': standbyOn,
        'last_tx_label': lastTxLabel,
        'last_tx_hex': lastTxHex,
        'since_last_tx_ms': sinceLastTxMs,
        'since_connect_ms': sinceConnectMs,
      };

  factory AlarmEvent.fromRow(Map<String, Object?> r) {
    int? i(String k) => (r[k] as num?)?.toInt();
    double? d(String k) => (r[k] as num?)?.toDouble();
    return AlarmEvent(
      id: i('id'),
      serial: r['serial'] as String,
      atMs: i('at_ms') ?? 0,
      frame: r['frame'] as String,
      byteIndex: i('byte_index') ?? 0,
      bitName: r['bit_name'] as String? ?? '',
      transition: r['transition'] as String? ?? set,
      fromValue: i('from_value') ?? 0,
      toValue: i('to_value') ?? 0,
      durationMs: i('duration_ms'),
      packI: d('pack_i'),
      packV: d('pack_v'),
      cellMin: d('cell_min'),
      cellMax: d('cell_max'),
      cellDelta: d('cell_delta'),
      temp0: i('temp0'),
      temp1: i('temp1'),
      temp2: i('temp2'),
      temp3: i('temp3'),
      chip: i('chip'),
      soc: i('soc'),
      chargeState: r['charge_state'] as String? ?? 'unknown',
      chgMos: i('chg_mos'),
      disMos: i('dis_mos'),
      tempGate: i('temp_gate'),
      smokeGate: i('smoke_gate'),
      heatGate: i('heat_gate'),
      overTempLatched: i('over_temp_latched') ?? 0,
      standbyOn: i('standby_on'),
      lastTxLabel: r['last_tx_label'] as String?,
      lastTxHex: r['last_tx_hex'] as String?,
      sinceLastTxMs: i('since_last_tx_ms'),
      sinceConnectMs: i('since_connect_ms'),
    );
  }

  // --- text -----------------------------------------------------------------

  /// The MOS switches as one phrase: "MOS on" / "MOS off" when both agree,
  /// else each named; "MOS —" while no BAL_STATUS has been decoded.
  String get mosText {
    final c = chgMos, d = disMos;
    if (c == null || d == null) return 'MOS —';
    if (c == 1 && d == 1) return 'MOS on';
    if (c == 0 && d == 0) return 'MOS off';
    return 'charge ${c == 1 ? 'on' : 'off'} · output ${d == 1 ? 'on' : 'off'}';
  }

  /// One display line, e.g.
  /// `21 Sep 15:06:59  Short circuit protection SET — 0.0 A · 13.2 V · MOS off
  /// · 0.5 s after 'Output ON' · cleared after 1.7 s`.
  String describe() {
    final parts = <String>[
      fSignedA(packI),
      packV == null ? '— V' : '${packV!.toStringAsFixed(1)} V',
      mosText,
      if (lastTxLabel != null && sinceLastTxMs != null)
        "${fmtAgeShort(sinceLastTxMs!)} after '$lastTxLabel'",
      if (durationMs != null)
        isSet
            ? 'cleared after ${fmtAgeShort(durationMs!)}'
            : 'was set for ${fmtAgeShort(durationMs!)}',
    ];
    return '${fmtShortStamp(atMs)}  $bitName ${transition.toUpperCase()} — '
        '${parts.join(' · ')}';
  }

  /// The full snapshot on one line, for the raw log's `ALARM` line, the
  /// Diagnostics entry and the Copy action.
  String snapshotText() {
    String onOff(int? v) => v == null ? '?' : (v == 1 ? 'on' : 'off');
    String t(int? v) => v == null ? '?' : '$v';
    final tx = lastTxLabel == null
        ? 'no TX yet'
        : "lastTx='$lastTxLabel' ${lastTxHex ?? ''}"
            '${sinceLastTxMs == null ? '' : ' ${fmtAgeShort(sinceLastTxMs!)} ago'}';
    return "$frame byte $byteIndex '$bitName' $fromValue -> $toValue "
        '($transition'
        '${durationMs == null ? '' : ', ${isSet ? 'cleared after' : 'set for'} ${fmtAgeShort(durationMs!)}'}'
        ') | I=${packI?.toStringAsFixed(1) ?? '?'}A '
        'V=${packV?.toStringAsFixed(1) ?? '?'}V '
        'cells ${cellMin?.toStringAsFixed(2) ?? '?'}..'
        '${cellMax?.toStringAsFixed(2) ?? '?'} '
        'd=${cellDelta?.toStringAsFixed(2) ?? '?'} '
        't=${t(temp0)}/${t(temp1)}/${t(temp2)}/${t(temp3)} chip=${t(chip)} '
        'soc=${soc == null ? '?' : '$soc%'} state=$chargeState '
        'chgMos=${onOff(chgMos)} disMos=${onOff(disMos)} '
        'tempGate=${t(tempGate)} smokeGate=${t(smokeGate)} '
        'heatGate=${t(heatGate)} latched=$overTempLatched '
        'standby=${standbyOn == null ? 'unknown' : onOff(standbyOn)} | '
        '$tx | connected '
        '${sinceConnectMs == null ? '?' : fmtAgeShort(sinceConnectMs!)}';
  }

  @override
  String toString() => describe();
}

/// Per-serial in-memory tally the logger keeps for the Diagnostics summary.
class AlarmStats {
  final int count;
  final AlarmEvent? last;
  const AlarmStats({this.count = 0, this.last});

  AlarmStats add(AlarmEvent e) => AlarmStats(
      count: count + 1, last: last == null || e.atMs >= last!.atMs ? e : last);

  /// "no alarm events" / "3 alarm events, last 21 Sep 15:07:01 Short circuit
  /// protection cleared".
  String get summaryLine {
    if (count == 0 || last == null) return 'no alarm events';
    final l = last!;
    return '$count alarm ${count == 1 ? 'event' : 'events'}, last '
        '${fmtShortStamp(l.atMs)} ${l.bitName} ${l.transition}';
  }
}

/// The Copy action's text: one [AlarmEvent.describe] line per event (newest
/// first, as shown) each followed by its full snapshot, indented.
String alarmEventsCopyText(String serial, List<AlarmEvent> events) => [
      'Alarm events $serial (${events.length}, newest first)',
      for (final e in events) ...[e.describe(), '    ${e.snapshotText()}'],
    ].join('\n');
