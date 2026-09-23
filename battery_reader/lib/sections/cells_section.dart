/// "Cells" detail section: the per-cell voltages in a row, then the catalogue
/// rows of [DetailSection.cells] (delta, min/max, sum / average …).
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../metrics.dart';
import 'section_card.dart';

class CellsSection extends StatelessWidget {
  final BatteryConnection conn;
  final bool dense;
  const CellsSection({super.key, required this.conn, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final s = conn.state;
    return SectionCard(
      'Cells',
      [
        if (s.cellsMv.isEmpty)
          const Text('—', style: TextStyle(color: Colors.white70))
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final mv in s.cellsMv)
                  Text('${(mv / 1000).toStringAsFixed(3)} V',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        const Divider(height: 20),
        ...metricKvRows(DetailSection.cells, conn),
      ],
      dense: dense,
    );
  }
}
