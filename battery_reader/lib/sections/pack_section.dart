/// "Pack" detail section: the catalogue rows of [DetailSection.pack].
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import 'section_card.dart';

class PackSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  const PackSection({super.key, required this.conn, this.dense = false});

  @override
  Widget build(BuildContext context) => SectionCard(
      'Pack', metricKvRows(DetailSection.pack, conn),
      dense: dense);
}
