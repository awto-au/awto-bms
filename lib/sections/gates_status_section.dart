/// "Gates & status" detail section: the catalogue rows of
/// [DetailSection.gates] (switches, balancing, heater, standby, frames …).
/// #71: [stale] (null while live) renders the rows as last-known with one
/// caption on the card.
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import '../stale.dart';
import 'section_card.dart';

class GatesStatusSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  final Staleness? stale;
  const GatesStatusSection(
      {super.key, required this.conn, this.dense = false, this.stale});

  @override
  Widget build(BuildContext context) => SectionCard(
      'Gates & status', metricKvRows(DetailSection.gates, conn, stale: stale != null),
      dense: dense, stale: stale);
}
