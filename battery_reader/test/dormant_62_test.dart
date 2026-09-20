/// GitHub #62 (remaining parts): dormant-BMS classification via the AT+V
/// probe, the user-initiated recovery ladder, the parallel-bank warning and
/// the corrected standby-ack semantics.
///
/// Verified live (2026-09-20): the BLE bridge is a separate module. A pack
/// whose BMS MCU is not running still connects, answers AT+V with ONLY the
/// bridge's single 0x30 status byte (no AC 9A version frame) and ignores
/// every framed command. A pack whose BMS is awake answers '0' + AC 9A.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/write_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// BAL_STATUS (A8 AC) with chgMos = disMos = 1 — one telemetry frame.
const bal = [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21];

/// VERSION (AC 9A) '1.0.1' — the answer of an AWAKE BMS to AT+V.
const version = [0xAC, 0x9A, 0x31, 0x2E, 0x30, 0x2E, 0x31, 0xBD, 0x10];

/// The vendor's both-MOS-on gate frame (its de-facto wake).
const vendorWake = [
  0xC3, 0x1E, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD4, 0x3B
];

/// SLEEP_SET_SUCCESS: byte0 == 0 => standby setting ON.
List<int> sleepAck({required bool on}) => [0xAC, 0xCA, on ? 0 : 1, 0xDE, 0xED];

Future<void> settle([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Clock {
  DateTime t = DateTime.utc(2026, 9, 20, 12);
  void advance(Duration d) => t = t.add(d);
  int get ms => t.millisecondsSinceEpoch;
}

/// A connected link that has been silent for 10 s (the watchdog threshold),
/// with the handshake writes dropped and a 40 ms probe window.
Future<(BatteryConnection, FakeTransport, Clock)> silentLink(
    {int silentS = 10}) async {
  final clock = Clock();
  final t = FakeTransport();
  final c = BatteryConnection(
    transport: t,
    now: () => clock.t,
    probeWindow: const Duration(milliseconds: 40),
  );
  await c.connectTo('dev-aa', name: 'JS-2C14AA');
  t.writes.clear();
  clock.advance(Duration(seconds: silentS));
  return (c, t, clock);
}

Future<void> probeWindow() =>
    Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  setUp(() {
    AppLog.instance.clear();
    AppLog.instance.echoToConsole = false;
  });

  group('AT+V classification (#62 item 2)', () {
    test('10 s silent: the watchdog sends AT+V; ONLY 0x30 back -> dormant',
        () async {
      final (c, t, _) = await silentLink();
      expect(c.notStreaming, isTrue);
      expect(c.streamClass, StreamClass.unknown);
      c.watchdogTick();
      expect(t.writes, [BatteryCommands.getVersion]);
      expect(c.probeInFlight, isTrue);
      // The bridge answers with its lone status byte — no version frame.
      c.parser.addBytes([0x30]);
      expect(c.state.unrecognisedBytes, 0, reason: '#60: a status byte');
      await probeWindow();
      expect(c.streamClass, StreamClass.dormant);
      expect(c.probeInFlight, isFalse);
      expect(c.gateControlsDisabledReason,
          BatteryConnection.reasonNotStreaming(10000, StreamClass.dormant));
      expect(c.gateControlsDisabledReason,
          contains(BatteryConnection.dormantState));
      expect(c.gateStatusSummary(), contains('stream dormant'));
      expect(AppLog.instance.dump(), contains('AT+V probe: dormant'));
      // Nothing else was sent: the app never forces the pack on by itself.
      expect(t.writes, [BatteryCommands.getVersion]);
    });

    test('0x30 + a version frame, no stream -> awake-not-streaming and '
        'CMD_BEGIN is re-sent', () async {
      final (c, t, _) = await silentLink();
      c.watchdogTick();
      c.parser.addBytes([0x30, ...version]);
      await settle();
      expect(c.state.firmwareVersion, '1.0.1');
      expect(c.streamClass, StreamClass.awakeNotStreaming);
      expect(t.writes, [BatteryCommands.getVersion, BatteryCommands.begin]);
      expect(c.gateControlsDisabledReason,
          contains(BatteryConnection.awakeNotStreamingState));
      expect(c.gateControlsDisabledReason,
          contains('Connected but not streaming'));
    });

    test('telemetry during the probe -> streaming (no CMD_BEGIN)', () async {
      final (c, t, _) = await silentLink();
      c.watchdogTick();
      c.parser.addBytes(bal);
      await settle();
      expect(c.streamClass, StreamClass.streaming);
      expect(c.notStreaming, isFalse);
      expect(t.writes, [BatteryCommands.getVersion]);
      expect(c.gateControlsDisabledReason, isNull);
    });

    test('a LONE 0x30 notification (the whole answer of a dormant pack) is '
        'consumed as the status byte at once; before AT+V it still waits',
        () {
      final s = BatteryState();
      final at = <int>[];
      final p = BatteryParser(state: s, onAtStatusByte: at.add);
      p.addBytes([0x30]);
      expect(at, isEmpty, reason: 'AT+V not sent: could be anything');
      p.reset();
      p.atVersionSent = true;
      p.addBytes([0x30]);
      expect(at, [0x30]);
      expect(s.unrecognisedBytes, 0);
      // And a frame right after still decodes cleanly.
      p.addBytes(bal);
      expect(s.chargeMos, isTrue);
    });

    test('a version frame or an ack does NOT count as streaming — silence '
        'is measured from the last telemetry frame', () async {
      final (c, _, _) = await silentLink();
      c.parser.addBytes([0x30, ...version]);
      expect(c.frameCount, 1);
      expect(c.lastTelemetryMs, isNull);
      expect(c.notStreaming, isTrue);
      expect(c.streamClass, StreamClass.unknown);
      c.parser.addBytes(sleepAck(on: false));
      expect(c.notStreaming, isTrue);
      c.parser.addBytes(bal);
      expect(c.notStreaming, isFalse);
      expect(c.streamClass, StreamClass.streaming);
    });

    test('nothing at all within the window -> no response', () async {
      final (c, _, _) = await silentLink();
      final r = await c.probeStreaming();
      expect(r, StreamClass.noResponse);
      expect(c.gateControlsDisabledReason,
          contains(BatteryConnection.noResponseState));
    });

    test('a streaming link is never probed; a silent one at most every 30 s',
        () async {
      final (c, t, clock) = await silentLink(silentS: 9);
      c.watchdogTick();
      expect(t.writes, isEmpty, reason: 'only 9 s silent');
      clock.advance(const Duration(seconds: 1));
      c.watchdogTick();
      expect(t.writes.length, 1);
      c.parser.addBytes([0x30]);
      await probeWindow();
      expect(c.streamClass, StreamClass.dormant);
      c.watchdogTick();
      expect(t.writes.length, 1, reason: 'probed 0 s ago — not again');
      clock.advance(const Duration(seconds: 30));
      c.watchdogTick();
      expect(t.writes.length, 2, reason: 're-probed after 30 s');
      c.parser.addBytes([0x30]);
      await probeWindow();
      // A frame later flips it straight back to streaming.
      c.parser.addBytes(bal);
      expect(c.streamClass, StreamClass.streaming);
    });

    test('a probe already running is not duplicated', () async {
      final (c, t, _) = await silentLink();
      final a = c.probeStreaming();
      final b = c.probeStreaming();
      expect(identical(await a, await b), isTrue);
      expect(t.writes.length, 1);
    });

    test('reconnect resets the verdict and the frame counter', () async {
      final (c, t, _) = await silentLink();
      c.parser.addBytes(bal);
      expect(c.frameCount, 1);
      await c.probeStreaming();
      final pending = c.connectTo('dev-aa', name: 'JS-2C14AA');
      await Future<void>.delayed(Duration.zero);
      await pending;
      expect(c.streamClass, StreamClass.unknown);
      expect(c.frameCount, 0);
      expect(c.totalFrameCount, greaterThanOrEqualTo(1));
      expect(t.lastLink, isNotNull);
    });
  });

  group('recovery ladder (#62 item 3) — user-initiated, reports the result',
      () {
    test('(i) re-send wake sends CMD_BEGIN; true iff telemetry follows',
        () async {
      final (c, t, _) = await silentLink();
      final f = c.resendWake(timeout: const Duration(milliseconds: 60));
      await settle();
      expect(t.writes, [BatteryCommands.begin]);
      c.parser.addBytes(bal);
      expect(await f, isTrue);
      // No frames: false after the timeout.
      final g = c.resendWake(timeout: const Duration(milliseconds: 30));
      expect(await g, isFalse);
    });

    test('(ii) turn switches on sends the vendor both-MOS-on frame from the '
        'safe base (no fresh status needed)', () async {
      final (c, t, _) = await silentLink();
      expect(c.gateControlsDisabledReason, isNotNull, reason: 'silent link');
      expect(c.safeWritesDisabledReason, isNull);
      final f = c.switchesOnToWake(timeout: const Duration(milliseconds: 60));
      await settle();
      expect(t.gateWrites.single, vendorWake);
      c.parser.addBytes(bal);
      expect(await f, isTrue);
    });

    test('(iii) reconnect drops the link, reconnects at once (backoff '
        'cleared) and reports whether the stream resumed', () async {
      final t = FakeTransport();
      final m = BatteryManager(transport: t);
      final c = m.resolveDiscovered(
          serial: 'JS-2C14AA', deviceId: 'dev-aa', profile: DeviceProfile.sphere);
      await m.connectForTest(c, 'dev-aa', 'JS-2C14AA');
      expect(c.connState, ConnState.connected);
      expect(t.connectCalls, 1);
      final first = t.lastLink!;
      // The resume window must outlast the handshake (~0.6 s of delays).
      final f = m.reconnect(c, timeout: const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(first.disconnected, isTrue);
      expect(t.connectCalls, 2);
      expect(c.connState, ConnState.connected);
      expect(c.disconnectExpected, isFalse, reason: 'cleared by the connect');
      c.parser.addBytes(bal);
      expect(await f, isTrue);
    });

    test('(iii) reconnect refuses a row with no known address', () async {
      final t = FakeTransport();
      final m = BatteryManager(transport: t);
      final c = BatteryConnection(transport: t)..state.serial = 'JS-X';
      expect(() => m.reconnect(c), throwsA(isA<StateError>()));
    });

    test('the ladder descriptors: keys, single confirm, result-aware toast '
        'and the dormant advice', () async {
      final (c, t, _) = await silentLink();
      final a = wakeResendAction(c);
      expect(a.busyKey, WriteKeys.wake);
      expect(a.dangerous, isFalse);
      expect(a.title, 'Re-send wake (CMD_BEGIN)');
      final sending = a.send();
      await settle();
      expect(t.writes, [BatteryCommands.begin]);
      c.parser.addBytes(bal);
      await sending;
      expect(await a.readBack!(), isTrue);
      expect(a.sentToast(), 'Stream resumed on JS-2C14AA');

      final b = wakeSwitchesOnAction(c);
      expect(b.busyKey, WriteKeys.forMos(GateAction.bothMos));
      expect(b.dangerous, isFalse);
      expect(b.message, contains('de-facto wake'));
      expect(b.warnTitle, 'Still not streaming');

      final m = BatteryManager(transport: t);
      final r = wakeReconnectAction(c, m);
      expect(r.busyKey, WriteKeys.reconnect);
      expect(r.dangerous, isFalse);

      // (iv) after every step the dormant verdict says it plainly.
      c.streamClass = StreamClass.dormant;
      expect(notStreamingAdvice(c, tried: 'CMD_BEGIN was sent'),
          contains(BatteryConnection.dormantMessage));
      expect(b.warnMessage!(), contains(BatteryConnection.dormantMessage));
      c.streamClass = StreamClass.awakeNotStreaming;
      expect(a.warnMessage!(), contains('it is awake'));
    });
  });

  group('wording (pinned)', () {
    test('the dormant message and state labels are exactly the incident text',
        () {
      expect(
          BatteryConnection.dormantMessage,
          'BMS is not running — it entered Bluetooth standby with its output '
          'off and cannot be woken over Bluetooth. Isolate this pack from the '
          'bank and connect a charger to it alone, or use its reset button.');
      expect(BatteryConnection.dormantState,
          'BMS dormant (bridge answers, no telemetry)');
      expect(BatteryConnection.awakeNotStreamingState,
          'BMS awake, not streaming');
    });

    test('the parallel-bank warning is exact and appears on every switch-OFF '
        'stern page when the fleet has more than one member', () async {
      expect(
          parallelBankWarning,
          'In a parallel bank the other pack carries all current, so this '
          'pack cannot see charge current to wake if it enters standby.');
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(bal);
      for (final make in [outputAction, chargeAction, bothMosAction]) {
        expect(make(c, target: false, fleetSize: 2).sternWarning,
            contains(parallelBankWarning));
        expect(make(c, target: false, fleetSize: 1).sternWarning,
            isNot(contains(parallelBankWarning)));
        expect(make(c, target: false).sternWarning,
            isNot(contains(parallelBankWarning)));
        expect(make(c, target: true, fleetSize: 2).sternWarning, isNull);
      }
    });

    test('fleet switch-OFF: the bank warning with two members, not with one',
        () async {
      final t = FakeTransport();
      final m = BatteryManager(transport: t);
      final a = m.resolveDiscovered(
          serial: 'JS-A', deviceId: 'dev-a', profile: DeviceProfile.sphere);
      await m.connectForTest(a, 'dev-a', 'JS-A');
      a.parser.addBytes(bal);
      m.setInFleet(a, true);
      expect(fleetOutputAction(m, on: false).sternWarning,
          isNot(contains(parallelBankWarning)));
      final b = m.resolveDiscovered(
          serial: 'JS-B', deviceId: 'dev-b', profile: DeviceProfile.sphere);
      await m.connectForTest(b, 'dev-b', 'JS-B');
      b.parser.addBytes(bal);
      m.setInFleet(b, true);
      expect(fleetOutputAction(m, on: false).sternWarning,
          contains(parallelBankWarning));
      expect(fleetChargeAction(m, on: false).sternWarning,
          contains(parallelBankWarning));
      expect(fleetOutputAction(m, on: true).sternWarning, isNull);
    });

    test('standby ack = the STORED setting only, never "asleep" (#62 item 5)',
        () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      c.parser.addBytes(sleepAck(on: true));
      expect(c.isSleepModeOn, isTrue, reason: 'the stored flag');
      // The pack keeps streaming with the flag ON — it is not "asleep".
      c.parser.addBytes(bal);
      expect(c.notStreaming, isFalse);
      expect(c.streamClass, StreamClass.streaming);
      for (final text in [
        BatteryConnection.reasonNotStreaming(10000),
        BatteryConnection.reasonNotStreaming(10000, StreamClass.dormant),
        BatteryConnection.reasonNotStreaming(10000, StreamClass.noResponse),
        sleepAction(c, target: false).warnMessage!(),
        sleepAction(c, target: true).sternWarning!,
        BatteryConnection.dormantMessage,
      ]) {
        expect(text.toLowerCase(), isNot(contains('asleep')), reason: text);
      }
      expect(sleepAction(c, target: false).warnMessage!(),
          contains('standby setting may still be ON'));
    });
  });
}
