/// #50: amber WARNING card shown while the latched over-temperature protection
/// (CMD_WARN_TEMP_ALARM byte[2]) is set. Not a live fault — the pack is not hot
/// now — but charging may be inhibited until the BMS is restarted. Carries the
/// same restart control (and confirmation) as the Controls section. Shared by
/// both layouts (#68).
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../write_actions.dart';

class LatchedOverTempCard extends StatelessWidget {
  final BatteryConnection conn;
  final VoidCallback onChanged;

  /// M4: shared in-flight flags (the restart key is common with Controls).
  final BusyWrites busy;
  const LatchedOverTempCard({
    super.key,
    required this.conn,
    required this.onChanged,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    // #55/#59: restart is a SAFE write — any connected link — so the latched
    // over-temp can always be cleared.
    final gateReason = busy.any
        ? 'a write is in progress (${busy.current})'
        : conn.safeWritesDisabledReason;
    return Card(
      color: const Color(0xFF3D2E0A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Colors.amber, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber, color: Colors.amber),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('WARNING — over-temperature protection latched',
                          style: TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                      SizedBox(height: 4),
                      Text(
                        'Over-temperature protection latched — charging may '
                        'be inhibited. Set by a past over-temp event. Restart '
                        'the BMS to clear.',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.amber, foregroundColor: Colors.black),
              icon: const Icon(Icons.restart_alt, size: 18),
              onPressed: gateReason != null
                  ? null
                  : () => runWriteAction(context, restartAction(conn),
                      busy: busy, onChanged: onChanged),
              label: const Text('Restart BMS to clear'),
            ),
            if (gateReason != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(restartUnavailableText(gateReason),
                    style:
                        const TextStyle(color: Colors.amber, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}
