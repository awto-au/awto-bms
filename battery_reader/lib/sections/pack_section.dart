/// "Pack" detail section: the catalogue rows of [DetailSection.pack].
/// #71: [stale] (null while live) renders the rows as last-known with one
/// caption on the card.
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import '../stale.dart';
import 'section_card.dart';

class PackSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  final Staleness? stale;
  const PackSection(
      {super.key, required this.conn, this.dense = false, this.stale});

  @override
  Widget build(BuildContext context) => SectionCard(
      'Pack', metricKvRows(DetailSection.pack, conn, stale: stale != null),
      dense: dense, stale: stale);
}
