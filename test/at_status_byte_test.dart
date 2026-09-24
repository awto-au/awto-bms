/// GitHub #60: the stray `0x30` after `AT+V` is the ASCII '0' status byte of
/// the firmware's AT bridge (live A/B test, #23) — not unrecognised data. Once
/// AT+V has been sent on a link, a dropped 0x30 is classified as that status
/// byte: reported through [BatteryParser.onAtStatusByte], NOT counted in
/// [BatteryState.unrecognisedBytes] and NOT reported as unrecognised. Any
/// other stray byte, and a 0x30 before AT+V was sent, are unchanged.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  // BAL_STATUS (A8 AC) with chgMos = disMos = 1.
  const bal = [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21];

  test('[AT+V sent] 0x30 + a valid frame: status logged, nothing counted', () {
    final s = BatteryState();
    final unrec = <int>[];
    final at = <int>[];
    final p = BatteryParser(
        state: s, onUnrecognisedByte: unrec.add, onAtStatusByte: at.add);
    p.atVersionSent = true;
    p.addBytes([0x30, ...bal]);
    expect(s.unrecognisedBytes, 0);
    expect(unrec, isEmpty);
    expect(at, [0x30]);
    expect(s.chargeMos, isTrue, reason: 'the frame after it still decodes');
  });

  test('a stray 0x31 still counts as unrecognised (AT+V sent or not)', () {
    final s = BatteryState();
    final unrec = <int>[];
    final at = <int>[];
    final p = BatteryParser(
        state: s, onUnrecognisedByte: unrec.add, onAtStatusByte: at.add);
    p.atVersionSent = true;
    p.addBytes([0x31, ...bal]);
    expect(s.unrecognisedBytes, 1);
    expect(unrec, [0x31]);
    expect(at, isEmpty);
    expect(s.chargeMos, isTrue);
  });

  test('0x30 BEFORE AT+V was sent on the link is still unrecognised', () {
    final s = BatteryState();
    final unrec = <int>[];
    final at = <int>[];
    final p = BatteryParser(
        state: s, onUnrecognisedByte: unrec.add, onAtStatusByte: at.add);
    p.addBytes([0x30, ...bal]);
    expect(s.unrecognisedBytes, 1);
    expect(unrec, [0x30]);
    expect(at, isEmpty);
  });

  test('reset() (a new link) clears the AT+V flag', () {
    final p = BatteryParser(state: BatteryState());
    p.atVersionSent = true;
    p.reset();
    expect(p.atVersionSent, isFalse);
  });

  test('the connection marks AT+V sent by its handshake, per link', () async {
    final t = FakeTransport();
    final c = BatteryConnection(transport: t);
    expect(c.parser.atVersionSent, isFalse);
    await c.connectTo('dev-1', name: 'JS-A');
    expect(c.parser.atVersionSent, isTrue);
    expect(t.writes, anyElement(equals(BatteryCommands.getVersion)));
    // The status byte of this link's AT+V is not an unrecognised byte.
    c.parser.addBytes([0x30, ...bal]);
    expect(c.state.unrecognisedBytes, 0);
    expect(c.unknownChangedMetrics, isEmpty);
    // Reconnect: the flag resets until the new handshake sends AT+V again.
    final pending = c.connectTo('dev-1', name: 'JS-A');
    await Future<void>.delayed(Duration.zero);
    await pending;
    expect(c.parser.atVersionSent, isTrue);
  });
}
