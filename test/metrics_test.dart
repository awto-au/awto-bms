import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_log.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/health_palette.dart';
import 'package:battery_reader/metrics.dart';

import 'fakes.dart';

/// Review pass C2: the ONE metric catalogue. These pin down that the table
/// drives the same five sites the hand-written lists used to — the logger's
/// row set, the charts' loaded metrics and per-card series, the sparkline
/// rows, and the detail-page sections — with the SAME keys, labels, colours
/// and order as before.
void main() {
  /// A connection carrying a value for every logged metric.
  BatteryConnection full() {
    final c = BatteryConnection(transport: FakeTransport());
    c.state
      ..serial = 'JS-T'
      ..cellsMv = [3300, 3310, 3320, 3330]
      ..packVoltage = 13.26
      ..cellSum = 13.26
      ..cellMax = 3.33
      ..cellMin = 3.30
      ..cellAvg = 3.31
      ..cellDiff = 0.03
      ..packCurrent = 12.5
      ..power = 165
      ..chargeState = ChargeState.discharging
      ..socPercent = 77
      ..remainingAh = 77
      ..fullAh = 100
      ..timeToFullSec = 0
      ..timeToEmptySec = 22000
      ..cycleCount = 7
      ..temp0 = 21
      ..temp1 = 22
      ..temp2 = 23
      ..temp3 = 24
      ..chipTemperature = 0
      ..rssi = -60
      ..tempControlGate = 1
      ..smokeGate = 0
      ..heatGate = 0
      ..firmwareVersion = '1.0.1'
      ..temperatureAlarmSeen = true
      ..overTempLatched = false;
    c.cumulativeThroughputAh = 50; // efc = 0.5
    return c;
  }

  group('table invariants', () {
    test('keys are unique and every logged key is a real Metric constant', () {
      final keys = metricTable.map((m) => m.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'no duplicate rows');
      expect(loggedMetrics.map((m) => m.key).toSet(), {
        Metric.soc, Metric.packVoltage, Metric.packCurrent, Metric.power,
        Metric.cycleCount, Metric.efc, Metric.remainingAh, Metric.fullAh,
        Metric.timeToFullSec, Metric.timeToEmptySec, Metric.cellSum,
        Metric.cellAvg, Metric.cellMax, Metric.cellMin, Metric.cellDelta,
        Metric.temp1, Metric.temp2, Metric.temp0, Metric.temp3, Metric.chipTemp,
        Metric.tempControlGate, Metric.smokeGate, Metric.heatGate,
        Metric.overTempLatched, Metric.firmwareVersion, Metric.rssi,
      });
    });

    test('the metric KEYS are byte-identical to the Python store', () {
      expect(Metric.packVoltage, 'packV');
      expect(Metric.packCurrent, 'packI');
      expect(Metric.remainingAh, 'remAh');
      expect(Metric.cycleCount, 'cycles');
      expect(Metric.chipTemp, 'chip');
      expect(Metric.tempControlGate, 'tempGate');
      expect(Metric.firmwareVersion, 'firmware');
      expect(Metric.flags, 'flags');
      expect(Metric.cells, ['cell1', 'cell2', 'cell3', 'cell4']);
    });

    test('display-only rows are never logged and are named after flags_bits',
        () {
      for (final k in [
        Metric.displayChargeState, Metric.displayLoad, Metric.displayCharger,
        Metric.displayMos, Metric.displayChgMos, Metric.displayDisMos,
        Metric.displayPassiveBal, Metric.displayUnrecognised,
      ]) {
        expect(metricDef(k)!.logged, isFalse, reason: k);
      }
      expect(Metric.displayChgMos, 'chgMos');
      expect(metricDef('cell1'), isNull, reason: 'cells are dynamic');
      expect(metricDef(Metric.flags), isNull, reason: 'flags stays special');
    });
  });

  group('site 1: the logger writes exactly the catalogued rows', () {
    test('every logged row lands (plus cells, unknown bytes and flags)',
        () {
      final log = BatteryLogger.custom();
      final c = full();
      log.observeConnection(c, nowMs: 1000);
      for (final m in loggedMetrics) {
        final segs = log.hourSegments('JS-T', m.key);
        expect(segs, isNotEmpty, reason: '${m.key} not logged');
        final v = m.extract?.call(c);
        if (v != null) expect(segs.single.valueNum, closeTo(v.toDouble(), 1e-9));
        if (m.extractText != null) {
          expect(segs.single.valueText, m.extractText!(c));
        }
      }
      expect(log.hourSegments('JS-T', 'cell4').single.valueNum, 3.33);
      expect(log.hourSegments('JS-T', Metric.packCurrent).single.valueNum,
          -12.5, reason: 'SIGNED: discharging is negative');
      expect(log.hourSegments('JS-T', Metric.efc).single.valueNum, 0.5);
      expect(log.hourSegments('JS-T', Metric.firmwareVersion).single.valueText,
          '1.0.1');
      expect(log.hourSegments('JS-T', Metric.overTempLatched).single.valueNum, 0);
    });

    test('a null extractor logs nothing this event (over-temp before any '
        'temperature-alarm frame; a missing value)', () {
      final log = BatteryLogger.custom();
      final c = full();
      c.state
        ..temperatureAlarmSeen = false
        ..rssi = null;
      log.observeConnection(c, nowMs: 1000);
      expect(log.hourSegments('JS-T', Metric.overTempLatched), isEmpty);
      expect(log.hourSegments('JS-T', Metric.rssi), isEmpty);
      expect(log.hourSegments('JS-T', Metric.soc), isNotEmpty);
    });
  });

  group('site 2: charts', () {
    test('chartMetrics = cells (or the familiar four) + charted rows + flags',
        () {
      expect(chartMetrics(const []), [
        ...Metric.cells,
        Metric.soc, Metric.packVoltage, Metric.packCurrent,
        Metric.temp2, Metric.temp1, // #114: Temp A, Temp B only
        Metric.flags,
        Metric.sampleIntervalS, // #53
      ]);
      expect(chartMetrics(['cell1', 'cell2']).take(2), ['cell1', 'cell2']);
    });

    test('per-card series, legend labels and colours are the originals', () {
      expect(chartSeries(ChartGroup.cells), isEmpty, reason: 'dynamic');
      expect(chartSeries(ChartGroup.packVoltage).single.labelOnChart,
          'Voltage');
      expect(chartSeries(ChartGroup.packVoltage).single.color,
          const Color(0xFF4C9AFF));
      final cur = chartSeries(ChartGroup.current).single;
      expect(cur.labelOnChart, 'Current');
      expect(cur.color, HealthPalette.healthy);
      expect(cur.centreZero, isTrue);
      final temps = chartSeries(ChartGroup.temperature);
      // #114: two sensors; each keeps the colour its series had before.
      expect(temps.map((m) => m.labelOnChart), ['Temp A', 'Temp B']);
      expect(temps.map((m) => m.key), [Metric.temp2, Metric.temp1]);
      expect(temps.map((m) => m.color),
          const [Color(0xFFEB5757), Color(0xFFF2994A)]);
      final soc = chartSeries(ChartGroup.soc).single;
      expect(soc.labelOnChart, 'SOC');
      expect(soc.color, HealthPalette.healthy);
    });
  });

  group('site 3: sparkline rows', () {
    test('the seven rows in order, labels, colours and signedness (#114)',
        () {
      final c = full();
      expect(sparkMetricKeys, [
        Metric.packCurrent, Metric.packVoltage, Metric.power, Metric.soc,
        Metric.remainingAh, Metric.temp2, Metric.temp1,
      ]);
      expect(sparkMetrics.map((m) => m.label), [
        'Current', 'Voltage', 'Power', 'SOC', 'Remaining', 'Temp A', 'Temp B',
      ]);
      expect(sparkMetrics.map((m) => m.centreZero),
          [true, false, true, false, false, false, false]);
      final socColor = HealthPalette.colorForSoc(77);
      expect(sparkMetrics.map((m) => m.sparkColorFor(c)), [
        HealthPalette.telemetryAccent, HealthPalette.telemetryAccent,
        HealthPalette.telemetryAccent, socColor, socColor,
        const Color(0xFFEB5757), const Color(0xFFF2994A),
      ]);
      expect(sparkMetrics.map((m) => m.format(c)), [
        '-12.5 A out', '13.26 V', '165 W', '77%', '77.0 Ah', '23 °C', '22 °C',
      ]);
    });
  });

  group('site 4: detail-page sections render the original rows', () {
    test('Pack', () {
      final c = full();
      final rows = detailMetrics(DetailSection.pack);
      expect(rows.map((m) => m.labelOnDetail), [
        'SOC', 'Voltage', 'Current', 'Power',
        'Status', 'Load', 'Charger', 'Cycles', 'EFC',
      ]);
      expect(metricDef(Metric.efc)!.tooltip, 'Equivalent full cycles');
      expect(metricDef(Metric.soc)!.tooltip, 'State of charge');
      expect(rows.map((m) => m.detailValue(c)), [
        '77%', '13.26 V', '12.5 A', '165 W', 'Discharging', '—', '—', '7', '0.50',
      ]);
    });

    test('Capacity', () {
      final c = full();
      final rows = detailMetrics(DetailSection.capacity);
      expect(rows.map((m) => m.labelOnDetail),
          ['Remaining', 'Full / rated', 'Time to full', 'Time to empty']);
      expect(rows.map((m) => m.detailValue(c)),
          ['77.0 Ah', '100.0 Ah', '00:00:00', '06:06:40']);
    });

    test('Cells', () {
      final c = full();
      final rows = detailMetrics(DetailSection.cells);
      expect(rows.map((m) => m.labelOnDetail),
          ['Sum of cells', 'Average', 'Max', 'Min', 'Delta']);
      expect(rows.map((m) => m.detailValue(c)),
          ['13.26 V', '3.31 V', '3.33 V', '3.30 V', '0.03 V']);
    });

    test('#107: Cells renders as two one-line rows', () {
      final c = full();
      final rows = detailRows(DetailSection.cells);
      expect(rows.map((r) => r.label), ['Sum / Average', 'Min / Max / Delta']);
      expect(rows.map((r) => r.value(c)),
          ['13.26 / 3.310 V', '3.300 / 3.330 / 0.030 V']);
      expect(rows.last.metrics.map((m) => m.key),
          [Metric.cellMin, Metric.cellMax, Metric.cellDelta]);
      // Every catalogue row of the section is behind exactly one row.
      expect([for (final r in rows) ...r.metrics],
          unorderedEquals(detailMetrics(DetailSection.cells)));
      // Partly known: the unknown part is a dash; none known: one dash.
      c.state.cellMax = null;
      expect(rows.last.value(c), '3.300 / — / 0.030 V');
      c.state
        ..cellMin = null
        ..cellDiff = null;
      expect(rows.last.value(c), '—');
    });

    test('#107: the other sections are one row per metric', () {
      for (final s in DetailSection.values) {
        if (s == DetailSection.cells) continue;
        expect(detailRows(s).map((r) => r.label),
            detailMetrics(s).map((m) => m.labelOnDetail), reason: '$s');
      }
    });

    test('Temperature', () {
      final c = full();
      final rows = detailMetrics(DetailSection.temperature);
      // #114: Temp A = temp2 (byte[3]), Temp B = temp1 (byte[1]); no chip.
      expect(rows.map((m) => m.labelOnDetail), ['Temp A', 'Temp B']);
      expect(rows.map((m) => m.detailValue(c)), ['23 °C', '22 °C']);
    });

    test('Gates & status', () {
      final c = full();
      c.state
        ..mosOn = true
        ..chargeMos = true
        ..dischargeMos = false
        ..passiveBalancing = false
        ..unrecognisedBytes = 3;
      final rows = detailMetrics(DetailSection.gates);
      expect(rows.map((m) => m.labelOnDetail), [
        'Both switches', 'Charge switch', 'Output switch', 'Passive balancing',
        'Low-temp protection', 'Smoke sensor', 'Heater', 'Over-temp latched',
        'Firmware', 'RSSI', 'Stray bytes',
        'Frames (this link)', 'Last frame', // #61
      ]);
      expect(rows.map((m) => m.detailValue(c)), [
        'On', 'On', 'Off', 'Off', 'On', 'Off', '0', 'No', '1.0.1', '-60 dBm', '3',
        '—', '—', // #61: not connected
      ]);
      c.state.overTempLatched = true;
      expect(metricDef(Metric.overTempLatched)!.detailValue(c),
          'Yes — restart to clear');
      c.state.temperatureAlarmSeen = false;
      expect(metricDef(Metric.overTempLatched)!.detailValue(c), '—');
    });

    test('an empty state renders em dashes everywhere', () {
      final c = BatteryConnection(transport: FakeTransport());
      for (final m in metricTable) {
        if (m.key == Metric.displayUnrecognised) continue; // a count: "0"
        expect(m.detailValue(c), '—', reason: m.key);
      }
    });
  });

  group('#114: the duplicate temperature bytes and the chip byte', () {
    test('are still LOGGED but shown nowhere (no chart, row or sparkline)',
        () {
      for (final k in [Metric.temp0, Metric.temp3, Metric.chipTemp]) {
        final m = metricDef(k)!;
        expect(m.logged, isTrue, reason: '$k: all data is kept');
        expect(m.chartGroup, isNull, reason: k);
        expect(m.detailSection, isNull, reason: k);
        expect(m.spark, isNull, reason: k);
      }
      final shown = [
        for (final m in metricTable)
          if (m.detailSection != null || m.chartGroup != null || m.spark != null)
            m.labelOnDetail,
      ];
      expect(shown.where((l) => l.contains('Chip') || l.contains('Probe')),
          isEmpty);
    });

    test('the logger still writes temp0 / temp3 / chip', () {
      final log = BatteryLogger.custom();
      final c = full();
      log.observeConnection(c, nowMs: 1000);
      expect(log.hourSegments('JS-T', Metric.temp0).single.valueNum, 21);
      expect(log.hourSegments('JS-T', Metric.temp3).single.valueNum, 24);
      expect(log.hourSegments('JS-T', Metric.chipTemp).single.valueNum, 0);
    });
  });

  group('ChargeStateStyle — the one label/colour map', () {
    test('direction colour, band colour, labels and words', () {
      final ch = ChargeStateStyle.of(ChargeState.charging);
      expect((ch.color, ch.bandColor, ch.label, ch.shortLabel, ch.word),
          (HealthPalette.healthy, HealthPalette.healthy, 'Charging', 'Charging', 'in'));
      final di = ChargeStateStyle.of(ChargeState.discharging);
      expect((di.color, di.bandColor, di.label, di.shortLabel, di.word),
          (HealthPalette.faultRed, HealthPalette.warn, 'Discharging', 'Discharging', 'out'));
      final id = ChargeStateStyle.of(ChargeState.idle);
      expect((id.color, id.bandColor, id.label, id.shortLabel, id.word),
          (HealthPalette.idle, HealthPalette.idle, 'Idle · no load', 'Idle', ''));
      final un = ChargeStateStyle.of(ChargeState.unknown);
      expect((un.color, un.label, un.shortLabel), (HealthPalette.idle, 'Idle · no load', '—'));
    });
  });
}
