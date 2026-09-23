/// The "Alarm events" section of the battery detail page (#67): every
/// alarm-byte transition recorded for the pack, newest first, each with the
/// measured values and the command context at that instant — no manual
/// correlation. The last [AlarmEventsSection.pageSize] are shown with a
/// "Show all" when more exist; Copy puts every shown row (with its full
/// snapshot) on the clipboard.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'alarm_events.dart';

class AlarmEventsSection extends StatelessWidget {
  /// How many rows the section shows before "Show all".
  static const int pageSize = 50;

  final String serial;

  /// The rows to show, NEWEST first.
  final List<AlarmEvent> events;

  /// How many are stored in total (drives "Show all N").
  final int total;
  final bool showingAll;
  final VoidCallback? onShowAll;

  /// Why the load failed (DB error), or null.
  final String? error;

  const AlarmEventsSection({
    super.key,
    required this.serial,
    required this.events,
    required this.total,
    this.showingAll = false,
    this.onShowAll,
    this.error,
  });

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(
        ClipboardData(text: alarmEventsCopyText(serial, events)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alarm events copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final more = total > events.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Alarm events${total > 0 ? ' ($total)' : ''}',
                      style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: events.isEmpty ? null : () => _copy(context),
                ),
              ],
            ),
            const Divider(),
            if (error != null)
              Text('Could not load alarm events: $error',
                  style: TextStyle(color: theme.colorScheme.error))
            else if (events.isEmpty)
              const Text('None recorded — every alarm-byte change is listed '
                  'here with the current, voltage, MOS state and the last '
                  'command at that moment.',
                  style: TextStyle(color: Colors.white70)),
            for (final e in events)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      e.isSet ? Icons.warning_amber : Icons.check_circle_outline,
                      size: 16,
                      color: e.isSet ? Colors.amber : Colors.white54,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Tooltip(
                        message: e.snapshotText(),
                        child: Text(e.describe(),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            if (more && !showingAll && onShowAll != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onShowAll,
                  child: Text('Show all $total'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
