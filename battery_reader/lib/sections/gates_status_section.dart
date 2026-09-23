/// "Gates & status" detail section: the catalogue rows of
/// [DetailSection.gates] (switches, balancing, heater, standby, frames …).
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import 'section_card.dart';

class GatesStatusSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  const GatesStatusSection({super.key, required this.conn, this.dense = false});

  @override
  Widget build(BuildContext context) => SectionCard(
      'Gates & status', metricKvRows(DetailSection.gates, conn),
      dense: dense);
}
