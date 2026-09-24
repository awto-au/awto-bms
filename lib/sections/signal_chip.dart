/// Signal-strength (RSSI) icon grading and the small [SignalChip] shown on the
/// list row and the detected-device sheet.
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../fmt.dart';

// Signal-strength icon graded by RSSI (dBm). Higher (closer to 0) is stronger.
IconData rssiIcon(int? v) {
  if (v == null) return Icons.signal_cellular_off;
  if (v >= -60) return Icons.network_cell;
  if (v >= -75) return Icons.signal_cellular_alt;
  if (v >= -88) return Icons.signal_cellular_alt_2_bar;
  return Icons.signal_cellular_alt_1_bar;
}

Color rssiColor(int? v) {
  if (v == null) return Colors.white38;
  if (v >= -65) return kGreen;
  if (v >= -80) return Colors.amber;
  return kRed;
}

/// Small signal-strength chip: an icon graded by RSSI plus the dBm value.
class SignalChip extends StatelessWidget {
  final int? rssi;
  const SignalChip(this.rssi, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = rssiColor(rssi);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(rssiIcon(rssi), size: 16, color: c),
        const SizedBox(width: 3),
        Text(fRssi(rssi), style: TextStyle(fontSize: 12, color: c)),
      ],
    );
  }
}
