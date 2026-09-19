/// App-wide health colour system (issue #13).
///
/// ONE shared palette, keyed to state-of-charge and matching the linear SOC
/// bar: 100 % = green, grading down through amber/yellow to red at low
/// charge. It also carries the semantic tokens used across the app so every
/// screen speaks the same colour language and works in light and dark themes.
///
///  * [colorForSoc] — the graded SOC colour (the SOC % number, the SOC bar
///    fill, and each battery's identity accent all use it).
///  * [healthy] / [warn] / [critical] — semantic green / amber / red.
///  * [faultRed] — the DISTINCT alarm/fault red kept from Pass 1. It is a
///    separate semantic from the health gradient: an active fault OVERRIDES the
///    graded health colour (see [socOrFault]).
///  * [telemetryAccent] — a neutral accent for telemetry sparklines.
///
/// The vivid hues are theme-independent (they read on both light and dark
/// surfaces); only the neutral chrome ([track], [gridLine]) resolves per
/// [Brightness].
library;

import 'package:flutter/material.dart';

import 'battery_protocol.dart' show ChargeState;

/// The ONE charge-state label / colour map (review pass C2). It replaces the
/// `stateStyle` + `fState` switches in main.dart and the band-colour /
/// `LoadBandState` maps in battery_charts.dart, which had each grown their own
/// copy of "charging is green, discharging is …".
///
///  * [color] — the direction colour used by the cards and the detail header:
///    green charging, the alarm red discharging, neutral idle.
///  * [bandColor] — the charge-state band on the charts page (#22), which
///    grades discharging as AMBER (a load, not a fault) — deliberately not the
///    fault red, so a discharging stretch never reads as an alarm.
///  * [label] — the status-line word ("Idle · no load"), [shortLabel] the
///    detail-row word ("Idle", "—" for unknown), [word] the flow direction.
class ChargeStateStyle {
  final Color color;
  final Color bandColor;
  final String label;
  final String shortLabel;
  final String word;
  const ChargeStateStyle._(
      this.color, this.bandColor, this.label, this.shortLabel, this.word);

  static const charging = ChargeStateStyle._(HealthPalette.healthy,
      HealthPalette.healthy, 'Charging', 'Charging', 'in');
  static const discharging = ChargeStateStyle._(HealthPalette.faultRed,
      HealthPalette.warn, 'Discharging', 'Discharging', 'out');
  static const idle = ChargeStateStyle._(
      HealthPalette.idle, HealthPalette.idle, 'Idle · no load', 'Idle', '');
  static const unknown = ChargeStateStyle._(
      HealthPalette.idle, HealthPalette.idle, 'Idle · no load', '—', '');

  static ChargeStateStyle of(ChargeState cs) => switch (cs) {
        ChargeState.charging => charging,
        ChargeState.discharging => discharging,
        ChargeState.idle => idle,
        ChargeState.unknown => unknown,
      };
}

class HealthPalette {
  const HealthPalette._();

  // --- semantic tokens ------------------------------------------------------

  /// Full / good — the green end of the SOC gradient.
  static const Color healthy = Color(0xFF2FBF71);

  /// A mid amber, for warnings that are not yet critical.
  static const Color warn = Color(0xFFF2B01E);

  /// Low-charge / critical — the red end of the SOC gradient. Deliberately a
  /// DIFFERENT red from [faultRed] so "nearly empty" never looks identical to
  /// "in alarm".
  static const Color critical = Color(0xFFE5533B);

  /// The alarm/fault red kept from Pass 1. This is its own semantic and, when a
  /// fault is active, it OVERRIDES the health colour everywhere (see
  /// [socOrFault]).
  static const Color faultRed = Color(0xFFE5484D);

  /// Neutral accent for per-row telemetry sparklines (a metric with no health
  /// meaning of its own — voltage, temperature, power, …).
  static const Color telemetryAccent = Color(0xFF4C9AFF);

  /// Idle / no-flow neutral (matches the old `kIdle`).
  static const Color idle = Color(0xFF8895A7);

  // --- SOC gradient ---------------------------------------------------------

  /// Gradient control stops, low-charge (t=0) to full (t=1). Chosen so the
  /// SOC bar reads red → orange → yellow → green as it fills.
  static const List<(double, Color)> _stops = <(double, Color)>[
    (0.00, critical), // ~empty: red
    (0.30, Color(0xFFF2994A)), // amber / orange
    (0.55, Color(0xFFF2C94C)), // yellow
    (1.00, healthy), // full: green
  ];

  /// Graded colour for a state-of-charge percentage (0..100). 100 → green,
  /// grading through amber/yellow to red near 0. Values outside 0..100 clamp.
  static Color colorForSoc(double pct) {
    final t = (pct / 100.0).clamp(0.0, 1.0);
    for (var i = 0; i < _stops.length - 1; i++) {
      final (t0, c0) = _stops[i];
      final (t1, c1) = _stops[i + 1];
      if (t <= t1) {
        final f = (t1 == t0) ? 0.0 : ((t - t0) / (t1 - t0)).clamp(0.0, 1.0);
        return Color.lerp(c0, c1, f)!;
      }
    }
    return _stops.last.$2;
  }

  /// The SOC-graded colour, unless a fault is active — then the distinct
  /// [faultRed] takes over. Callers pass whether the battery is in alarm.
  static Color socOrFault(double pct, {bool fault = false}) =>
      fault ? faultRed : colorForSoc(pct);

  // --- theme-resolved neutrals ---------------------------------------------

  /// The unfilled track behind a SOC bar, per theme.
  static Color track(Brightness b) => b == Brightness.dark
      ? const Color(0xFF222A35)
      : const Color(0xFFE2E7EE);

  /// A faint grid / divider line, per theme.
  static Color gridLine(Brightness b) => b == Brightness.dark
      ? const Color(0xFF2A333F)
      : const Color(0xFFD3D9E0);

  /// Text/icon colour to lay OVER a filled health colour. The health hues are
  /// saturated, so white reads on all of them in both themes.
  static const Color onHealth = Colors.white;
}
