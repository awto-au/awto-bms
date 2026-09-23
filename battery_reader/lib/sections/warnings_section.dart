/// A red "… alarms" card listing the decoded warning strings of one alarm
/// byte (current / voltage / temperature); nothing when the list is empty.
library;

import 'package:flutter/material.dart';

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
      child: Padding(
        padding: sectionPadding(dense),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            for (final w in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.warning_amber, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(w)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
