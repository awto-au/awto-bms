/// App-wide colour tokens and the two tiny helpers every layout shares
/// ([effState], [alertBeep]). Split out of main.dart (#68) so the section
/// widgets under lib/sections/ can use them without importing the app root.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemSound, SystemSoundType;

import 'battery_protocol.dart';
import 'health_palette.dart';

// Shared palette. Direction tokens (green charging / red discharging / neutral
// idle) are sourced from the ONE app-wide [HealthPalette] (issue #13) so the
// whole app speaks a single colour language. SOC-graded colours come from
// [HealthPalette.colorForSoc]; [kRed] stays the distinct alarm/fault red.
const kGreen = HealthPalette.healthy;
const kRed = HealthPalette.faultRed;
const kIdle = HealthPalette.idle;
const kTrack = Color(0xFF222A35); // dark SOC-bar track (HealthPalette.track resolves per theme)

/// #71: a LAST-KNOWN (not live) figure — the fault red at 75 % opacity. Every
/// shared widget renders a remembered value in this colour, with tabular
/// numerals ([staleFigure]), whenever the connection is not streaming, so
/// the phone and desktop layouts cannot drift apart on how "stale" looks.
const kStale = Color(0xBFE5484D); // HealthPalette.faultRed, alpha 0xBF

/// #71: the stale text style — [kStale] + tabular numerals — layered over a
/// widget's own size / weight ([base]) so only the colour says "not live".
TextStyle staleFigure([TextStyle? base]) => (base ?? const TextStyle()).copyWith(
      color: kStale,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// [base] while live, [staleFigure] of it while [stale] — the one switch
/// every figure in the shared widgets goes through. With [text] given, a
/// figure that holds no value at all ("—", "—  ·  —") keeps [base]: a
/// never-known value is a plain dash, not a stale one.
TextStyle staleOr(bool stale, TextStyle base, {String? text}) =>
    stale && (text == null || !_noValue.hasMatch(text))
        ? staleFigure(base)
        : base;

final RegExp _noValue = RegExp(r'^[—\s·]*$');

/// Resolve an effective charge state, filling `unknown` from the flags.
ChargeState effState(BatteryState s) {
  final cs = s.chargeState;
  if (cs != ChargeState.unknown) return cs;
  if (s.chargerConnected == true) return ChargeState.charging;
  if ((s.packCurrent ?? 0) > 0 && s.loadConnected == true) {
    return ChargeState.discharging;
  }
  return ChargeState.idle;
}

/// Loud audible + haptic alert for a fault / unknown-byte change / disconnect.
void alertBeep() {
  // System alert sound (falls back to a click where 'alert' is unsupported) plus
  // a strong haptic buzz, so an error is impossible to miss.
  SystemSound.play(SystemSoundType.alert);
  HapticFeedback.heavyImpact();
}
