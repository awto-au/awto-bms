/// GitHub #41: firmware update (OTA). Everything here runs against the fake
/// transport / a fake BMS — NO OTA frame is ever sent to real hardware.
///
/// The byte vectors are derived by hand from the vendor decompile
/// (BatteryManager.java `beginSendUpdateFile` / `getSum` / `getRecallSum`,
/// BatteryCMD.java) — see the spec at the top of lib/ota_update.dart.
library;

import 'dart:async';

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/ota_update.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A session wired to a recording send function and a controllable BMS.
class Harness {
  final sent = <List<int>>[];
  final labels = <String>[];
  final logs = <String>[];
  final events = StreamController<BatteryEvent>.broadcast();
  bool failSend = false;
  late final OtaSession session;

  Harness(
    List<int> bytes, {
    int mtu = 20,
    String name = 'PB51250506.bin',
    Duration resend = const Duration(seconds: 2),
    Duration recall = const Duration(seconds: 20),
    Duration finish = const Duration(milliseconds: 300),
    Duration end = const Duration(seconds: 1),
  }) {
    session = OtaSession(
      image: OtaImage(name: name, bytes: bytes),
      mtu: mtu,
      serial: 'JS-A',
      send: (b, l) async {
        if (failSend) throw StateError('GATT write failed');
        sent.add(List.of(b));
        labels.add(l);
      },
      replies: events.stream,
      log: logs.add,
      resendTimeout: resend,
      recallTimeout: recall,
      finishDelay: finish,
      endDelay: end,
    );
  }

  void recall() => events.add(const OtaRecallEvent());
  void ack(int n, {int? sum, int status = 0}) =>
      events.add(OtaAckEvent(n, status, sum ?? OtaProtocol.ackChecksum(n)));
  void success() => events.add(const OtaSuccessEvent());

  /// Only the data frames (`01 01 …`, excluding FINISH) sent so far.
  List<List<int>> get chunkFrames => [
        for (final f in sent)
          if (f.length >= 6 &&
              f[0] == 0x01 &&
              f[1] == 0x01 &&
              !_eq(f, OtaProtocol.updateFinish))
            f
      ];

  int count(List<int> frame) => sent.where((f) => _eq(f, frame)).length;
}

class Clock {
  DateTime t = DateTime.utc(2026, 9, 21, 12);
  void advance(Duration d) => t = t.add(d);
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 30 bytes: at mtu 20 (cap 12) that is chunks of 12, 12, 6.
final image30 = List<int>.generate(30, (i) => (i * 7 + 3) & 0xff);

const mtuFrame20 = [0xC3, 0xF2, 0x14, 0xED, 0xCE];

void main() {
  setUp(() => AppLog.instance.echoToConsole = false);

  // =========================================================================
  group('wire constants (BatteryCMD.java)', () {
    test('byte-exact', () {
      expect(OtaProtocol.beginUpdate, [0xEB, 0x90, 0x00, 0x07, 0xBB, 0x03, 0x40]);
      expect(OtaProtocol.recall, [0xFF, 0x01, 0xB1, 0x02, 0xEF]);
      expect(OtaProtocol.ackHead, [0x01, 0x01]);
      expect(OtaProtocol.updateFinish, [0x01, 0x01, 0xEC, 0x00, 0x00, 0x12]);
      expect(OtaProtocol.success, [0xAA, 0xBB, 0x01, 0x02, 0xEF]);
      expect(OtaProtocol.updateEnd,
          [0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04, 0xCC, 0xDD]);
      expect(OtaProtocol.mtuFrame(20), mtuFrame20);
      expect(OtaProtocol.mtuFrame(200), [0xC3, 0xF2, 0xC8, 0xED, 0xCE]);
      expect(OtaProtocol.mtuFrame(0x1F4), [0xC3, 0xF2, 0xF4, 0xED, 0xCE],
          reason: 'only the low byte goes out (BM:145)');
    });

    test('effective MTU: min(negotiated, 200), 20 when unknown (MM:159-162)',
        () {
      expect(OtaProtocol.effectiveMtu(null), 20);
      expect(OtaProtocol.effectiveMtu(0), 20);
      expect(OtaProtocol.effectiveMtu(23), 23);
      expect(OtaProtocol.effectiveMtu(185), 185);
      expect(OtaProtocol.effectiveMtu(247), 200);
      expect(OtaProtocol.effectiveMtu(512), 200);
      expect(OtaProtocol.effectiveMtu(517), 200);
    });

    test('payload cap = (mtu/10)*9 - 6 with integer division (BM:934-936)',
        () {
      expect(OtaProtocol.payloadCap(20), 12);
      expect(OtaProtocol.payloadCap(23), 12); // 23/10 = 2
      expect(OtaProtocol.payloadCap(29), 12);
      expect(OtaProtocol.payloadCap(30), 21);
      expect(OtaProtocol.payloadCap(200), 174);
      expect(OtaProtocol.payloadCap(247), 210);
      expect(OtaProtocol.payloadCap(512), 453);
    });
  });

  // =========================================================================
  group('checksums (BM getSum / getRecallSum)', () {
    test('getSum: two\'s complement of the byte sum, frame sums to 0', () {
      // Hand vectors.
      expect(OtaProtocol.checksum([]), 0x00);
      expect(OtaProtocol.checksum([0x01]), 0xFF);
      expect(OtaProtocol.checksum([0x01, 0x01, 0xEC, 0x00, 0x00]), 0x12);
      expect(OtaProtocol.checksum([0xFF, 0x01]), 0x00); // 0x100 -> 0
      expect(OtaProtocol.checksum([0x80, 0x80, 0x01]), 0xFF);
    });

    test('CMD_UPDATE_FINISH is exactly a len-0 data frame numbered 0xEC00',
        () {
      expect(OtaProtocol.chunkFrame(0xEC00, const []), OtaProtocol.updateFinish);
    });

    test('data frame vectors', () {
      // chunk 0, payload [00]: 01+01+00+00+01+00 = 0x03 -> 0xFD
      expect(OtaProtocol.chunkFrame(0, [0x00]),
          [0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0xFD]);
      // chunk 1, payload [FF 01]: 01+01+00+01+02+FF+01 = 0x105 -> 0xFB
      expect(OtaProtocol.chunkFrame(1, [0xFF, 0x01]),
          [0x01, 0x01, 0x00, 0x01, 0x02, 0xFF, 0x01, 0xFB]);
      // chunk 300 = 0x012C: number is BIG-endian (BM:958-959).
      final f = OtaProtocol.chunkFrame(300, [0x10, 0x20, 0x30]);
      expect(f.sublist(0, 5), [0x01, 0x01, 0x01, 0x2C, 0x03]);
      // 01+01+01+2C+03+10+20+30 = 0x92 -> 0x6E
      expect(f.last, 0x6E);
      // Every frame sums to zero mod 256.
      for (final frame in [
        OtaProtocol.chunkFrame(0, [0x00]),
        OtaProtocol.chunkFrame(1, [0xFF, 0x01]),
        f,
        OtaProtocol.chunkFrame(0xFFFF, List.filled(255, 0xAB)),
      ]) {
        expect(frame.fold<int>(0, (a, b) => a + b) & 0xff, 0);
      }
    });

    test('getRecallSum: -(numHi + numLo + 8) & 0xFF', () {
      expect(OtaProtocol.ackChecksum(0), 0xF8);
      expect(OtaProtocol.ackChecksum(1), 0xF7);
      expect(OtaProtocol.ackChecksum(0x0102), 0xF5); // -(1+2+8) = -11
      expect(OtaProtocol.ackChecksum(0x8080), 0xF8); // -(128+128+8) = -264
      expect(OtaProtocol.ackChecksum(0xFFFF), 0xFA); // -(255+255+8) = -518
      expect(OtaProtocol.ackChecksum(0xEC00), 0x0C); // -(0xEC+8) = -244
    });

    test('chunkFrame refuses a number or payload that does not fit', () {
      expect(() => OtaProtocol.chunkFrame(0x10000, []), throwsArgumentError);
      expect(() => OtaProtocol.chunkFrame(-1, []), throwsArgumentError);
      expect(() => OtaProtocol.chunkFrame(0, List.filled(256, 0)),
          throwsArgumentError);
    });
  });

  // =========================================================================
  group('OtaImage.chunks — exact sizes, numbering, last chunk', () {
    test('mtu 200 (512 negotiated -> capped): cap 174, 400 B -> 174/174/52',
        () {
      final bytes = List<int>.generate(400, (i) => i & 0xff);
      final img = OtaImage(name: 'x.bin', bytes: bytes);
      expect(img.chunkCount(200), 3);
      final c = img.chunks(200);
      expect(c.length, 3);
      expect(c.map((x) => x.index), [0, 1, 2]);
      expect(c.map((x) => x.offset), [0, 174, 348]);
      expect(c.map((x) => x.payload.length), [174, 174, 52]);
      expect(c[0].frame.length, 180);
      expect(c[2].frame.length, 58);
      expect(c[2].frame.sublist(0, 5), [0x01, 0x01, 0x00, 0x02, 52]);
      expect(c[2].payload, bytes.sublist(348));
      // Payload bytes are the raw file (BM:951-955), nothing added.
      expect([for (final x in c) ...x.payload], bytes);
    });

    test('mtu 20 (vendor default): cap 12, 30 B -> 12/12/6', () {
      final img = OtaImage(name: 'x.bin', bytes: image30);
      final c = img.chunks(20);
      expect(c.map((x) => x.payload.length), [12, 12, 6]);
      expect(c[1].frame,
          [0x01, 0x01, 0x00, 0x01, 12, ...image30.sublist(12, 24),
            OtaProtocol.checksum([0x01, 0x01, 0x00, 0x01, 12, ...image30.sublist(12, 24)])]);
    });

    test('an exact multiple has no empty trailing chunk', () {
      final img = OtaImage(name: 'x.bin', bytes: List.filled(24, 1));
      expect(img.chunks(20).map((x) => x.payload.length), [12, 12]);
    });

    test('a raw mtu of 512 (cap 453) is REFUSED: the len byte is 8-bit '
        '(BM:960) — the vendor cap of 200 is what keeps chunks valid', () {
      final img = OtaImage(name: 'x.bin', bytes: List.filled(1000, 1));
      expect(OtaProtocol.payloadCap(512), 453);
      expect(() => img.chunks(512), throwsArgumentError);
      expect(() => img.chunkCount(512), throwsArgumentError);
      // 290 is the largest mtu whose cap (255) still fits.
      expect(img.chunks(290).map((x) => x.payload.length), [255, 255, 255, 235]);
      expect(() => img.chunks(300), throwsArgumentError);
    });

    test('numbering past 255 is big-endian in the frame', () {
      final img = OtaImage(name: 'x.bin', bytes: List.filled(12 * 260, 1));
      final c = img.chunks(20);
      expect(c.length, 260);
      expect(c[256].frame.sublist(2, 4), [0x01, 0x00]);
      expect(c[259].frame.sublist(2, 4), [0x01, 0x03]);
    });

    test('empty image -> no chunks; tiny mtu refused', () {
      expect(OtaImage(name: 'x.bin', bytes: const []).chunks(20), isEmpty);
      expect(() => OtaImage(name: 'x.bin', bytes: const [1]).chunks(9),
          throwsArgumentError);
    });

    test('sha256 of the image', () {
      expect(OtaImage(name: 'x.bin', bytes: const []).sha256Hex,
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(OtaImage(name: 'x.bin', bytes: 'abc'.codeUnits).sha256Hex,
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
  });

  // =========================================================================
  group('OtaSession — happy path byte-for-byte', () {
    test('MTU, BEGIN, RECALL, 3 acked chunks, FINISH, SUCCESS, END', () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        expect(h.sent, [mtuFrame20, OtaProtocol.beginUpdate]);
        expect(h.session.stage, OtaStage.awaitingRecall);
        expect(h.session.canAbort, isTrue);

        h.recall();
        async.flushMicrotasks();
        final chunks = OtaImage(name: 'x', bytes: image30).chunks(20);
        expect(h.sent.length, 3);
        expect(h.sent[2], chunks[0].frame);
        expect(h.session.stage, OtaStage.sending);
        expect(h.session.canAbort, isFalse);
        expect(h.session.progress.percent, 0);

        h.ack(0);
        async.flushMicrotasks();
        expect(h.sent[3], chunks[1].frame);
        expect(h.session.progress.ackedChunks, 1);
        expect(h.session.progress.ackedBytes, 12);
        expect(h.session.progress.percent, 40);
        expect(h.session.progress.lastAckedChunk, 0);

        h.ack(1);
        async.flushMicrotasks();
        expect(h.sent[4], chunks[2].frame);
        expect(h.sent[4].length, 6 + 6);

        h.ack(2);
        async.flushMicrotasks();
        expect(h.session.stage, OtaStage.finishing);
        expect(h.session.progress.percent, 100);
        expect(h.sent.length, 5, reason: 'FINISH waits 300 ms (BM:928)');
        async.elapse(const Duration(milliseconds: 300));
        expect(h.sent[5], OtaProtocol.updateFinish);

        h.success();
        async.flushMicrotasks();
        expect(h.session.stage, OtaStage.success);
        expect(result, isNull, reason: 'END goes out 1 s later (UVM:131)');
        async.elapse(const Duration(seconds: 1));
        expect(h.sent[6], OtaProtocol.updateEnd);
        expect(h.sent.length, 7);
        expect(result!.ok, isTrue);
        expect(result!.endSent, isTrue);
        expect(result!.lastAckedChunk, 2);
        expect(result!.framesSent, 7);
        expect(h.labels.first, 'OTA: CMD_SEND_MTU (20)');
        expect(h.labels, everyElement(startsWith('OTA:')));
        expect(h.session.inProgress, isFalse);
      });
    });

    test('an ack whose status byte is anything is accepted (never compared)',
        () {
      fakeAsync((async) {
        final h = Harness(image30);
        h.session.run();
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        h.ack(0, status: 0x99);
        async.flushMicrotasks();
        expect(h.chunkFrames.length, 2);
        expect(h.session.progress.ackedChunks, 1);
      });
    });
  });

  // =========================================================================
  group('OtaSession — retry / timeout / refusal paths', () {
    test('no ack: the chunk is resent every 2 s, 10 times, then FAILED', () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        final chunk0 = h.chunkFrames.single;
        for (var i = 1; i <= 10; i++) {
          async.elapse(const Duration(seconds: 2));
          expect(h.count(chunk0), 1 + i, reason: 'resend $i');
          expect(h.session.stage, OtaStage.sending);
          expect(h.session.progress.attempt, i);
        }
        expect(result, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(result!.stage, OtaStage.failed);
        expect(result!.stageAtEnd, OtaStage.sending);
        expect(result!.reason, contains('chunk 0 of 3'));
        expect(result!.reason, contains('11 sends'));
        expect(result!.lastAckedChunk, isNull);
        expect(result!.endSent, isFalse,
            reason: 'the vendor sends END only when the user leaves');
        expect(h.count(chunk0), 11);
        expect(h.chunkFrames.length, 11);
        expect(h.session.inProgress, isFalse);
      });
    });

    test('wrong chunk number / wrong sum are ignored -> resend; a correct ack '
        'then proceeds', () {
      fakeAsync((async) {
        final h = Harness(image30);
        h.session.run();
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        h.ack(1); // wrong number
        async.flushMicrotasks();
        h.ack(0, sum: 0x00); // wrong sum
        async.flushMicrotasks();
        expect(h.chunkFrames.length, 1, reason: 'nothing advanced');
        expect(h.session.progress.ackedChunks, 0);
        expect(h.logs.where((l) => l.contains('ack ignored')).length, 2);
        async.elapse(const Duration(seconds: 2));
        expect(h.chunkFrames.length, 2);
        expect(h.chunkFrames[1], h.chunkFrames[0], reason: 'a resend');
        h.ack(0);
        async.flushMicrotasks();
        expect(h.chunkFrames.length, 3);
        expect(h.chunkFrames[2][3], 0x01, reason: 'chunk 1 now');
        expect(h.session.progress.attempt, 0, reason: 'reset on a good ack');
      });
    });

    test('RECALL never arrives: FAILED after 20 s with NO chunk sent', () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 19));
        expect(result, isNull);
        async.elapse(const Duration(seconds: 1));
        expect(result!.stage, OtaStage.failed);
        expect(result!.stageAtEnd, OtaStage.awaitingRecall);
        expect(result!.reason, contains('No RECALL'));
        expect(h.sent, [mtuFrame20, OtaProtocol.beginUpdate]);
        expect(h.chunkFrames, isEmpty);
      });
    });

    test('SUCCESS never arrives after FINISH: FINISH resent 10x then FAILED',
        () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        for (var i = 0; i < 3; i++) {
          h.ack(i);
          async.flushMicrotasks();
        }
        async.elapse(const Duration(milliseconds: 300));
        expect(h.count(OtaProtocol.updateFinish), 1);
        for (var i = 1; i <= 10; i++) {
          async.elapse(const Duration(milliseconds: 2300));
          expect(h.count(OtaProtocol.updateFinish), 1 + i);
        }
        expect(result, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(result!.stage, OtaStage.failed);
        expect(result!.stageAtEnd, OtaStage.finishing);
        expect(result!.reason, contains('No SUCCESS'));
        expect(result!.lastAckedChunk, 2);
        expect(h.count(OtaProtocol.updateFinish), 11);
        expect(h.count(OtaProtocol.updateEnd), 0);
      });
    });

    test('abort before the first chunk sends END and nothing else', () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        expect(h.session.canAbort, isTrue);
        var aborted = false;
        h.session.abort().then((v) => aborted = v);
        async.flushMicrotasks();
        expect(aborted, isTrue);
        expect(result!.stage, OtaStage.aborted);
        expect(result!.stageAtEnd, OtaStage.awaitingRecall);
        expect(result!.endSent, isTrue);
        expect(h.sent, [mtuFrame20, OtaProtocol.beginUpdate, OtaProtocol.updateEnd]);
        // A late RECALL changes nothing.
        h.recall();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(h.sent.length, 3);
      });
    });

    test('abort is refused once a chunk has been sent', () {
      fakeAsync((async) {
        final h = Harness(image30);
        h.session.run();
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        expect(h.session.canAbort, isFalse);
        var aborted = true;
        h.session.abort().then((v) => aborted = v);
        async.flushMicrotasks();
        expect(aborted, isFalse);
        expect(h.session.stage, OtaStage.sending);
        expect(h.count(OtaProtocol.updateEnd), 0);
      });
    });

    test('a premature SUCCESS (chunks still unacked) is ignored, not trusted',
        () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        h.ack(0);
        async.flushMicrotasks();
        h.success();
        async.flushMicrotasks();
        expect(h.session.stage, OtaStage.sending);
        expect(result, isNull);
        expect(h.logs.any((l) => l.contains('IGNORED')), isTrue);
        h.ack(1);
        async.flushMicrotasks();
        h.ack(2);
        async.flushMicrotasks();
        h.success(); // now every chunk is acked: accepted
        async.flushMicrotasks();
        expect(h.session.stage, OtaStage.success);
        async.elapse(const Duration(seconds: 1));
        expect(result!.ok, isTrue);
      });
    });

    test('SUCCESS is accepted at stage finishing even before FINISH went out '
        '(the vendor accepts it any time); success cancels the FINISH timer',
        () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        for (var i = 0; i < 3; i++) {
          h.ack(i);
          async.flushMicrotasks();
        }
        h.success(); // within the 300 ms before FINISH
        async.flushMicrotasks();
        expect(h.session.stage, OtaStage.success);
        async.elapse(const Duration(seconds: 5));
        expect(result!.ok, isTrue);
        expect(h.count(OtaProtocol.updateFinish), 0);
        expect(h.count(OtaProtocol.updateEnd), 1);
      });
    });

    test('a mid-transfer RECALL restarts from chunk 0 (vendor), bounded', () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        h.ack(0);
        async.flushMicrotasks();
        expect(h.chunkFrames.last[3], 1);
        h.recall();
        async.flushMicrotasks();
        expect(h.chunkFrames.last[3], 0, reason: 'restarted from chunk 0');
        expect(h.session.progress.ackedChunks, 0);
        expect(h.session.progress.lastAckedChunk, isNull);
        for (var i = 0; i < OtaSession.maxRestarts; i++) {
          h.recall();
          async.flushMicrotasks();
        }
        expect(result!.stage, OtaStage.failed);
        expect(result!.reason, contains('RECALL'));
      });
    });

    test('a link drop mid-transfer fails with the stage and last acked chunk',
        () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        h.ack(0);
        async.flushMicrotasks();
        h.session.linkLost('disconnected');
        async.flushMicrotasks();
        expect(result!.stage, OtaStage.failed);
        expect(result!.stageAtEnd, OtaStage.sending);
        expect(result!.reason, contains('Connection lost'));
        expect(result!.lastAckedChunk, 0);
        async.elapse(const Duration(seconds: 30));
        expect(h.chunkFrames.length, 2, reason: 'no resends after failure');
      });
    });

    test('a send failure fails the session at once', () {
      fakeAsync((async) {
        final h = Harness(image30);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        h.recall();
        async.flushMicrotasks();
        h.failSend = true;
        h.ack(0);
        async.flushMicrotasks();
        expect(result!.stage, OtaStage.failed);
        expect(result!.reason, contains('Send failed'));
        expect(result!.reason, contains('GATT write failed'));
      });
    });

    test('an empty image is refused before anything is sent', () {
      fakeAsync((async) {
        final h = Harness(const []);
        OtaResult? result;
        h.session.run().then((r) => result = r);
        async.flushMicrotasks();
        expect(result!.stage, OtaStage.failed);
        expect(h.sent, isEmpty);
      });
    });

    test('run() twice is refused', () {
      fakeAsync((async) {
        final h = Harness(image30);
        h.session.run();
        async.flushMicrotasks();
        expect(() => h.session.run(), throwsStateError);
      });
    });

    test('sendEnd is idempotent and reports failure', () {
      fakeAsync((async) {
        final h = Harness(image30);
        var ok = false;
        h.session.sendEnd().then((v) => ok = v);
        async.flushMicrotasks();
        expect(ok, isTrue);
        h.session.sendEnd().then((v) => ok = v);
        async.flushMicrotasks();
        expect(h.count(OtaProtocol.updateEnd), 1);
        final h2 = Harness(image30)..failSend = true;
        h2.session.sendEnd().then((v) => ok = v);
        async.flushMicrotasks();
        expect(ok, isFalse);
      });
    });
  });

  // =========================================================================
  group('pre-flight gates', () {
    OtaPreflightInput good({
      bool connected = true,
      bool streaming = true,
      int? soc = 80,
      bool fault = false,
      ChargeState cs = ChargeState.idle,
      double? current = 0.1,
      bool awake = true,
      OtaImage? image,
      bool noImage = false,
      String? version = 'JS5.1',
      bool other = false,
    }) =>
        OtaPreflightInput(
          connected: connected,
          streaming: streaming,
          soc: soc,
          activeFault: fault,
          chargeState: cs,
          currentA: current,
          keepAwake: awake,
          image: noImage
              ? null
              : (image ?? OtaImage(name: '8803250506.bin', bytes: const [1])),
          firmwareVersion: version,
          otherWriteInFlight: other,
        );

    test('all pass', () {
      final g = otaPreflight(good());
      expect(g.length, 8);
      expect(otaPreflightPasses(g), isTrue);
      expect(otaPreflightRefusal(g), '');
    });

    test('each gate refuses on its own', () {
      final cases = <String, OtaPreflightInput>{
        'Battery connected and streaming': good(connected: false),
        'streaming': good(streaming: false),
        'SOC at least 30 %': good(soc: 29),
        'soc unknown': good(soc: null),
        'No active fault': good(fault: true),
        'Not charging or discharging (current ~0 A)': good(cs: ChargeState.charging),
        'current too high': good(current: 0.6),
        'current unknown': good(current: null),
        'Device will stay awake': good(awake: false),
        'Firmware file chosen': good(noImage: true),
        'empty file': good(image: OtaImage(name: 'a.bin', bytes: const [])),
        'Current firmware version known': good(version: null),
        'version blank': good(version: ' '),
        'No other write in progress': good(other: true),
      };
      cases.forEach((name, input) {
        final g = otaPreflight(input);
        expect(otaPreflightPasses(g), isFalse, reason: name);
        expect(g.where((x) => !x.ok).length, 1, reason: name);
        expect(otaPreflightRefusal(g), isNotEmpty, reason: name);
      });
      expect(otaPreflightPasses(otaPreflight(good(soc: 30))), isTrue);
      expect(otaPreflightPasses(otaPreflight(good(current: 0.5))), isTrue);
      expect(otaPreflightPasses(otaPreflight(good(cs: ChargeState.discharging))),
          isFalse);
    });

    test('refusal names every failed gate', () {
      final g = otaPreflight(good(soc: 10, fault: true));
      expect(otaPreflightRefusal(g), contains('SOC at least'));
      expect(otaPreflightRefusal(g), contains('No active fault'));
    });
  });

  // =========================================================================
  group('file-name warning (Global.java / MainModel.java)', () {
    test('known images for their family pass', () {
      expect(otaFilenameWarning('PB51250506.bin', 'JS3.1'), isNull);
      expect(otaFilenameWarning('PB51250506.bin', 'JS1.0'), isNull);
      expect(otaFilenameWarning('8803250506.bin', 'JS5.1'), isNull);
      expect(otaFilenameWarning('8803250601.BIN', 'js5.2'), isNull);
    });
    test('unknown names warn', () {
      expect(otaFilenameWarning('firmware.bin', 'JS5.1'), contains('PB51'));
      expect(otaFilenameWarning('PB51250506.hex', 'JS3.1'), isNotNull);
    });
    test('family mismatch warns', () {
      expect(otaFilenameWarning('PB51250506.bin', 'JS5.1'), contains('JS5'));
      expect(otaFilenameWarning('8803250506.bin', 'JS3.2'), contains('JS3'));
    });
    test('unknown version warns that the family cannot be checked', () {
      expect(otaFilenameWarning('PB51250506.bin', null), contains('unknown'));
      expect(otaFilenameWarning('PB51250506.bin', '1.0.1'), contains('1.0.1'));
    });
  });

  // =========================================================================
  group('typed confirmation', () {
    test('exact serial (whitespace-trimmed) only', () {
      expect(otaConfirmationMatches('JS-2C14AA', 'JS-2C14AA'), isTrue);
      expect(otaConfirmationMatches('  JS-2C14AA ', 'JS-2C14AA'), isTrue);
      expect(otaConfirmationMatches('js-2c14aa', 'JS-2C14AA'), isFalse);
      expect(otaConfirmationMatches('JS-2C14A', 'JS-2C14AA'), isFalse);
      expect(otaConfirmationMatches('', 'JS-2C14AA'), isFalse);
      expect(otaConfirmationMatches('', ''), isFalse);
      expect(otaConfirmationMatches('x', null), isFalse);
    });
  });

  // =========================================================================
  group('parser: OTA replies decode ONLY while otaActive', () {
    const soc = [0xA9, 0x64, 50, 0x10, 0x27, 0x00, 0x88, 0x13, 0x00, 0xBA, 0x5E];

    test('inactive: the byte patterns stay unrecognised (decoder unchanged)',
        () {
      final s = BatteryState();
      final events = <BatteryEvent>[];
      final p = BatteryParser(state: s, onEvent: events.add);
      p.addBytes([...OtaProtocol.recall, ...soc]);
      p.addBytes(
          [0x01, 0x01, 0x00, 0x00, 0x00, 0xF8, ...OtaProtocol.success, ...soc]);
      expect(events.whereType<SocEvent>().length, 2);
      expect(events.where(isOtaEvent), isEmpty);
      expect(s.unrecognisedBytes, 5 + 6 + 5);
      expect(p.knownBegins, isNot(contains((0x01, 0x01))));
      expect(p.otaBegins, {(0xFF, 0x01), (0x01, 0x01), (0xAA, 0xBB)});
    });

    test('active: RECALL, ACK, SUCCESS decode, interleaved with telemetry',
        () {
      final s = BatteryState();
      final events = <BatteryEvent>[];
      final p = BatteryParser(state: s, onEvent: events.add)..otaActive = true;
      // Split across notifications, telemetry in between.
      p.addBytes([0xFF]);
      p.addBytes([0x01, 0xB1, 0x02, 0xEF, ...soc, 0x01, 0x01, 0x01]);
      p.addBytes([0x2C, 0x07, 0xCB, ...OtaProtocol.success]);
      expect(events.map((e) => e.runtimeType), [
        OtaRecallEvent,
        SocEvent,
        OtaAckEvent,
        OtaSuccessEvent,
      ]);
      final ack = events[2] as OtaAckEvent;
      expect(ack.chunk, 300, reason: 'big-endian');
      expect(ack.status, 0x07);
      expect(ack.checksum, 0xCB);
      expect(s.unrecognisedBytes, 0);
      expect(events.where(isOtaEvent).every((e) => !BatteryConnection.isTelemetryEvent(e)),
          isTrue);
    });

    test('active: a bad RECALL / SUCCESS tail resyncs instead of decoding', () {
      final s = BatteryState();
      final events = <BatteryEvent>[];
      final p = BatteryParser(state: s, onEvent: events.add)..otaActive = true;
      p.addBytes([0xFF, 0x01, 0xB1, 0x02, 0x00, ...soc]);
      p.addBytes([0xAA, 0xBB, 0x01, 0x02, 0x00, ...soc]);
      expect(events.whereType<SocEvent>().length, 2);
      expect(events.where(isOtaEvent), isEmpty);
      expect(s.unrecognisedBytes, 10);
    });

    test('reset() clears otaActive', () {
      final p = BatteryParser()..otaActive = true;
      p.reset();
      expect(p.otaActive, isFalse);
    });
  });

  // =========================================================================
  group('BatteryConnection.runFirmwareUpdate + OtaLock (fake transport)', () {
    Future<void> settle([int n = 8]) async {
      for (var i = 0; i < n; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<(BatteryConnection, FakeTransport, FakeLink)> connected(
        {Clock? clock}) async {
      final t = FakeTransport();
      final c = BatteryConnection(
          transport: t, now: clock == null ? DateTime.now : () => clock.t);
      await c.connectTo('dev-a', name: 'JS-A');
      final link = t.lastLink!;
      link.onData!([0xA8, 0xAC, 0x00, 1, 1, 0, 1, 0, 0, 0xB9, 0x21]); // BAL
      t.writes.clear();
      return (c, t, link);
    }

    tearDown(() => OtaLock.active = null);

    test('happy path through the real parser; the lock refuses everything '
        'else meanwhile and is released after', () async {
      final (c, t, link) = await connected();
      link.mtu = 517; // negotiated -> effective 200
      final img = OtaImage(name: '8803250506.bin', bytes: List.filled(200, 0x5A));
      final done = c.runFirmwareUpdate(img,
          resendTimeout: const Duration(milliseconds: 200),
          recallTimeout: const Duration(milliseconds: 500),
          finishDelay: const Duration(milliseconds: 10),
          endDelay: const Duration(milliseconds: 10));
      await settle();
      expect(c.otaInProgress, isTrue);
      expect(OtaLock.inProgress, isTrue);
      expect(c.parser.otaActive, isTrue);
      expect(t.writes, [
        [0xC3, 0xF2, 0xC8, 0xED, 0xCE],
        OtaProtocol.beginUpdate,
      ]);

      // Every other write is refused with the OTA reason.
      await expectLater(c.setSleepMode(false), throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('firmware update'))));
      await expectLater(
          c.sendGateControl(GateAction.chargeMos, on: true), throwsStateError);
      expect(t.writes.length, 2, reason: 'nothing else went out');
      // The manager's release paths are refused too.
      final m = BatteryManager(transport: t)..batteries.add(c);
      await m.pauseLive();
      expect(c.connState, ConnState.connected);
      await m.enterSampling(const Duration(seconds: 60));
      expect(m.isSampling, isFalse);
      expect(AppLog.instance.entries.any((e) => e.message.contains('refused')),
          isTrue);

      // The BMS replies come through the real link -> parser -> session.
      link.onData!(OtaProtocol.recall);
      await settle();
      final chunks = img.chunks(200);
      expect(chunks.length, 2);
      expect(t.writes[2], chunks[0].frame);
      link.onData!([0x01, 0x01, 0x00, 0x00, 0x00, OtaProtocol.ackChecksum(0)]);
      await settle();
      expect(t.writes[3], chunks[1].frame);
      link.onData!([0x01, 0x01, 0x00, 0x01, 0x00, OtaProtocol.ackChecksum(1)]);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(t.writes[4], OtaProtocol.updateFinish);
      link.onData!(OtaProtocol.success);
      await settle();
      final r = await done;
      expect(r.ok, isTrue);
      expect(t.writes[5], OtaProtocol.updateEnd);
      expect(t.writes.length, 6);
      expect(c.otaInProgress, isFalse);
      expect(OtaLock.inProgress, isFalse);
      expect(c.parser.otaActive, isFalse);
      // Writes work again.
      await c.setSleepMode(false);
      expect(t.writes.length, 7);
      await c.dispose();
    });

    test('unknown link MTU -> the vendor default 20 (12-byte chunks)', () async {
      final (c, t, link) = await connected();
      expect(link.mtu, isNull);
      final done = c.runFirmwareUpdate(
          OtaImage(name: 'PB51250506.bin', bytes: List.filled(13, 1)),
          recallTimeout: const Duration(milliseconds: 50));
      await settle();
      expect(t.writes.first, [0xC3, 0xF2, 0x14, 0xED, 0xCE]);
      final r = await done;
      expect(r.stage, OtaStage.failed);
      expect(r.stageAtEnd, OtaStage.awaitingRecall);
      expect(t.writes.length, 2, reason: 'no chunk without RECALL');
      await c.dispose();
    });

    test('a link drop mid-flash fails the session and releases the lock',
        () async {
      final (c, t, link) = await connected();
      final done = c.runFirmwareUpdate(
          OtaImage(name: 'PB51250506.bin', bytes: List.filled(30, 1)),
          resendTimeout: const Duration(seconds: 5));
      await settle();
      link.onData!(OtaProtocol.recall);
      await settle();
      link.onData!([0x01, 0x01, 0x00, 0x00, 0x00, OtaProtocol.ackChecksum(0)]);
      await settle();
      link.dropLink();
      await settle();
      final r = await done;
      expect(r.stage, OtaStage.failed);
      expect(r.reason, contains('Connection lost'));
      expect(r.lastAckedChunk, 0);
      expect(OtaLock.inProgress, isFalse);
      expect(t.writes.length, 4);
      await c.dispose();
    });

    test('refused when not connected, on a demo battery, or while another '
        'update runs', () async {
      final img = OtaImage(name: 'PB51250506.bin', bytes: const [1]);
      final idle = BatteryConnection(transport: FakeTransport());
      await expectLater(idle.runFirmwareUpdate(img), throwsStateError);
      final demo = BatteryConnection(transport: FakeTransport());
      await demo.startDemo();
      await expectLater(demo.runFirmwareUpdate(img), throwsStateError);
      await demo.dispose();

      final (c, _, _) = await connected();
      final (c2, _, _) = await connected();
      final first = c.runFirmwareUpdate(img,
          recallTimeout: const Duration(milliseconds: 50));
      await settle();
      expect(OtaLock.inProgress, isTrue);
      await expectLater(c2.runFirmwareUpdate(img), throwsStateError);
      await first;
      await c.dispose();
      await c2.dispose();
    });

    test('the not-streaming probe (a write) is skipped during an update',
        () async {
      final clock = Clock();
      final (c, t, link) = await connected(clock: clock);
      final done = c.runFirmwareUpdate(
          OtaImage(name: 'PB51250506.bin', bytes: const [1]),
          recallTimeout: const Duration(milliseconds: 50));
      await settle();
      clock.advance(const Duration(seconds: 11));
      expect(c.notStreaming, isTrue);
      c.watchdogTick();
      await settle();
      expect(c.probeInFlight, isFalse, reason: 'AT+V would be a write');
      expect(t.writes.length, 2);
      await done;
      // After the update the watchdog is back.
      c.watchdogTick();
      expect(c.probeInFlight, isTrue);
      await c.dispose();
      expect(link.disconnected, isTrue);
    });

    test('OtaLock reason is null when nothing runs', () {
      expect(OtaLock.inProgress, isFalse);
      expect(OtaLock.refuseReason, isNull);
    });
  });
}
