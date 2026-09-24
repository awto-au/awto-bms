/// "Temperature" detail section: the catalogue rows of
/// [DetailSection.temperature] (probes, chip, unit per #43).
/// #71: [stale] (null while live) renders the rows as last-known with one
/// caption on the card.
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import '../stale.dart';
import 'section_card.dart';

class TemperaturesSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  final Staleness? stale;
  const TemperaturesSection(
      {super.key, required this.conn, this.dense = false, this.stale});

  @override
  Widget build(BuildContext context) => SectionCard(
      'Temperature', metricKvRows(DetailSection.temperature, conn, stale: stale != null),
      dense: dense, stale: stale);
}
