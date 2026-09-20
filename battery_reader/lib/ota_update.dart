/// Firmware update (OTA) over the FCF0 link — GitHub #41.
///
/// THIS IS THE ONE FEATURE THAT CAN BRICK A PACK. Everything here refuses by
/// default: the session only starts once every pre-flight gate in
/// [otaPreflight] passes, the user has typed the battery's serial, and the
/// caller holds the [OtaLock] that blocks every other write, the pause /
/// exit / background-sampling paths and the not-streaming probe for the whole
/// transfer. Nothing in this module has been run against a real battery — all
/// verification is against the fake transport in test/ota_update_test.dart.
///
/// ===========================================================================
/// DERIVED PROTOCOL SPEC
/// ===========================================================================
/// Source of truth: the vendor Sphere Battery 1.0.24 decompile,
/// `artifacts/sphere-battery-1.0.24/jadx/sources/com/joysuny/batteryutil/`
/// (cited below as BM = blemanager/BatteryManager.java, CMD =
/// blemanager/BatteryCMD.java, BU = util/ByteUtils.java, UVM =
/// actvm/UpdateViewModel.java, MM = actmodel/MainModel.java, G =
/// global/Global.java). Cross-checked against docs/PROTOCOL.md "Firmware
/// update" and docs/reverse/01-ble-protocol.md §1.9 / §1.13 / §2.17 and
/// 02-transport-ibluz.md §4.
///
/// 0. MTU. Opening the update screen calls `iBluzDevice.setMtu(512)`
///    (UVM:42). The SDK reports the NEGOTIATED ATT MTU to MM:155-164, which
///    CAPS IT AT 200 and stores it as pref `sphere_mtu` (default 20 when
///    unset). MM:401-407 sends the app-level MTU frame `C3 F2 <mtu&0xFF> ED CE`
///    (BM:144-146 `sendMtu`, CMD:57-58) 1 s after the handshake, with that same
///    capped value. The chunker reads the SAME pref (BM:934). So the value
///    that sizes the chunks AND is told to the BMS is `min(negotiatedMtu,
///    200)` — never 512. [OtaProtocol.effectiveMtu] reproduces this
///    (unknown MTU -> 20, the vendor default).
///
/// 1. Begin. `update()` (BM:173-179) -> `beginUpdate()` (BM:181-184): arm a
///    20 s "handshake" timer (BM:29 HANDSHAKE_TIMEOUT) and send
///    CMD_BEGIN_UPDATE = `EB 90 00 07 BB 03 40` (CMD:66).
///
/// 2. Recall. The BMS answers `FF 01` (CMD:67 CMD_UPDATE_RECALL_1) then 3
///    bytes byte-compared to `B1 02 EF` (CMD:68 CMD_UPDATE_RECALL_2) —
///    BM:825-834. On it: new resend pool, `mCurNum = 0`, `mResendTime = 0`,
///    `beginSendUpdateFile(0)`. A RECALL that arrives MID-TRANSFER runs the
///    same code, i.e. restarts from chunk 0.
///
/// 3. Data frame, `beginSendUpdateFile(i)` (BM:932-971):
///      payloadCap = (mtu / 10) * 9 - 6          (BM:934-936, integer math)
///      offset     = payloadCap * i               (BM:937)
///      if fileLen <= offset -> updateFinish()    (BM:942-945)
///      len = min(payloadCap, fileLen - offset)   (BM:946-948, last chunk)
///      frame = 01 01 | numHi numLo | len | payload[len] | sum
///        [0..1] CMD_ACK_HEAD `01 01`             (CMD:69, BM:956-957)
///        [2]    intToBytes(i)[1] = (i >> 8) & FF (BM:958, BU:33-35)
///        [3]    intToBytes(i)[0] = i & FF        (BM:959)  => BIG-endian
///        [4]    len                              (BM:960)
///        [5..]  payload                          (BM:961)
///        [last] getSum(frame, len+5)             (BM:962-963, 973-979)
///      getSum: sum every byte BEFORE the checksum (head, number, len,
///      payload), take the low 8 bits, two's complement: `(byte)(~sum + 1)`
///      == `(-sum) & 0xFF`, so the whole frame sums to 0 mod 256.
///      A 2 s resend timer (BM:30 RESEND_TIMEOUT) is armed BEFORE the send
///      (BM:964-965). Progress = offset / fileLen * 100 (BM:940).
///      Consistency check: CMD_UPDATE_FINISH `01 01 EC 00 00 12` (CMD:70) is
///      exactly this frame with number 0xEC00 and len 0 (01+01+EC = EE,
///      -EE = 12), which confirms the checksum formula.
///
/// 4. Per-chunk ACK (BM:835-862): head `01 01` (CMD:69) then EXACTLY 4 bytes
///    `b[0..3]` (BM:836-837). Accepted iff
///      byteToIntHigh(b[0], b[1]) == mCurNum       (BM:841; BU:45-47 = u16 BE)
///      && b[3] == getRecallSum(b[0], b[1])         (BM:843)
///    getRecallSum (BM:982-984) = `(byte)(~(b0 + 2 + b1 + 6) + 1)`
///      == `(-(numHi + numLo + 8)) & 0xFF`. b[2] is read but NEVER compared.
///    So the ack is 6 bytes on the wire: `01 01 numHi numLo <status> <sum>`.
///    On accept: cancel the resend timer, `mResendTime = 0`, `mCurNum++`,
///    send the next chunk (BM:844-848). A NON-matching ack is silently
///    ignored — the running 2 s timer then resends the same chunk.
///
/// 5. Resend (BM:49-63 mResendTimeout): on timer expiry, if `mResendTime >=
///    10` -> onUpdateFailure; else `mResendTime++` and resend the current
///    chunk. I.e. 1 send + up to 10 resends = 11 sends, failure after the
///    11th 2 s timeout (~22 s of silence).
///
/// 6. Finish (BM:920-929 updateFinish): reached from beginSendUpdateFile when
///    `fileLen <= offset`, i.e. right after the LAST chunk's ack. 300 ms
///    later send CMD_UPDATE_FINISH `01 01 EC 00 00 12` (CMD:70) and arm the
///    same 2 s resend timer (its expiry re-enters beginSendUpdateFile ->
///    updateFinish, so FINISH is re-sent, 300 ms + 2 s apart, with the same
///    10-resend cap).
///
/// 7. Success (BM:864-873): head `AA BB` (CMD:30 CMD_UPDATE_SUCCESS_1) then
///    3 bytes byte-compared to `01 02 EF` (CMD:31) -> onUpdateSuccess, the
///    resend timer is removed.
///
/// 8. End. CMD_UPDATE_END = `AA BB 01 02 03 04 CC DD` (CMD:71, BM:186-189
///    endUpdate). The vendor sends it (a) 1 s after success (UVM:120-131),
///    (b) when the user presses Back on the update screen (UVM:52-58) and
///    (c) in onStop (UVM:45-50). It is NOT sent on failure by itself.
///
/// 9. File. The main path only accepts a file named exactly `PB51250506.bin`
///    (G:17, JS3.x family) or `8803250506.bin` (G:20, JS5.x family) — the
///    version string maps to the family at MM:392-394; the service-mode path
///    takes any file (UVM:60-72, "*/*"). The `.bin` is streamed raw from
///    offset 0 (BM:951-955); the app parses no header.
///
/// AMBIGUITIES / DEVIATIONS (each flagged in the report):
///  * Chunk-number byte order: the Java writes intToBytes(i)[1] (HIGH byte)
///    first (BM:958-959) — BIG-endian, as PROTOCOL.md says; the task brief's
///    `<numLo> <numHi>` is the other way round. The Java wins.
///  * The 20 s handshake timer (BM:39-47) only INCREMENTS `retryTimes` the
///    first time it fires and never re-arms, so in the vendor a missing
///    RECALL hangs forever. Here a missing RECALL within 20 s FAILS the
///    session before any chunk is sent.
///  * ACK byte b[2] ("status") is never compared by the vendor; it is
///    ignored here too and logged.
///  * SUCCESS is accepted at ANY time by the vendor (BM:864). Here it is
///    accepted only once every chunk has been acked (stage finishing); a
///    premature SUCCESS is logged and ignored, because declaring success on
///    a half-written image is worse than a failed update.
///  * After success the vendor's pending FINISH timer still fires and
///    re-arms the resend timer (BM:925-926), which after 10 expiries would
///    call a null listener. Here success cancels every timer.
///  * A mid-transfer RECALL restarts from chunk 0 as the vendor does, but
///    is bounded ([OtaSession.maxRestarts]) instead of looping forever.
///  * The MTU frame is sent by the vendor 1 s after EVERY connect, not in the
///    update path. This app's handshake does not send it, so the session
///    sends it immediately before CMD_BEGIN_UPDATE with the same value the
///    chunker uses.
///  * On failure the vendor sends END only when the user leaves the screen;
///    this UI does the same ([OtaSession.sendEnd] from the result screen).
///  * The len byte is `intToByte(length)` = `length & 0xFF` (BM:960): any
///    MTU above 290 (cap > 255) would silently truncate it. The vendor's
///    200 cap keeps it at <= 174; [OtaImage.chunks] refuses a cap > 255
///    instead of emitting a corrupt frame.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'battery_protocol.dart';

/// A TX function: write [bytes] on FCF1 and label it in the raw log. Throws
/// on any failure (no link, GATT error).
typedef OtaSend = Future<void> Function(List<int> bytes, String label);

// ===========================================================================
// Wire constants and pure frame math (byte-exact to the Java).
// ===========================================================================

class OtaProtocol {
  /// CMD_SEND_MTU `C3 F2 <mtu> ED CE` (CMD:57-58, BM:144-146).
  static const sendMtuBegin = <int>[0xC3, 0xF2];
  static const sendMtuEnd = <int>[0xED, 0xCE];

  /// CMD_BEGIN_UPDATE (CMD:66).
  static const beginUpdate = <int>[0xEB, 0x90, 0x00, 0x07, 0xBB, 0x03, 0x40];

  /// CMD_UPDATE_RECALL_1 + _2 (CMD:67-68) — the BMS's "go".
  static const recall = <int>[0xFF, 0x01, 0xB1, 0x02, 0xEF];

  /// CMD_ACK_HEAD (CMD:69): data-frame head and per-chunk ack head.
  static const ackHead = <int>[0x01, 0x01];

  /// CMD_UPDATE_FINISH (CMD:70) — a len-0 data frame numbered 0xEC00.
  static const updateFinish = <int>[0x01, 0x01, 0xEC, 0x00, 0x00, 0x12];

  /// CMD_UPDATE_SUCCESS_1 + _2 (CMD:30-31).
  static const success = <int>[0xAA, 0xBB, 0x01, 0x02, 0xEF];

  /// CMD_UPDATE_END (CMD:71).
  static const updateEnd = <int>[
    0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04, 0xCC, 0xDD, //
  ];

  /// MM:159-161: the negotiated MTU is capped at 200 before it is stored.
  static const mtuCap = 200;

  /// BM:934 / MM:401: pref default when no MTU was ever reported.
  static const defaultMtu = 20;

  /// The chunk number CMD_UPDATE_FINISH carries (0xEC00), for log clarity.
  static const finishChunkNumber = 0xEC00;

  static const maxResends = 10; // BM:52 `mResendTime >= 10`
  static const resendTimeout = Duration(milliseconds: 2000); // BM:30
  static const recallTimeout = Duration(milliseconds: 20000); // BM:29
  static const finishDelay = Duration(milliseconds: 300); // BM:928
  static const endDelay = Duration(milliseconds: 1000); // UVM:131

  /// The MTU value the vendor's chunker and MTU frame actually use:
  /// `min(negotiated, 200)`, or 20 when the link never reported one.
  static int effectiveMtu(int? negotiated) =>
      negotiated == null || negotiated <= 0
          ? defaultMtu
          : math.min(negotiated, mtuCap);

  /// BM:934-936: `(mtu / 10) * 9 - 6` with Java integer division.
  static int payloadCap(int mtu) => (mtu ~/ 10) * 9 - 6;

  /// BM:973-979 getSum over [bytes]: two's complement of the low 8 bits of
  /// the byte sum, so the frame plus this byte sums to 0 mod 256.
  static int checksum(List<int> bytes) {
    var sum = 0;
    for (final b in bytes) {
      sum += b & 0xff;
    }
    return (-sum) & 0xff;
  }

  /// BM:982-984 getRecallSum: the checksum the app expects in ack byte [3]
  /// for chunk [chunk]: `(byte)(~(hi + 2 + lo + 6) + 1)`. Signed-byte
  /// arithmetic in the Java changes nothing mod 256.
  static int ackChecksum(int chunk) {
    final hi = (chunk >> 8) & 0xff;
    final lo = chunk & 0xff;
    return (-(hi + lo + 8)) & 0xff;
  }

  /// BM:956-963: one data frame for chunk [index] carrying [payload].
  static Uint8List chunkFrame(int index, List<int> payload) {
    if (index < 0 || index > 0xffff) {
      throw ArgumentError.value(index, 'index', 'chunk number must fit u16');
    }
    if (payload.length > 0xff) {
      throw ArgumentError.value(
          payload.length, 'payload', 'chunk payload must fit one length byte');
    }
    final frame = Uint8List(payload.length + 6);
    frame[0] = ackHead[0];
    frame[1] = ackHead[1];
    frame[2] = (index >> 8) & 0xff; // intToBytes(i)[1]  (BM:958)
    frame[3] = index & 0xff; // intToBytes(i)[0]  (BM:959)
    frame[4] = payload.length;
    frame.setRange(5, 5 + payload.length, payload);
    frame[frame.length - 1] = checksum(frame.sublist(0, frame.length - 1));
    return frame;
  }

  /// BM:144-146: the app-level MTU frame, low byte only.
  static List<int> mtuFrame(int mtu) =>
      [sendMtuBegin[0], sendMtuBegin[1], mtu & 0xff, sendMtuEnd[0], sendMtuEnd[1]];

  /// The vendor's known image names (G:17 / G:20) and the family each is
  /// for (MM:392-394 maps the reported version to the family).
  static const js3ImagePrefix = 'PB51';
  static const js5ImagePrefix = '8803';
}

// ===========================================================================
// The image and its chunks.
// ===========================================================================

/// One data frame's worth of the image.
class OtaChunk {
  final int index;
  final int offset;
  final Uint8List payload;
  final Uint8List frame;
  const OtaChunk({
    required this.index,
    required this.offset,
    required this.payload,
    required this.frame,
  });
}

/// A user-chosen `.bin`, streamed raw from offset 0 (BM:951-955).
class OtaImage {
  final String name;
  final Uint8List bytes;

  OtaImage({required this.name, required List<int> bytes})
      : bytes = Uint8List.fromList(bytes);

  int get size => bytes.length;

  /// Lower-case hex SHA-256 of the whole file, shown before the flash so the
  /// user can check it against the one the dealer gave them.
  late final String sha256Hex = sha256.convert(bytes).toString();

  /// How many chunks at [mtu] (`ceil(size / cap)`; 0 for an empty file).
  int chunkCount(int mtu) {
    final cap = OtaProtocol.payloadCap(mtu);
    if (cap <= 0 || cap > 0xff) {
      throw ArgumentError.value(mtu, 'mtu', 'payload cap $cap out of range');
    }
    return (size + cap - 1) ~/ cap;
  }

  /// The exact frames BM:932-971 would send for this image at [mtu], in
  /// order. [mtu] is the EFFECTIVE value ([OtaProtocol.effectiveMtu]).
  List<OtaChunk> chunks(int mtu) {
    final cap = OtaProtocol.payloadCap(mtu);
    if (cap <= 0) throw ArgumentError.value(mtu, 'mtu', 'payload cap <= 0');
    // The len byte is `intToByte(length)` = length & 0xFF (BM:960): any mtu
    // above 290 would silently truncate it. The vendor never gets there
    // (MTU capped at 200 -> 174 B); refuse rather than corrupt.
    if (cap > 0xff) {
      throw ArgumentError.value(
          mtu, 'mtu', 'payload cap $cap does not fit the length byte');
    }
    final out = <OtaChunk>[];
    for (var i = 0; cap * i < size; i++) {
      final offset = cap * i;
      final len = math.min(cap, size - offset);
      final payload = Uint8List.sublistView(bytes, offset, offset + len);
      out.add(OtaChunk(
        index: i,
        offset: offset,
        payload: payload,
        frame: OtaProtocol.chunkFrame(i, payload),
      ));
    }
    return out;
  }
}

/// Non-null when [name] does not look like a vendor image for the reported
/// [firmwareVersion] (G:17/G:20, MM:392-394). A WARNING only — the vendor's
/// service-mode path takes any file — shown on the pre-flight checklist.
String? otaFilenameWarning(String name, String? firmwareVersion) {
  final lower = name.toLowerCase();
  final isJs3 = lower.startsWith(OtaProtocol.js3ImagePrefix.toLowerCase()) &&
      lower.endsWith('.bin');
  final isJs5 = lower.startsWith(OtaProtocol.js5ImagePrefix.toLowerCase()) &&
      lower.endsWith('.bin');
  final v = (firmwareVersion ?? '').trim().toUpperCase();
  final String? family;
  if (v == 'JS5.1' || v == 'JS5.2') {
    family = 'JS5';
  } else if (v == 'JS1.0' || v == 'JS3.1' || v == 'JS3.2') {
    family = 'JS3';
  } else {
    family = null;
  }
  if (!isJs3 && !isJs5) {
    return 'File name "$name" does not match a known vendor image '
        '(PB51*.bin for JS3.x, 8803*.bin for JS5.x). Make sure it is the '
        'image for this exact BMS.';
  }
  if (family == 'JS5' && isJs3) {
    return 'This BMS reports $v (JS5 family) but "$name" is a PB51* (JS3) '
        'image.';
  }
  if (family == 'JS3' && isJs5) {
    return 'This BMS reports $v (JS3 family) but "$name" is an 8803* (JS5) '
        'image.';
  }
  if (family == null) {
    return 'The BMS firmware version is ${v.isEmpty ? 'unknown' : v}; the '
        'family this image is for cannot be checked.';
  }
  return null;
}

// ===========================================================================
// Pre-flight gates (all pure).
// ===========================================================================

/// One pre-flight check, shown pass/fail on the checklist.
class OtaGate {
  final String name;
  final bool ok;
  final String detail;
  const OtaGate(this.name, this.ok, this.detail);
}

/// Everything the gates look at, gathered by the UI from the connection.
class OtaPreflightInput {
  final bool connected;

  /// Fresh telemetry: a telemetry frame within the not-streaming window.
  final bool streaming;
  final String streamingDetail;
  final int? soc;
  final bool activeFault;
  final String faultDetail;
  final ChargeState chargeState;
  final double? currentA;

  /// The device will not sleep / kill the app mid-flash (Android: the
  /// foreground service with its wake lock is running).
  final bool keepAwake;
  final String keepAwakeDetail;
  final OtaImage? image;
  final String? firmwareVersion;

  /// Another write (or another update) is in flight on this app.
  final bool otherWriteInFlight;
  const OtaPreflightInput({
    required this.connected,
    required this.streaming,
    this.streamingDetail = '',
    required this.soc,
    required this.activeFault,
    this.faultDetail = '',
    required this.chargeState,
    required this.currentA,
    required this.keepAwake,
    this.keepAwakeDetail = '',
    required this.image,
    required this.firmwareVersion,
    this.otherWriteInFlight = false,
  });
}

/// Minimum state of charge to start a flash.
const int otaMinSocPercent = 30;

/// "Current ~0 A": the pack must be idle with no more than this flowing.
const double otaIdleCurrentMaxA = 0.5;

/// The pre-flight checklist. EVERY gate must pass ([otaPreflightPasses]).
List<OtaGate> otaPreflight(OtaPreflightInput i) {
  final img = i.image;
  final soc = i.soc;
  final cur = i.currentA;
  final idle = i.chargeState == ChargeState.idle &&
      cur != null &&
      cur.abs() <= otaIdleCurrentMaxA;
  return [
    OtaGate(
      'Battery connected and streaming',
      i.connected && i.streaming,
      !i.connected
          ? 'Not connected'
          : i.streaming
              ? 'Fresh telemetry'
              : (i.streamingDetail.isEmpty
                  ? 'No fresh telemetry'
                  : i.streamingDetail),
    ),
    OtaGate(
      'State of charge at least $otaMinSocPercent %',
      soc != null && soc >= otaMinSocPercent,
      soc == null ? 'SOC unknown' : 'SOC $soc %',
    ),
    OtaGate(
      'No active fault',
      !i.activeFault,
      i.activeFault
          ? (i.faultDetail.isEmpty ? 'A fault is active' : i.faultDetail)
          : 'No fault reported',
    ),
    OtaGate(
      'Not charging or discharging (current ~0 A)',
      idle,
      cur == null
          ? 'Current unknown'
          : '${i.chargeState.name}, ${cur.toStringAsFixed(1)} A'
              '${idle ? '' : ' (needs idle and at most '
                  '${otaIdleCurrentMaxA.toStringAsFixed(1)} A)'}',
    ),
    OtaGate(
      'Device will stay awake',
      i.keepAwake,
      i.keepAwakeDetail.isEmpty
          ? (i.keepAwake ? 'OK' : 'The device may sleep mid-flash')
          : i.keepAwakeDetail,
    ),
    OtaGate(
      'Firmware file chosen',
      img != null && img.size > 0,
      img == null
          ? 'No file chosen'
          : img.size == 0
              ? '${img.name} is empty'
              : '${img.name} — ${img.size} bytes',
    ),
    OtaGate(
      'Current firmware version known',
      i.firmwareVersion != null && i.firmwareVersion!.trim().isNotEmpty,
      i.firmwareVersion == null || i.firmwareVersion!.trim().isEmpty
          ? 'The BMS has not reported its version on this connection'
          : 'Version ${i.firmwareVersion}',
    ),
    OtaGate(
      'No other write in progress',
      !i.otherWriteInFlight,
      i.otherWriteInFlight
          ? 'Another command or update is in flight'
          : 'Nothing else is being sent',
    ),
  ];
}

bool otaPreflightPasses(List<OtaGate> gates) => gates.every((g) => g.ok);

/// The gates that failed, as one reason line (for the refusal message).
String otaPreflightRefusal(List<OtaGate> gates) => [
      for (final g in gates)
        if (!g.ok) '${g.name}: ${g.detail}'
    ].join('; ');

/// The typed confirmation: the user must type the battery's serial exactly
/// (surrounding whitespace ignored). An empty serial never matches.
bool otaConfirmationMatches(String typed, String? serial) {
  final s = (serial ?? '').trim();
  return s.isNotEmpty && typed.trim() == s;
}

/// The stern warning shown before the typed confirmation.
const String otaSternWarning =
    'A failed or interrupted update can permanently disable this battery\'s '
    'BMS. Do not move the phone, close the app, or let the battery lose '
    'connection.';

// ===========================================================================
// The session: begin -> chunks (ack-gated, retry/timeout) -> finish ->
// success -> end.
// ===========================================================================

enum OtaStage {
  idle,

  /// Sending the MTU frame.
  mtu,

  /// CMD_BEGIN_UPDATE sent; waiting for RECALL (20 s).
  awaitingRecall,

  /// Chunks in flight, ack-gated.
  sending,

  /// Every chunk acked; FINISH sent / pending; waiting for SUCCESS.
  finishing,

  /// Terminal: the BMS reported SUCCESS.
  success,

  /// Terminal: failed — see [OtaResult.reason].
  failed,

  /// Terminal: aborted by the user before the first chunk.
  aborted;

  bool get terminal =>
      this == OtaStage.success ||
      this == OtaStage.failed ||
      this == OtaStage.aborted;

  String get text => switch (this) {
        OtaStage.idle => 'Not started',
        OtaStage.mtu => 'Sending MTU',
        OtaStage.awaitingRecall => 'Waiting for the BMS to accept the update',
        OtaStage.sending => 'Sending firmware',
        OtaStage.finishing => 'Waiting for the BMS to confirm',
        OtaStage.success => 'Update successful',
        OtaStage.failed => 'Update failed',
        OtaStage.aborted => 'Update aborted',
      };
}

/// A progress snapshot (immutable; a new one per change).
class OtaProgress {
  final OtaStage stage;

  /// Index of the chunk currently in flight (or the next to send).
  final int chunkIndex;
  final int chunkCount;

  /// Chunks acked so far (== the index of the next chunk).
  final int ackedChunks;
  final int ackedBytes;
  final int totalBytes;

  /// Resend attempt for the current chunk (0 = first send).
  final int attempt;

  /// The highest chunk index the BMS has acked, or null before the first.
  final int? lastAckedChunk;
  final String detail;
  const OtaProgress({
    required this.stage,
    required this.chunkIndex,
    required this.chunkCount,
    required this.ackedChunks,
    required this.ackedBytes,
    required this.totalBytes,
    required this.attempt,
    required this.lastAckedChunk,
    this.detail = '',
  });

  /// Vendor progress (BM:940): offset of the chunk being sent over the file
  /// length; 100 once every chunk is acked.
  int get percent =>
      totalBytes == 0 ? 0 : (ackedBytes * 100 ~/ totalBytes).clamp(0, 100);

  OtaProgress copyWith({
    OtaStage? stage,
    int? chunkIndex,
    int? ackedChunks,
    int? ackedBytes,
    int? attempt,
    int? lastAckedChunk,
    bool clearLastAcked = false,
    String? detail,
  }) =>
      OtaProgress(
        stage: stage ?? this.stage,
        chunkIndex: chunkIndex ?? this.chunkIndex,
        chunkCount: chunkCount,
        ackedChunks: ackedChunks ?? this.ackedChunks,
        ackedBytes: ackedBytes ?? this.ackedBytes,
        totalBytes: totalBytes,
        attempt: attempt ?? this.attempt,
        lastAckedChunk:
            clearLastAcked ? null : (lastAckedChunk ?? this.lastAckedChunk),
        detail: detail ?? this.detail,
      );
}

/// The terminal outcome of [OtaSession.run].
class OtaResult {
  final OtaStage stage;

  /// Failure reason (null on success / abort).
  final String? reason;

  /// The stage the session was in when it failed / was aborted.
  final OtaStage stageAtEnd;
  final int? lastAckedChunk;
  final int chunkCount;
  final int framesSent;

  /// Whether CMD_UPDATE_END went out (success and abort send it; on failure
  /// the UI sends it when the user leaves, as the vendor does).
  final bool endSent;
  const OtaResult({
    required this.stage,
    required this.reason,
    required this.stageAtEnd,
    required this.lastAckedChunk,
    required this.chunkCount,
    required this.framesSent,
    required this.endSent,
  });

  bool get ok => stage == OtaStage.success;
}

/// One firmware update. Transport-agnostic: [send] writes a frame, [replies]
/// is the decoded event stream (only the OTA events are looked at). All
/// timing is on `dart:async` timers so tests drive it with fakeAsync.
class OtaSession {
  final OtaImage image;

  /// The EFFECTIVE MTU ([OtaProtocol.effectiveMtu]) — sizes the chunks and
  /// is the value told to the BMS.
  final int mtu;
  final OtaSend send;
  final Stream<BatteryEvent> replies;

  /// Session-level log line (the connection records it in Diagnostics and
  /// the raw log). Every TX frame is additionally raw-logged by [send].
  final void Function(String line) log;

  /// Names the pack in messages / the lock reason.
  final String serial;

  final Duration resendTimeout;
  final Duration recallTimeout;
  final Duration finishDelay;
  final Duration endDelay;

  /// Bound on mid-transfer RECALL restarts (the vendor has none).
  static const int maxRestarts = 3;

  OtaSession({
    required this.image,
    required this.mtu,
    required this.send,
    required this.replies,
    required this.serial,
    void Function(String line)? log,
    this.resendTimeout = OtaProtocol.resendTimeout,
    this.recallTimeout = OtaProtocol.recallTimeout,
    this.finishDelay = OtaProtocol.finishDelay,
    this.endDelay = OtaProtocol.endDelay,
  })  : log = log ?? ((_) {}),
        chunks = image.chunks(mtu) {
    _progress = OtaProgress(
      stage: OtaStage.idle,
      chunkIndex: 0,
      chunkCount: chunks.length,
      ackedChunks: 0,
      ackedBytes: 0,
      totalBytes: image.size,
      attempt: 0,
      lastAckedChunk: null,
    );
  }

  final List<OtaChunk> chunks;
  late OtaProgress _progress;
  final _progressCtl = StreamController<OtaProgress>.broadcast();
  final _done = Completer<OtaResult>();
  StreamSubscription<BatteryEvent>? _sub;
  Timer? _recallTimer;
  Timer? _resendTimer;
  Timer? _finishTimer;
  Timer? _endTimer;
  bool _started = false;
  int _curNum = 0;
  int _resendCount = 0;
  int _restarts = 0;
  int _framesSent = 0;
  bool _endSent = false;
  bool _firstChunkSent = false;

  OtaProgress get progress => _progress;
  Stream<OtaProgress> get progressStream => _progressCtl.stream;
  OtaStage get stage => _progress.stage;
  bool get inProgress => _started && !stage.terminal;
  int get framesSent => _framesSent;
  bool get endSent => _endSent;

  /// Abort is only offered before the first chunk goes out.
  bool get canAbort =>
      !stage.terminal &&
      !_firstChunkSent &&
      (stage == OtaStage.idle ||
          stage == OtaStage.mtu ||
          stage == OtaStage.awaitingRecall);

  void _set(OtaProgress p) {
    _progress = p;
    if (!_progressCtl.isClosed) _progressCtl.add(p);
  }

  /// Run the whole sequence; completes with the terminal result. Throws
  /// synchronously if called twice.
  Future<OtaResult> run() {
    if (_started) throw StateError('OTA session already started');
    _started = true;
    return _run();
  }

  Future<OtaResult> _run() async {
    if (chunks.isEmpty) {
      _fail('Refusing to flash an empty image');
      return _done.future;
    }
    _sub = replies.listen(_onReply);
    log('start: ${image.name} (${image.size} B, sha256 ${image.sha256Hex}) '
        'to $serial — mtu $mtu, payload cap ${OtaProtocol.payloadCap(mtu)} B, '
        '${chunks.length} chunks');
    _set(_progress.copyWith(stage: OtaStage.mtu));
    if (!await _tx(OtaProtocol.mtuFrame(mtu), 'OTA: CMD_SEND_MTU ($mtu)')) {
      return _done.future;
    }
    _set(_progress.copyWith(stage: OtaStage.awaitingRecall));
    _recallTimer = Timer(recallTimeout, () {
      _fail('No RECALL (FF 01 B1 02 EF) from the BMS within '
          '${recallTimeout.inSeconds} s of CMD_BEGIN_UPDATE — the BMS did '
          'not enter update mode. No firmware data was sent.');
    });
    await _tx(OtaProtocol.beginUpdate, 'OTA: CMD_BEGIN_UPDATE');
    return _done.future;
  }

  /// Abort before the first chunk: cancels the timers, sends CMD_UPDATE_END
  /// (the vendor's Back button, UVM:52-58) and completes as aborted. Returns
  /// false (and does nothing) once a chunk has been sent.
  Future<bool> abort() async {
    if (!canAbort) return false;
    final at = stage;
    _cancelTimers();
    log('aborted by the user at stage ${at.name} (no chunk was sent)');
    _set(_progress.copyWith(stage: OtaStage.aborted, detail: 'Aborted'));
    await sendEnd();
    _finish(OtaResult(
      stage: OtaStage.aborted,
      reason: null,
      stageAtEnd: at,
      lastAckedChunk: _progress.lastAckedChunk,
      chunkCount: chunks.length,
      framesSent: _framesSent,
      endSent: _endSent,
    ));
    return true;
  }

  /// The link dropped (or the connection was disposed) mid-session.
  void linkLost(String why) {
    if (stage.terminal) return;
    _fail('Connection lost: $why');
  }

  /// Send CMD_UPDATE_END once (idempotent). Called automatically after
  /// success (1 s later, UVM:131) and on abort; after a FAILURE the UI calls
  /// it when the user leaves the update screen (UVM:45-58).
  Future<bool> sendEnd() async {
    if (_endSent) return true;
    _endSent = true;
    try {
      await send(OtaProtocol.updateEnd, 'OTA: CMD_UPDATE_END');
      _framesSent++;
      log('CMD_UPDATE_END sent');
      return true;
    } catch (e) {
      log('CMD_UPDATE_END could not be sent: $e');
      return false;
    }
  }

  // --- internals -----------------------------------------------------------

  Future<bool> _tx(List<int> bytes, String label) async {
    if (stage.terminal) return false;
    try {
      await send(bytes, label);
      _framesSent++;
      return true;
    } catch (e) {
      _fail('Send failed at stage ${stage.name} ($label): $e');
      return false;
    }
  }

  void _onReply(BatteryEvent e) {
    if (stage.terminal) return;
    switch (e) {
      case OtaRecallEvent():
        _onRecall();
      case OtaAckEvent(:final chunk, :final status, :final checksum):
        _onAck(chunk, status, checksum);
      case OtaSuccessEvent():
        _onSuccess();
      default:
        break; // telemetry keeps flowing; not ours
    }
  }

  void _onRecall() {
    if (stage == OtaStage.awaitingRecall) {
      _recallTimer?.cancel();
      _recallTimer = null;
      log('RECALL received — BMS is in update mode, sending chunk 0 of '
          '${chunks.length}');
      _curNum = 0;
      _resendCount = 0;
      unawaited(_sendChunk(0));
      return;
    }
    // BM:825-834 runs the same code whenever RECALL arrives: restart from 0.
    if (stage == OtaStage.sending || stage == OtaStage.finishing) {
      _restarts++;
      if (_restarts > maxRestarts) {
        _fail('The BMS asked to restart the transfer (RECALL) '
            '$_restarts times — giving up');
        return;
      }
      log('RECALL received mid-transfer (restart $_restarts of '
          '$maxRestarts) — restarting from chunk 0 as the vendor app does');
      _resendTimer?.cancel();
      _finishTimer?.cancel();
      _curNum = 0;
      _resendCount = 0;
      _set(_progress.copyWith(
          ackedChunks: 0, ackedBytes: 0, clearLastAcked: true, attempt: 0));
      unawaited(_sendChunk(0));
      return;
    }
    log('RECALL ignored at stage ${stage.name}');
  }

  void _onAck(int chunk, int status, int checksum) {
    if (stage != OtaStage.sending) {
      // e.g. the BMS acking CMD_UPDATE_FINISH (number 0xEC00).
      log('ack for chunk 0x${chunk.toRadixString(16)} at stage '
          '${stage.name} ignored');
      return;
    }
    final want = OtaProtocol.ackChecksum(_curNum);
    if (chunk != _curNum || checksum != want) {
      // BM:841-843: a non-matching ack is ignored; the timer resends.
      log('ack ignored: chunk $chunk sum 0x${checksum.toRadixString(16)} '
          '(expected chunk $_curNum sum 0x${want.toRadixString(16)}) — '
          'the ${resendTimeout.inSeconds} s timer will resend');
      return;
    }
    _resendTimer?.cancel();
    _resendTimer = null;
    _resendCount = 0;
    final acked = chunks[_curNum];
    _set(_progress.copyWith(
      ackedChunks: _curNum + 1,
      ackedBytes: acked.offset + acked.payload.length,
      lastAckedChunk: _curNum,
      attempt: 0,
    ));
    _curNum++;
    unawaited(_sendChunk(_curNum));
  }

  /// BM:932-971 for chunk [i]; past the end -> finish.
  Future<void> _sendChunk(int i) async {
    if (stage.terminal) return;
    if (i >= chunks.length) {
      _beginFinish();
      return;
    }
    final c = chunks[i];
    _firstChunkSent = true;
    _set(_progress.copyWith(
      stage: OtaStage.sending,
      chunkIndex: i,
      attempt: _resendCount,
      detail: 'Chunk ${i + 1} of ${chunks.length}'
          '${_resendCount > 0 ? ' (resend $_resendCount of '
              '${OtaProtocol.maxResends})' : ''}',
    ));
    _armResend();
    await _tx(
      c.frame,
      'OTA: chunk $i/${chunks.length - 1} (${c.payload.length} B'
      '${_resendCount > 0 ? ', resend $_resendCount' : ''})',
    );
  }

  void _beginFinish() {
    if (stage.terminal) return;
    _set(_progress.copyWith(
      stage: OtaStage.finishing,
      chunkIndex: chunks.length,
      detail: _resendCount > 0
          ? 'All chunks acked — re-sending FINISH ($_resendCount of '
              '${OtaProtocol.maxResends})'
          : 'All chunks acked — sending FINISH',
    ));
    _finishTimer?.cancel();
    _finishTimer = Timer(finishDelay, () async {
      _finishTimer = null;
      if (stage.terminal) return;
      _armResend();
      await _tx(OtaProtocol.updateFinish,
          'OTA: CMD_UPDATE_FINISH${_resendCount > 0 ? ' (resend $_resendCount)' : ''}');
    });
  }

  void _armResend() {
    _resendTimer?.cancel();
    _resendTimer = Timer(resendTimeout, _onResendTimeout);
  }

  /// BM:49-63.
  void _onResendTimeout() {
    _resendTimer = null;
    if (stage.terminal) return;
    if (_resendCount >= OtaProtocol.maxResends) {
      if (stage == OtaStage.finishing) {
        _fail('No SUCCESS (AA BB 01 02 EF) from the BMS after '
            'CMD_UPDATE_FINISH was sent ${OtaProtocol.maxResends + 1} times');
      } else {
        _fail('No ack for chunk $_curNum of ${chunks.length} after '
            '${OtaProtocol.maxResends + 1} sends '
            '(${resendTimeout.inSeconds} s each)');
      }
      return;
    }
    _resendCount++;
    if (stage == OtaStage.finishing) {
      log('no SUCCESS after FINISH — resend $_resendCount of '
          '${OtaProtocol.maxResends}');
      _beginFinish();
    } else {
      log('no ack for chunk $_curNum — resend $_resendCount of '
          '${OtaProtocol.maxResends}');
      unawaited(_sendChunk(_curNum));
    }
  }

  void _onSuccess() {
    if (stage != OtaStage.finishing) {
      log('SUCCESS received at stage ${stage.name} with '
          '${_progress.ackedChunks} of ${chunks.length} chunks acked — '
          'IGNORED (the vendor app would accept it; a half-written image '
          'is not a success)');
      return;
    }
    _cancelTimers();
    log('SUCCESS received — the BMS accepted the image; sending '
        'CMD_UPDATE_END in ${endDelay.inMilliseconds} ms');
    _set(_progress.copyWith(stage: OtaStage.success, detail: 'Success'));
    _endTimer = Timer(endDelay, () async {
      _endTimer = null;
      await sendEnd();
      _finish(OtaResult(
        stage: OtaStage.success,
        reason: null,
        stageAtEnd: OtaStage.success,
        lastAckedChunk: _progress.lastAckedChunk,
        chunkCount: chunks.length,
        framesSent: _framesSent,
        endSent: _endSent,
      ));
    });
  }

  void _fail(String reason) {
    if (stage.terminal) return;
    final at = stage;
    _cancelTimers();
    log('FAILED at stage ${at.name}: $reason (last acked chunk: '
        '${_progress.lastAckedChunk ?? 'none'} of ${chunks.length})');
    _set(_progress.copyWith(stage: OtaStage.failed, detail: reason));
    _finish(OtaResult(
      stage: OtaStage.failed,
      reason: reason,
      stageAtEnd: at,
      lastAckedChunk: _progress.lastAckedChunk,
      chunkCount: chunks.length,
      framesSent: _framesSent,
      endSent: _endSent,
    ));
  }

  void _cancelTimers() {
    _recallTimer?.cancel();
    _resendTimer?.cancel();
    _finishTimer?.cancel();
    _endTimer?.cancel();
    _recallTimer = _resendTimer = _finishTimer = _endTimer = null;
  }

  void _finish(OtaResult r) {
    _cancelTimers();
    unawaited(_sub?.cancel());
    _sub = null;
    if (!_done.isCompleted) _done.complete(r);
    unawaited(_progressCtl.close());
  }
}

// ===========================================================================
// App-wide lock: one update at a time, and nothing else writes meanwhile.
// ===========================================================================

/// While a session is [OtaSession.inProgress] every other write, Pause,
/// Exit, background sampling and the not-streaming probe are refused with
/// [refuseReason]. Set / cleared by `BatteryConnection.runFirmwareUpdate`.
class OtaLock {
  static OtaSession? active;

  static bool get inProgress => active?.inProgress ?? false;

  /// Why something else is refused right now, or null when nothing is.
  static String? get refuseReason => inProgress
      ? 'A firmware update is in progress on ${active!.serial} — nothing '
          'else can be sent until it finishes'
      : null;
}
