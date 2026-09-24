// #114: shorter value names, and two temperature rows instead of four probes.
//
// The TEMP frame (A1 4F) carries two sensors, each reported twice: byte[0] ==
// byte[3] in every real frame (sensor A) and byte[1] ~= byte[2] within 1 C
// (sensor B). The stored keys are NOT in byte order (temp2 = byte[3], temp3 =
// byte[2]) and never change; the UI shows Temp A = temp2 and Temp B = temp1.
// The chip byte (A2 57 byte[7]) is 0 on every real pack and is never shown.
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/demo_source.dart';
import 'package:battery_reader/metrics.dart';
import 'package:battery_reader/raw_log.dart';
import 'package:battery_reader/sections/pack_section.dart';
import 'package:battery_reader/sections/temperatures_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A real frame from the pull of 2026-09-24 (the one the issue quotes).
const realTemp = [0xA1, 0x4F, 0x21, 0x1F, 0x20, 0x21, 0xB2, 0xE3];

void main() {
  group('TEMP byte -> metric mapping (documented in PROTOCOL.md)', () {
    test('a1 4f 21 1f 20 21: A = bytes 0/3 (33), B = bytes 1/2 (31/32)', () {
      final state = BatteryState();
      BatteryParser(state: state).addBytes(realTemp);
      expect(state.temp0, 33, reason: 'byte[0]');
      expect(state.temp1, 31, reason: 'byte[1]');
      expect(state.temp3, 32, reason: 'byte[2] -> temp3 (not byte order)');
      expect(state.temp2, 33, reason: 'byte[3] -> temp2 (not byte order)');
      expect(state.tempA, 33);
      expect(state.tempB, 31);
    });

    test('the raw-log decode names the sensors and lists bytes in order',
        () async {
      final lines = <String>[];
      RawLogger.instance
        ..enabled = true
        ..onLine = lines.add;
      addTearDown(() => RawLogger.instance.onLine = null);
      final t = FakeTransport();
      final c = BatteryConnection(transport: t);
      await c.connectTo('dev-1', name: 'JS-1');
      t.lastLink!.onData!(realTemp);
      final line = lines.lastWhere((l) => l.contains('Temperatures'));
      expect(line, contains('a1 4f 21 1f 20 21'));
      expect(line, endsWith('A=33C B=31C p0..p3=33/31/32/33'));
      expect(line, isNot(contains('t2=')));
    });
  });

  test('the demo pack pairs its temperatures like a real one', () {
    final frames = <List<int>>[];
    for (final soc in [40, 41]) {
      DemoBattery(frames.add, startSoc: soc, mode: DemoMode.idle)
        ..start(interval: const Duration(hours: 1))
        ..stop();
    }
    final temps = [
      for (final f in frames)
        if (f[0] == 0xA1 && f[1] == 0x4F) f.sublist(2, 6),
    ];
    expect(temps, hasLength(2));
    for (final p in temps) {
      expect(p[0], p[3], reason: 'sensor A sent twice, identical');
      expect((p[1] - p[2]).abs(), lessThanOrEqualTo(1), reason: 'sensor B');
      expect(p[0], isNot(p[1]), reason: 'two different sensors');
    }
    final all = frames.firstWhere((f) => f[0] == 0xA2 && f[1] == 0x57);
    expect(all[2 + 7], 0, reason: 'chip byte unpopulated, like real firmware');
  });

  group('widgets: short labels, two temperature rows, no chip', () {
    BatteryConnection conn() {
      final c = BatteryConnection(transport: FakeTransport());
      c.state
        ..socPercent = 80
        ..packVoltage = 13.3
        ..packCurrent = 2.0
        ..temp0 = 33
        ..temp1 = 31
        ..temp2 = 33
        ..temp3 = 32
        ..chipTemperature = 0;
      return c;
    }

    Widget host(Widget child) =>
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

    testWidgets('Temperature card: Temp A / Temp B only', (tester) async {
      await tester.pumpWidget(host(TemperaturesSection(conn: conn())));
      expect(find.text('Temp A'), findsOneWidget);
      expect(find.text('Temp B'), findsOneWidget);
      expect(find.text('33 °C'), findsOneWidget);
      expect(find.text('31 °C'), findsOneWidget);
      expect(find.textContaining('Probe'), findsNothing);
      expect(find.textContaining('Chip'), findsNothing);
      expect(find.text('0 °C'), findsNothing);
      expect(find.text('32 °C'), findsNothing, reason: 'duplicate not shown');
    });

    testWidgets('Pack card: SOC, Voltage, Current, EFC with its full name',
        (tester) async {
      await tester.pumpWidget(host(PackSection(conn: conn())));
      for (final l in [
        'SOC',
        'Voltage',
        'Current',
        'Load',
        'Charger',
        'Cycles',
        'EFC',
      ]) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      expect(find.text('Pack voltage'), findsNothing);
      expect(find.text('Pack current'), findsNothing);
      expect(find.textContaining('State of charge'), findsNothing);
      expect(find.byTooltip(efcTooltip), findsOneWidget);
    });
  });
}
