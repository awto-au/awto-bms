/// #75: a non-JoySuny pack is connected READ-ONLY through its codec — the
/// codec's service is bound, only the codec's poll frames are written, the
/// replies land in [BatteryState], and every JoySuny command is refused.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/ble_transport.dart';
import 'package:battery_reader/bms_codecs.dart';
import 'package:battery_reader/bms_families.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bms_codec_fixtures.dart';
import 'fakes.dart';

List<int> hx(String s) => [
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];

void main() {
  setUp(() => AppLog.instance.echoToConsole = false);
  tearDown(() => AppLog.instance.echoToConsole = true);

  group('BatteryConnection with a codec', () {
    test('binds the family service and polls with the codec only', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, codec: JbdCodec());
      await c.connectTo('jbd-1', name: 'JBD-SP04S');
      final link = t.lastLink!;
      expect(link.lastTarget!.service, u16('ff00'));
      expect(link.lastTarget!.notify, u16('ff01'));
      expect(link.lastTarget!.write, u16('ff02'));
      // The first cycle runs at once: info, then (after the gap) cells.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(t.writes, [JbdCodec.command(0x03), JbdCodec.command(0x04)]);
      expect(t.writes.any((w) => w[0] != 0xDD), isFalse,
          reason: 'no JoySuny handshake frame reaches a JBD pack');
      await c.dispose();
    });

    test('replies decode into the state and count as streaming', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, codec: JbdCodec());
      await c.connectTo('jbd-1', name: 'JBD-SP04S');
      final link = t.lastLink!;
      final info = hx(jbdInfo);
      for (var i = 0; i < info.length; i += 20) {
        link.onData!(info.sublist(i, i + 20 > info.length ? info.length : i + 20));
      }
      link.onData!(hx(jbdCells));
      final s = c.state;
      expect(s.packVoltage, closeTo(15.6, 1e-9));
      expect(s.packCurrent, closeTo(2.87, 1e-9));
      expect(s.status, ChargeState.discharging);
      expect(s.socPercent, 100);
      expect(s.cellsMv, [3430, 3425, 3432, 3417]);
      expect(s.tempA, 22);
      expect(c.lastTelemetryMs, isNotNull);
      expect(c.cycleComplete, isTrue);
      expect(c.hasFreshGateState, isFalse,
          reason: 'a family row never gets a JoySuny gate base');
      await c.dispose();
    });

    test('every JoySuny write is refused and nothing is sent', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t, codec: JbdCodec());
      await c.connectTo('jbd-1', name: 'JBD-SP04S');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final before = t.writes.length;
      await expectLater(c.setSleepMode(false), throwsStateError);
      await expectLater(c.resendWake(), throwsStateError);
      expect(t.writes.length, before);
      expect(t.gateWrites, isEmpty);
      // The UI disables every control, the "safe" ON writes included.
      expect(c.safeWritesDisabledReason, contains('read-only'));
      expect(c.gateControlsDisabledReason, contains('read-only'));
      await c.dispose();
    });

    test('a JoySuny row still binds FCF0 and runs its handshake', () async {
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('js-1', name: 'JS-1');
      expect(t.lastLink!.lastTarget, same(GattTarget.joySuny));
      expect(t.writes.first, BatteryCommands.begin);
      await c.dispose();
    });
  });

  group('BatteryManager', () {
    BatteryManager newManager(FakeTransport t) => BatteryManager(
        transport: t,
        scanWindow: const Duration(milliseconds: 5),
        rescanInterval: const Duration(hours: 1));

    Future<void> settle(BatteryManager m) async {
      for (var i = 0; i < 200 && m.connectingIds.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('a recognised family with a codec becomes a live read-only row',
        () async {
      final t = FakeTransport();
      final m = newManager(t);
      final start = m.startLive();
      await Future<void>.delayed(Duration.zero);
      t.emitScan([
        BleScanHit(
            deviceId: 'jk-1',
            name: 'JK-B2A8S20P',
            rssi: -60,
            serviceUuids: [u16('ffe0')]),
      ]);
      await start;
      await settle(m);
      expect(m.detectedOthers, isEmpty);
      final row = m.batteries.single;
      expect(row.codec, isA<JkCodec>());
      expect(row.isReadOnlyFamily, isTrue);
      expect(row.connState, ConnState.connected);
      expect(t.lastLink!.lastTarget!.service, u16('ffe0'));
      m.stopLive();
      m.disposeAll();
    });

    test('a SmartBat without a usable serial stays detect-only', () async {
      final t = FakeTransport();
      final m = newManager(t);
      final start = m.startLive();
      await Future<void>.delayed(Duration.zero);
      t.emitScan([
        const BleScanHit(
            deviceId: 'ogt-1', name: 'Offgridtec-SmartBat', rssi: -60),
      ]);
      await start;
      expect(m.batteries, isEmpty);
      expect(m.detectedOthers.single.family.name, 'LiFePO4POWER / Offgridtec');
      expect(t.connectCalls, 0);
      m.stopLive();
      m.disposeAll();
    });
  });
}
