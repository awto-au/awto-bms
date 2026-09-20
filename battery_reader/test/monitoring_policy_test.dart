import 'package:flutter_test/flutter_test.dart';

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/ble_transport.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/monitoring_policy.dart';
import 'package:battery_reader/settings_store.dart';

import 'fakes.dart';

/// Issue #52: background monitoring must be stoppable. The foreground service
/// runs only while `monitoredCount > 0 && backgroundMonitoring && !userStopped`;
/// an explicit user stop wins over the 300 ms tick; the toggle OFF stops it and
/// prevents any start; only a fresh launch (new policy), Resume, or the toggle
/// ON clears a user stop. Pausing releases every battery (an EXPECTED
/// disconnect, no alarm) and stops the scan / reconnect loop; resuming scans
/// and reconnects again.
void main() {
  group('MonitoringPolicy: service should-run (#52)', () {
    test('runs only with monitored > 0, toggle ON and no user stop', () {
      final p = MonitoringPolicy();
      expect(p.backgroundMonitoring, isTrue, reason: 'default ON');
      expect(p.userStopped, isFalse, reason: 'a fresh launch is not stopped');
      expect(p.serviceShouldRun(0), isFalse);
      expect(p.serviceShouldRun(1), isTrue);
      expect(p.serviceShouldRun(3), isTrue);
    });

    test('a user stop wins over the tick: it never comes back on its own', () {
      final p = MonitoringPolicy();
      p.stopByUser();
      // The 300 ms tick keeps asking with batteries present; the answer stays
      // NO for every tick.
      for (var i = 0; i < 50; i++) {
        expect(p.serviceShouldRun(2), isFalse);
      }
      expect(p.userStopped, isTrue);
    });

    test('toggle OFF stops and prevents any start', () {
      final p = MonitoringPolicy();
      p.setBackgroundMonitoring(false);
      expect(p.serviceShouldRun(2), isFalse);
      // Even a fresh instance with the persisted toggle OFF never starts it.
      expect(MonitoringPolicy(backgroundMonitoring: false).serviceShouldRun(2),
          isFalse);
    });

    test('toggle ON clears a user stop; toggle OFF does not', () {
      final p = MonitoringPolicy();
      p.stopByUser();
      p.setBackgroundMonitoring(false);
      expect(p.userStopped, isTrue);
      expect(p.serviceShouldRun(1), isFalse);
      p.setBackgroundMonitoring(true);
      expect(p.userStopped, isFalse);
      expect(p.serviceShouldRun(1), isTrue);
    });

    test('resume clears a user stop', () {
      final p = MonitoringPolicy()..stopByUser();
      expect(p.serviceShouldRun(1), isFalse);
      p.resume();
      expect(p.serviceShouldRun(1), isTrue);
    });

    test('a fresh launch (new policy) starts un-stopped', () {
      final old = MonitoringPolicy()..stopByUser();
      expect(old.serviceShouldRun(1), isFalse);
      // The app constructs a new policy per launch; the stop is not persisted.
      final fresh =
          MonitoringPolicy(backgroundMonitoring: old.backgroundMonitoring);
      expect(fresh.userStopped, isFalse);
      expect(fresh.serviceShouldRun(1), isTrue);
    });
  });

  group('MonitoringPolicy: BLE should-run (#52)', () {
    test('toggle ON: BLE runs in the foreground AND background', () {
      final p = MonitoringPolicy();
      expect(p.bleShouldRun, isTrue);
      p.setForeground(false);
      expect(p.bleShouldRun, isTrue);
    });

    test(
        'toggle OFF: BLE runs ONLY in the foreground (swipe/background '
        'releases the packs)', () {
      final p = MonitoringPolicy(backgroundMonitoring: false);
      expect(p.bleShouldRun, isTrue);
      p.setForeground(false);
      expect(p.bleShouldRun, isFalse, reason: 'backgrounded -> released');
      p.setForeground(true);
      expect(p.bleShouldRun, isTrue, reason: 'back in front -> reconnect');
    });

    test('a user stop / pause releases BLE regardless of foreground', () {
      final p = MonitoringPolicy()..stopByUser();
      expect(p.bleShouldRun, isFalse);
      p.setForeground(true);
      expect(p.bleShouldRun, isFalse,
          reason: 'coming to the front does not resume; only Resume / '
              'toggle ON / relaunch do');
      p.resume();
      expect(p.bleShouldRun, isTrue);
    });
  });

  group('Exit (#54)', () {
    test('exit sets the user-stopped state and forbids service + BLE', () {
      final p = MonitoringPolicy();
      p.exitApp();
      expect(p.userStopped, isTrue);
      expect(p.exiting, isTrue);
      expect(p.serviceShouldRun(3), isFalse, reason: 'tick cannot restart');
      expect(p.bleShouldRun, isFalse, reason: 'batteries released');
      // Unlike Pause, nothing brings it back while exiting.
      p.setBackgroundMonitoring(true);
      p.resume();
      p.setForeground(true);
      expect(p.serviceShouldRun(3), isFalse);
      expect(p.bleShouldRun, isFalse);
    });

    test('the exit sequence runs stop service -> release BLE -> cancel '
        'notifications -> flush logs -> terminate, in that order', () async {
      final order = <String>[];
      await runExitSequence(
        stopService: () async => order.add('service'),
        releaseBle: () async => order.add('ble'),
        cancelNotifications: () async => order.add('notifications'),
        flushLogs: () async => order.add('flush'),
        terminate: () => order.add('terminate'),
      );
      expect(order, ['service', 'ble', 'notifications', 'flush', 'terminate']);
    });

    test('a failing step is recorded and skipped; the flush still happens '
        'and the app still terminates', () async {
      final order = <String>[];
      final errors = <String>[];
      await runExitSequence(
        stopService: () async => throw StateError('no service'),
        releaseBle: () async => order.add('ble'),
        cancelNotifications: () async => throw StateError('no plugin'),
        flushLogs: () async => order.add('flush'),
        terminate: () => order.add('terminate'),
        onError: (step, e) => errors.add(step),
      );
      expect(order, ['ble', 'flush', 'terminate']);
      expect(errors, ['stop service', 'cancel notifications']);
    });

    test('exit releases the packs and stops the scan loop (manager)',
        () async {
      final t = FakeTransport();
      final m = BatteryManager(
          transport: t,
          scanWindow: const Duration(milliseconds: 5),
          rescanInterval: const Duration(hours: 1));
      AppLog.instance.echoToConsole = false;
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';
      await c.connectTo('dev-1', name: 'JS-A');
      await m.startLive();
      m.batteries.add(c);
      var terminated = false;
      await runExitSequence(
        stopService: () async {},
        releaseBle: () async {
          await m.pauseLive();
          m.disposeAll();
        },
        cancelNotifications: () async {},
        flushLogs: () async {},
        terminate: () => terminated = true,
      );
      expect(terminated, isTrue);
      expect(m.isLive, isFalse, reason: 'scan / reconnect loop stopped');
      expect(t.lastLink!.disconnected, isTrue, reason: 'pack released');
      expect(m.batteries, isEmpty);
      AppLog.instance.echoToConsole = true;
    });
  });

  group('SettingsStore: background monitoring (#52)', () {
    test('persisted under its own key, default ON, in the table', () {
      expect(
          SettingsStore.backgroundMonitoring.key, 'background_monitoring_v1');
      expect(SettingsStore.backgroundMonitoring.defaultValue, isTrue);
      expect(SettingsStore.all, contains(SettingsStore.backgroundMonitoring));
    });
  });

  group('BatteryManager.pauseLive / resumeLive (#52)', () {
    const hit = BleScanHit(
        deviceId: 'dev-1', name: 'JS-A', rssi: -60, serviceUuids: []);

    BatteryManager newManager(FakeTransport t) => BatteryManager(
        transport: t,
        scanWindow: const Duration(milliseconds: 5),
        rescanInterval: const Duration(hours: 1));

    // The fake handshake takes ~0.6 s; wait for the manager's connect (and
    // its dedupe entry) to finish before going on.
    Future<void> settle(BatteryManager m) async {
      for (var i = 0; i < 200 && m.connectingIds.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(m.connectingIds, isEmpty, reason: 'connect finished');
    }

    setUp(() => AppLog.instance.echoToConsole = false);
    tearDown(() => AppLog.instance.echoToConsole = true);

    test(
        'pause disconnects every pack (expected: no alarm), keeps the rows '
        'and stops scanning; resume scans and reconnects', () async {
      final t = FakeTransport();
      final m = newManager(t);
      final start = m.startLive();
      await Future<void>.delayed(Duration.zero);
      t.emitScan([hit]);
      await start;
      await settle(m);
      expect(m.batteries.length, 1);
      final c = m.batteries.single;
      expect(c.connState, ConnState.connected);
      expect(m.isLive, isTrue);
      final link = t.lastLink!;

      await m.pauseLive();
      expect(m.isLive, isFalse, reason: 'rescan / reconnect loop stopped');
      expect(m.isPaused, isTrue);
      expect(link.disconnected, isTrue, reason: 'the pack is RELEASED');
      expect(c.connState, ConnState.disconnected);
      expect(c.disconnectExpected, isTrue, reason: 'no disconnect alarm');
      expect(c.alarmActive, isFalse);
      expect(m.batteries.single, same(c), reason: 'row kept (offline)');
      final connectsBefore = t.connectCalls;

      final resume = m.resumeLive();
      await Future<void>.delayed(Duration.zero);
      t.emitScan([hit]); // advertising again during the resumed scan window
      await resume;
      await settle(m);
      expect(m.isLive, isTrue);
      expect(m.isPaused, isFalse);
      expect(t.connectCalls, connectsBefore + 1, reason: 'reconnected');
      expect(c.connState, ConnState.connected);
      expect(m.batteries.single, same(c), reason: 'same row, no duplicate');
      m.stopLive();
      m.disposeAll();
    });

    test('a connect in flight when the pause lands lets go on completion',
        () async {
      final t = FakeTransport();
      final m = newManager(t);
      await m.startLive();
      final c = BatteryConnection(transport: t)..state.serial = 'JS-A';
      m.batteries.add(c);
      await m.pauseLive(); // released
      // The manager's connect path completes AFTER the pause -> drops the link.
      await m.connectForTest(c, 'dev-1', 'JS-A');
      expect(t.lastLink!.disconnected, isTrue);
      expect(c.connState, ConnState.disconnected);
      m.disposeAll();
    });

    test('resumeLive on a manager that never went live is a full startLive',
        () async {
      final t = FakeTransport();
      final m = newManager(t);
      m.startDemoFleet();
      expect(m.batteries.length, 4);
      await m.resumeLive();
      expect(m.isLive, isTrue);
      expect(m.batteries, isEmpty, reason: 'demo rows disposed');
      m.stopLive();
      m.disposeAll();
    });

    test('resumeLive while live is a no-op', () async {
      final t = FakeTransport();
      final m = newManager(t);
      await m.startLive();
      await m.resumeLive();
      expect(m.isLive, isTrue);
      m.stopLive();
      m.disposeAll();
    });
  });
}
