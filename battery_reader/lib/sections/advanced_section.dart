/// #41: "Advanced" — the firmware update entry. Disabled with the reason
/// while the pack is not connected, a write is in flight or another update
/// is running; the page itself runs the full pre-flight / warning / typed
/// confirmation flow before anything is sent. Shared by both layouts (#68).
library;

import 'package:flutter/material.dart';

import '../battery_connection.dart';
import '../ota_update.dart' show OtaLock;
import '../ota_update_page.dart';
import '../write_actions.dart' show BusyWrites;
import 'section_card.dart';

class AdvancedSection extends StatelessWidget {
  final BatteryConnection conn;
  final BusyWrites busy;
  final bool Function() keepAwake;
  final VoidCallback onChanged;
  final bool dense;
  const AdvancedSection({
    super.key,
    required this.conn,
    required this.busy,
    required this.keepAwake,
    required this.onChanged,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = conn.state;
    final String? reason;
    if (conn.connState != ConnState.connected) {
      reason = 'Not connected';
    } else if (s.serial == null || s.serial!.isEmpty) {
      reason = 'Serial unknown';
    } else if (OtaLock.inProgress) {
      reason = OtaLock.refuseReason;
    } else if (busy.any) {
      reason = 'Write in progress (${busy.current})';
    } else {
      reason = null;
    }
    return Card(
      child: Padding(
        padding: sectionPadding(dense),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Advanced',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update_alt),
              title: const Text('Firmware update'),
              subtitle: Text(reason ??
                  'Flash a vendor .bin to this BMS (current version: '
                      '${s.firmwareVersion ?? 'unknown'}). A failed update '
                      'can permanently disable the battery.'),
              enabled: reason == null,
              trailing: const Icon(Icons.chevron_right),
              onTap: reason != null
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FirmwareUpdatePage(
                            conn: conn,
                            busy: busy,
                            keepAwake: () => otaKeepAwakeOk(keepAwake()),
                            keepAwakeDetail: () =>
                                otaKeepAwakeDetail(keepAwake()),
                          ),
                        ),
                      );
                      onChanged();
                    },
            ),
          ],
        ),
      ),
    );
  }
}
