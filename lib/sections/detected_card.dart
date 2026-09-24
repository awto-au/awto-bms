/// DETECT-only list entries (issue #15) for an other-family BMS recognised in
/// range but NOT supported for decode, plus the info sheet a tap opens. Shared
/// by the phone list and the desktop left pane (#68).
library;

import 'package:flutter/material.dart';

import '../bms_families.dart';
import '../widgets.dart';
import 'signal_chip.dart';

/// Visually MUTED and clearly distinct from a real (JoySuny) battery card: no
/// SOC bar, no fleet star, no telemetry — just the family, the advertised
/// name, RSSI and a "detected · not yet supported" badge. Tapping opens an
/// info sheet. It is never connected or decoded.
class DetectedCard extends StatelessWidget {
  final DetectedDevice device;
  final VoidCallback onTap;
  const DetectedCard({super.key, required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const muted = Colors.white38;
    return Card(
      // Muted, semi-transparent surface so it visibly recedes behind real packs.
      color: Colors.white.withValues(alpha: 0.03),
      margin: kCardMargin, // #3: 4 px between list cards
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              const Icon(Icons.help_outline, color: muted, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Issue #29: no RSSI/dBm on the main-screen card (still shown
                    // in the tapped info sheet's diagnostics).
                    Text(
                      device.family.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.name.isNotEmpty ? device.name : device.deviceId,
                      style: const TextStyle(color: muted, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    // The badge that sets this entry apart from a supported pack.
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'detected · not yet supported',
                        style: TextStyle(
                          color: muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Info sheet for a DETECT-only device: family, advertised name, the UUIDs we
/// recognise it by, and a plain statement that decoding this family isn't
/// implemented yet. No actions — this family is never connected or decoded.
class DetectedInfoSheet extends StatelessWidget {
  final DetectedDevice device;
  const DetectedInfoSheet({super.key, required this.device});

  /// Open the sheet for [d] as a modal bottom sheet (the only interaction
  /// offered for such a device: there is deliberately NO connect / handshake /
  /// decode path. DECODE per family is future work).
  static void show(BuildContext context, DetectedDevice d) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => DetectedInfoSheet(device: d),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = device.family;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, color: Colors.white54),
              const SizedBox(width: 10),
              Expanded(
                child: Text(f.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              SignalChip(device.rssi),
            ],
          ),
          const SizedBox(height: 12),
          KvRow.info('Advertised name',
              device.name.isNotEmpty ? device.name : '(none)'),
          KvRow.info('Device id', device.deviceId),
          if (f.serviceUuid != null)
            KvRow.info('Service', _short(f.serviceUuid!)),
          if (f.notifyChars.isNotEmpty)
            KvRow.info('Notify', f.notifyChars.map(_short).join(', ')),
          if (f.writeChars.isNotEmpty)
            KvRow.info('Write', f.writeChars.map(_short).join(', ')),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Decoding this battery family isn\'t implemented yet. The app '
              'recognises it in range but only fully supports JoySuny packs '
              '(Sphere / RV). Support for this family is future work.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  // Show the recognisable 16-bit part of a stock UUID for readability.
  static String _short(String uuid) {
    final m = RegExp(r'^0000([0-9a-fA-F]{4})-0000-1000-8000-00805f9b34fb$')
        .firstMatch(uuid);
    return m != null ? '0x${m.group(1)!.toUpperCase()}' : uuid;
  }
}
