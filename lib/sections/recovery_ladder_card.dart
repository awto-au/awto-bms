/// #62: shown while the pack is connected but NOT streaming. States the
/// classification (the AT+V probe's verdict) and offers the user-initiated
/// recovery ladder — re-send CMD_BEGIN, both switches ON (the vendor's
/// de-facto wake), reconnect — each reporting whether the stream resumed. A
/// pack whose BMS is not running (dormant OR no reply to AT+V — the bridge's
/// 0x30 is intermittent, #63) gets the red card and the plain
/// physical-recovery message; the finer verdict is the detail line. Shared by
/// both layouts (#68).
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../battery_connection.dart';
import '../battery_manager.dart';
import '../fmt.dart';
import '../widgets.dart' show kCardMargin, kCardPadding;
import '../write_actions.dart';

class RecoveryLadderCard extends StatelessWidget {
  final BatteryConnection conn;
  final BatteryManager manager;
  final BusyWrites busy;
  final VoidCallback onChanged;
  const RecoveryLadderCard({
    super.key,
    required this.conn,
    required this.manager,
    required this.busy,
    required this.onChanged,
  });

  Future<void> _run(BuildContext context, WriteAction action) =>
      runWriteAction(context, action, busy: busy, onChanged: onChanged);

  @override
  Widget build(BuildContext context) {
    final cls = conn.streamClass;
    final dormant = conn.bmsNotRunning; // #63: dormant OR no reply
    final silent = conn.silenceMs ?? 0;
    final headline = switch (cls) {
      StreamClass.dormant || StreamClass.noResponse =>
        'Connected, not streaming — ${BatteryConnection.bmsNotRunningState}',
      StreamClass.awakeNotStreaming =>
        'Connected, not streaming — ${BatteryConnection.awakeNotStreamingState}',
      _ => conn.probeInFlight
          ? 'Connected, not streaming — probing the BMS (AT+V)…'
          : 'Connected, not streaming — no telemetry for '
              '${(silent / 1000).round()} s',
    };
    final probeAge = conn.lastProbeMs == null
        ? null
        : conn.now().millisecondsSinceEpoch - conn.lastProbeMs!;
    final busyAny = busy.any;
    return Card(
      color: dormant ? const Color(0xFF3A1414) : const Color(0xFF3A2E10),
      margin: kCardMargin, // #3: no spacer above, 4 px card gap
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(dormant ? Icons.power_off : Icons.hourglass_empty,
                    size: 18, color: dormant ? kRed : Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(headline,
                      style: TextStyle(
                          color: dormant ? kRed : Colors.amber,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            if (dormant)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(BatteryConnection.dormantMessage,
                    style: TextStyle(fontSize: 13)),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  switch (cls) {
                    StreamClass.awakeNotStreaming =>
                      'The BMS answers AT+V, so it is running; CMD_BEGIN was '
                          're-sent. If the stream does not resume, try the '
                          'steps below.',
                    _ => 'The pack is linked but has sent no telemetry. The '
                        'app probes it with AT+V after 10 s of silence to '
                        'tell a dormant BMS from one that merely stopped '
                        'streaming.',
                  },
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Frames on this link: ${conn.frameCount}'
                '${probeAge == null ? '' : ' · last probe ${fmtAgeShort(probeAge)} ago · ${BatteryConnection.probeDetail(cls)}'}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow, size: 16),
                  onPressed: busyAny
                      ? null
                      : () => _run(context, wakeResendAction(conn)),
                  label: const Text('Re-send wake (CMD_BEGIN)'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.toggle_on, size: 16),
                  onPressed: busyAny || conn.safeWritesDisabledReason != null
                      ? null
                      : () => _run(context, wakeSwitchesOnAction(conn)),
                  label: const Text('Turn switches on'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.bluetooth_searching, size: 16),
                  onPressed: busyAny
                      ? null
                      : () => _run(context, wakeReconnectAction(conn, manager)),
                  label: const Text('Reconnect'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.search, size: 16),
                  onPressed: busyAny || conn.probeInFlight
                      ? null
                      : () async {
                          final r = await conn.probeStreaming();
                          onChanged();
                          if (context.mounted) {
                            showToast(context, 'AT+V probe: ${r.name}');
                          }
                        },
                  label: const Text('Probe again (AT+V)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
