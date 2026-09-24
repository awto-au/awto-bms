/// The one card frame every detail section renders inside (#68), plus the
/// catalogue-driven key/value rows. Both the phone (stacked) and the desktop
/// (grid) arrangements build their sections from these, so a label or value
/// path exists in exactly one place: the [MetricDef] table.
///
/// #71: a section takes the pack's [Staleness] (null while live). Stale rows
/// render their last-known values in the stale style, and the card carries
/// ONE "last known · … ago" caption in its title row — not one per field.
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import '../stale.dart';
import '../widgets.dart';

/// Card inner padding: 16 on the phone, halved on a dense (desktop) layout.
EdgeInsets sectionPadding(bool dense) =>
    dense ? const EdgeInsets.all(8) : const EdgeInsets.all(16);

/// The key/value rows of one detail section, straight from the catalogue —
/// the ONLY place a detail-page metric row is turned into a widget. [stale]
/// (#71) renders every row's value as last-known.
List<Widget> metricKvRows(DetailSection section, BatteryConnection conn,
        {bool stale = false}) =>
    [
      for (final m in detailMetrics(section))
        KvRow(m.labelOnDetail, m.detailValue(conn), stale: stale),
    ];

/// A titled card of rows: `Card > Padding > Column[title, Divider, rows…]`.
/// [dense] halves the padding (desktop density, #68); nothing else changes.
/// [stale] (#71) adds the one last-known caption beside the title.
class SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> rows;
  final bool dense;
  final Staleness? stale;
  const SectionCard(this.title, this.rows,
      {super.key, this.dense = false, this.stale});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: sectionPadding(dense),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (stale != null) Flexible(child: StaleCaption(stale!)),
              ],
            ),
            const Divider(),
            ...rows,
          ],
        ),
      ),
    );
  }
}
