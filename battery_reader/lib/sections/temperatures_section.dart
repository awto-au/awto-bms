/// "Temperature" detail section: the catalogue rows of
/// [DetailSection.temperature] (probes, chip, unit per #43).
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import 'section_card.dart';

class TemperaturesSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  const TemperaturesSection({super.key, required this.conn, this.dense = false});

  @override
  Widget build(BuildContext context) => SectionCard(
      'Temperature', metricKvRows(DetailSection.temperature, conn),
      dense: dense);
}
