/// "Cells" detail section: the per-cell voltages in a row, then the catalogue
/// rows of [DetailSection.cells] — #107: two one-line rows, `Sum / Average`
/// and `Min / Max / Delta` (see [detailRows]).
/// #71: [stale] (null while live) renders the cells and rows as last-known
/// with one caption on the card.
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../battery_connection.dart';
import '../metrics.dart';
import '../stale.dart';
import '../widgets.dart' show kTitleRuleHeight;
import 'section_card.dart';

class CellsSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  final Staleness? stale;
  const CellsSection(
      {super.key, required this.conn, this.dense = false, this.stale});

  @override
  Widget build(BuildContext context) {
    final s = conn.state;
    const cellStyle = TextStyle(fontWeight: FontWeight.w600);
    return SectionCard(
      'Cells',
      [
        if (s.cellsMv.isEmpty)
          const Text('—', style: TextStyle(color: Colors.white70))
        else
          // #3: the cell voltages on one text line, no padding.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final mv in s.cellsMv)
                Text('${(mv / 1000).toStringAsFixed(3)} V',
                    style: stale != null ? staleFigure(cellStyle) : cellStyle),
            ],
          ),
        const Divider(height: kTitleRuleHeight),
        ...metricKvRows(DetailSection.cells, conn, stale: stale != null),
      ],
      dense: dense,
      stale: stale,
    );
  }
}
