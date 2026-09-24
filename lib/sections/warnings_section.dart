/// A red "… alarms" card listing the decoded warning strings of one alarm
/// byte (current / voltage / temperature); nothing when the list is empty.
library;

import 'package:flutter/material.dart';

import '../widgets.dart';
import 'section_card.dart';

class WarningsSection extends StatelessWidget {
  final String title;
  final List<String> items;
  final bool dense;
  const WarningsSection(this.title, this.items, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      color: Colors.red.shade900,
      margin: kCardMargin,
      child: Padding(
        padding: sectionPadding(dense),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: sectionTitleStyle(context)),
            const Divider(height: kTitleRuleHeight),
            // #3: one text line per warning.
            for (final w in items)
              Row(children: [
                const Icon(Icons.warning_amber, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(w)),
              ]),
          ],
        ),
      ),
    );
  }
}
