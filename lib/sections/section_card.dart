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

/// Card inner padding. #3: the ONE compact padding ([kCardPadding]) on the
/// phone and the desktop alike; [dense] no longer changes it.
EdgeInsets sectionPadding(bool dense) => kCardPadding;

/// The key/value rows of one detail section, straight from the catalogue —
/// the ONLY place a detail-page metric row is turned into a widget. [stale]
/// (#71) renders every row's value as last-known. #107: a grouped row
/// ([detailRows]) shows several metrics on one line.
List<Widget> metricKvRows(DetailSection section, BatteryConnection conn,
        {bool stale = false}) =>
    [
      for (final r in detailRows(section))
        KvRow(r.label, r.value(conn), stale: stale, tooltip: r.tooltip),
    ];

/// A titled card of rows: `Card > Padding > Column[title, Divider, rows…]`.
/// #3: compact on both layouts — the title is one text line, the rule under
/// it [kTitleRuleHeight], each row one line, 4 px between cards.
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
      margin: kCardMargin,
      child: Padding(
        padding: sectionPadding(dense),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: sectionTitleStyle(context)),
                ),
                if (stale != null) Flexible(child: StaleCaption(stale!)),
              ],
            ),
            const Divider(height: kTitleRuleHeight),
            ...rows,
          ],
        ),
      ),
    );
  }
}
