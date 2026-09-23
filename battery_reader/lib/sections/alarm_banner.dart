/// Loud red banner at the top of the detail view while a battery is in alarm.
/// "Acknowledge" (M1) clears the sticky unknown-byte-change / link-error state;
/// a still-live genuine fault stays red. Shared by both layouts (#68).
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';

class AlarmBanner extends StatelessWidget {
  final List<String> reasons;
  final VoidCallback? onAcknowledge;
  const AlarmBanner({super.key, required this.reasons, this.onAcknowledge});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kRed,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('ALERT',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                      const SizedBox(height: 4),
                      for (final r in reasons.reversed.take(5))
                        Text('• $r',
                            style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
            if (onAcknowledge != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  icon: const Icon(Icons.check, size: 18),
                  onPressed: onAcknowledge,
                  label: const Text('Acknowledge'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
