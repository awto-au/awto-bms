import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/ble_transport.dart';

import 'fakes.dart';

/// Reconnection robustness (issue #49). A dropped battery must always become
/// eligible for reconnect and the manager must keep retrying cleanly at weak
/// signal — never getting stuck in the [_connecting] dedupe set, and never
/// hammering the adapter (exponential backoff).
///
/// These are hermetic: a fake [BleTransport]/[BleLink] stands in for the real
/// BLE stack so failure modes (connect refused, service-discovery 'Unreachable')
/// are simulated deterministically, with an injected clock for the backoff.
void main() {
  group('connectTo treats a failed connect as a recoverable drop (#49)', () {
    test('connect refused → row is DISCONNECTED (not stuck connecting)',
        () async {
      final t = FakeTransport()..failConnect = true;
      final c = BatteryConnection(transport: t);
      await expectLater(
          c.connectTo('dev-1', name: 'JS-A'), throwsA(isA<Object>()));
      expect(c.connState, ConnState.disconnected,
          reason: 'eligible for the rescan to retry');
    });

    test('service-discovery failure → row is DISCONNECTED', () async {
      final t = FakeTransport()..failDiscover = true;
      final c = BatteryConnection(transport: t);
      await expectLater(
          c.connectTo('dev-1', name: 'JS-A'), throwsA(isA<Object>()));
      expect(c.connState, ConnState.disconnected);
    });

    test('a link drop after connect marks the row disconnected', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-A');
      expect(c.connState, ConnState.connected);
      // The transport signals a drop on the state stream.
      t.lastLink!.dropLink();
      await Future<void>.delayed(Duration.zero);
      expect(c.connState, ConnState.disconnected);
    });
  });

  group('manager reconnect dedupe + backoff (#49)', () {
    test('_connecting is ALWAYS cleared after a failed connect', () async {
      final t = FakeTransport()..failConnect = true;
      final m = BatteryManager();
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';
      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(m.connectingIds, isEmpty,
          reason: 'never left stuck / un-retryable in the dedupe set');
      expect(c.connState, ConnState.disconnected);
    });

    test('an in-flight connect is deduped (no parallel attempt)', () async {
      final gate = Completer<void>();
      // failDiscover so the (gated) connect returns a link, then discovery fails
      // — exercising the failure path without the handshake delays.
      final t = FakeTransport()
        ..failDiscover = true
        ..connectGate = gate;
      final m = BatteryManager();
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';

      final f1 = m.connectForTest(c, 'dev-1', 'JS-A'); // blocks on the gate
      await Future<void>.delayed(Duration.zero);
      expect(m.connectingIds, contains('dev-1'));

      await m.connectForTest(c, 'dev-1', 'JS-A'); // deduped, returns at once
      expect(t.connectCalls, 1, reason: 'deduped while the first is in flight');

      gate.complete();
      await f1;
      expect(m.connectingIds, isEmpty);
    });

    test('a failed connect arms a backoff that rate-limits the next attempt',
        () async {
      var clock = DateTime.utc(2024, 1, 1, 12);
      final t = FakeTransport()..failConnect = true;
      final m = BatteryManager(now: () => clock);
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';

      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(t.connectCalls, 1);
      expect(m.nextAttemptMsFor('dev-1'), isNotNull);

      // Immediate retry is suppressed while inside the backoff window.
      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(t.connectCalls, 1, reason: 'within backoff — no new attempt');

      // Once the window elapses, it retries again (keeps trying at weak signal).
      clock = clock.add(const Duration(seconds: 5));
      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(t.connectCalls, 2, reason: 'retries after the backoff elapsed');
    });

    test('backoff grows across repeated failures (no hammering)', () async {
      var clock = DateTime.utc(2024, 1, 1, 12);
      final t = FakeTransport()..failConnect = true;
      final m = BatteryManager(now: () => clock);
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';

      await m.connectForTest(c, 'dev-1', 'JS-A');
      final first = m.nextAttemptMsFor('dev-1')! - clock.millisecondsSinceEpoch;

      clock = clock.add(Duration(milliseconds: first));
      await m.connectForTest(c, 'dev-1', 'JS-A');
      final second = m.nextAttemptMsFor('dev-1')! - clock.millisecondsSinceEpoch;

      expect(second, greaterThan(first),
          reason: 'geometric growth so retries space out');
    });

    test('a successful connect clears the backoff', () async {
      var clock = DateTime.utc(2024, 1, 1, 12);
      final t = FakeTransport()..failConnect = true;
      final m = BatteryManager(now: () => clock);
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';

      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(m.nextAttemptMsFor('dev-1'), isNotNull);

      // Signal recovers: the next attempt (after the window) connects.
      clock = clock.add(const Duration(seconds: 5));
      t.failConnect = false;
      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(c.connState, ConnState.connected);
      expect(m.nextAttemptMsFor('dev-1'), isNull,
          reason: 'backoff reset so a later drop retries immediately');
    });
  });
}
