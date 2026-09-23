/// "Capacity" detail section: the catalogue rows of [DetailSection.capacity].
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import 'section_card.dart';

class CapacitySection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  const CapacitySection({super.key, required this.conn, this.dense = false});

  @override
  Widget build(BuildContext context) => SectionCard(
      'Capacity', metricKvRows(DetailSection.capacity, conn),
      dense: dense);
}
