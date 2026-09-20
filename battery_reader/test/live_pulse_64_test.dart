/// GitHub #64: the live dot flashes ONCE per decoded telemetry cycle —
/// event-driven from the connection's events, never a free-running animation.
/// [PulseTrigger] is the pure decision (BAL_STATUS = the cycle marker; one per
/// captured sample while background sampling); the widget test injects real
/// frames through a connected [BatteryConnection] and watches the dot animate
/// on the marker and sit idle otherwise.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/live_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const bal = [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21];
const soc = [0xA9, 0x64, 50, 0x10, 0x27, 0x00, 0x88, 0x13, 0x00, 0xBA, 0x5E];
const version = [0xAC, 0x9A, 0x31, 0x2E, 0x30, 0x2E, 0x31, 0xBD, 0x10];

void main() {
  group('PulseTrigger — the pure decision', () {
    test('one telemetry cycle (its BAL_STATUS marker) -> exactly one pulse',
        () {
      final t = PulseTrigger();
      // A cycle's frames in the order the pack streams them: only the marker
      // fires, once, however many other frames the cycle carries.
      final cycle = <BatteryEvent>[
        const VoltageEvent(),
        const TempEvent(),
        const AllDataEvent(),
        const MosEvent(),
        const BalancerEvent(),
        const SocEvent(),
        const EstTimeEvent(),
      ];
      expect(cycle.map(t.onEvent).toList(),
          [false, false, false, false, true, false, false]);
      // The next cycle pulses again: 1:1 with real cycles.
      expect(cycle.where(t.onEvent).length, 1);
    });

    test('frames that are not the cycle marker -> no pulse', () {
      final t = PulseTrigger();
      for (final e in const <BatteryEvent>[
        VoltageEvent(),
        TempEvent(),
        AllDataEvent(),
        MosEvent(),
        SocEvent(),
        EstTimeEvent(),
        VersionEvent(),
      ]) {
        expect(t.onEvent(e), isFalse, reason: e.label);
      }
      expect(t.onEvent(const BalancerEvent()), isTrue);
    });

    test('stop -> no pulse: nothing fires without a marker event', () {
      // The trigger has no clock and no timer: with no marker decoded there
      // is nothing to pulse, whatever the link state does.
      final t = PulseTrigger();
      t.onConnState(ConnState.connected);
      t.onConnState(ConnState.disconnected);
      expect(t.onEvent(const SocEvent()), isFalse);
    });

    test('background sampling -> one pulse per captured sample, even when '
        'the captured cycle straddles two BAL_STATUS frames', () {
      final t = PulseTrigger();
      // Sample 1: link up, marker seen twice (cycle started mid-way).
      t.onConnState(ConnState.connecting);
      t.onConnState(ConnState.connected);
      expect(t.onEvent(const BalancerEvent(), sampling: true), isTrue);
      expect(t.onEvent(const SocEvent(), sampling: true), isFalse);
      expect(t.onEvent(const BalancerEvent(), sampling: true), isFalse,
          reason: 'second marker in the same sample must not pulse');
      // Released; sample 2 pulses again.
      t.onConnState(ConnState.disconnected);
      t.onConnState(ConnState.connected);
      expect(t.onEvent(const BalancerEvent(), sampling: true), isTrue);
      expect(t.onEvent(const BalancerEvent(), sampling: true), isFalse);
      // Foreground returns while the link is still up: continuous again,
      // every cycle pulses.
      expect(t.onEvent(const BalancerEvent()), isTrue);
      expect(t.onEvent(const BalancerEvent()), isTrue);
    });
  });

  group('LiveIndicator widget — the dot animates on the event only', () {
    final clock = DateTime.utc(2026, 9, 21, 12);

    // The connection's connect / disconnect await real timers, so they run
    // under [WidgetTester.runAsync]; frames are fed to the parser from the
    // test body (fake-async zone) and reach the dot on the next pump.
    Future<BatteryConnection> connected(WidgetTester tester, String id) async {
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await tester.runAsync(() => c.connectTo(id, name: id));
      expect(c.connState, ConnState.connected);
      return c;
    }

    Future<void> pumpIndicator(WidgetTester tester, BatteryConnection c,
            {bool sampling = false}) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: LiveIndicator(conn: c, sampling: () => sampling),
          ),
        ));

    LiveDot dot(WidgetTester tester) =>
        tester.widget<LiveDot>(find.byType(LiveDot));

    testWidgets('idle at rest; one ~200 ms ease-out per BAL_STATUS; other '
        'frames leave it still; stop -> still', (tester) async {
      final c = await connected(tester, 'dev-1');
      await pumpIndicator(tester, c);
      expect(pulseDuration.inMilliseconds, inInclusiveRange(150, 250));
      expect(dot(tester).pulse.value, 1.0, reason: 'at rest = solid dot');
      expect(dot(tester).pulse.isAnimating, isFalse);

      // A non-marker telemetry frame: live (green) but no flash.
      c.parser.addBytes(soc);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isFalse);
      expect(dot(tester).pulse.value, 1.0);

      // The cycle marker: the flash starts the instant it is decoded …
      c.parser.addBytes(bal);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isTrue);
      expect(dot(tester).pulse.value, 0.0);
      await tester.pump(); // the ticker's first frame stamps its start
      await tester.pump(const Duration(milliseconds: 100));
      expect(dot(tester).pulse.value, inExclusiveRange(0.0, 1.0));
      // … and is over well within a cycle; nothing repeats.
      await tester.pump(pulseDuration + const Duration(milliseconds: 1));
      expect(dot(tester).pulse.value, 1.0);
      expect(dot(tester).pulse.isAnimating, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(dot(tester).pulse.isAnimating, isFalse,
          reason: 'telemetry stopped: no free-running pulse');

      // A version frame (an answer, not the stream) never flashes.
      c.parser.addBytes(version);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isFalse);

      // Every cycle flashes: a second marker restarts the ease-out.
      c.parser.addBytes(bal);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isTrue);

      // Tear down with the subscriptions live: no leak, no late setState.
      await tester.pumpWidget(const SizedBox());
      c.parser.addBytes(bal);
      await tester.pump();
      await tester.runAsync(c.dispose);
    });

    testWidgets('background sampling: one flash per captured sample',
        (tester) async {
      final c = await connected(tester, 'dev-1');
      await pumpIndicator(tester, c, sampling: true);
      c.parser.addBytes(bal);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isTrue);
      await tester.pump(); // the ticker's first frame stamps its start
      await tester.pump(pulseDuration + const Duration(milliseconds: 1));
      expect(dot(tester).pulse.isAnimating, isFalse);
      // A second marker inside the same sample: still.
      c.parser.addBytes(bal);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isFalse);
      // The sample ends (link released) and the next one connects: one more.
      await tester.runAsync(c.disconnect);
      await tester.pump();
      await tester.runAsync(() => c.connectTo('dev-1', name: 'dev-1'));
      await tester.pump();
      c.parser.addBytes(bal);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.dispose);
    });

    testWidgets('a swapped connection (demo / live toggle) re-subscribes',
        (tester) async {
      final c1 = await connected(tester, 'dev-1');
      await pumpIndicator(tester, c1);
      final c2 = await connected(tester, 'dev-2');
      await pumpIndicator(tester, c2);
      // The old connection's frames no longer reach the dot …
      c1.parser.addBytes(bal);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isFalse);
      // … the new one's do.
      c2.parser.addBytes(bal);
      await tester.pump();
      expect(dot(tester).pulse.isAnimating, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c1.dispose);
      await tester.runAsync(c2.dispose);
    });
  });
}
