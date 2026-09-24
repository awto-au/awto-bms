/// Shared presentational widgets (review pass C2, GitHub #51). Each one
/// replaces two or three hand-copied layouts in main.dart / battery_charts.dart
/// and renders them pixel-for-pixel as before — the parameters exist only to
/// carry the differences the original copies had.
library;

import 'package:flutter/material.dart';

import 'app_theme.dart' show kStale, staleOr;
import 'health_palette.dart';

/// The page body shell every screen used to spell out by hand:
/// `SafeArea > Center > ConstrainedBox(maxWidth)`. Issue #30(a): SafeArea keeps
/// the body clear of the Android system navigation bar.
class PageShell extends StatelessWidget {
  final double maxWidth;
  final Widget child;
  const PageShell({super.key, this.maxWidth = 640, required this.child});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        ),
      );
}

/// A linear state-of-charge bar: a rounded track with a fill that is [frac]
/// (0..1) of the width, optionally with an [overlay] (the figures) laid over
/// it at [overlayPadding]. Used by the list card, the fleet total and the
/// detail header (issue #16: LINEAR bars, never rings).
class SocBar extends StatelessWidget {
  final double frac;
  final Color fill;
  final Color track;
  final double height;
  final double radius;
  final Widget? overlay;
  final EdgeInsetsGeometry overlayPadding;

  const SocBar({
    super.key,
    required this.frac,
    required this.fill,
    required this.track,
    required this.height,
    required this.radius,
    this.overlay,
    this.overlayPadding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final fillBox = FractionallySizedBox(
      widthFactor: frac,
      alignment: Alignment.centerLeft,
      child: Container(color: fill),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        height: height,
        color: track,
        child: overlay == null
            ? fillBox
            : Stack(
                children: [
                  fillBox,
                  Padding(padding: overlayPadding, child: overlay),
                ],
              ),
      ),
    );
  }
}

/// #58: one MOSFET switch's state as a compact "Charge on" / "Output off"
/// badge — green when on, muted when off, an em dash while not yet reported.
/// #71: [stale] renders a last-known state in the stale red (same glyph and
/// word, dimmed red text) — never-known stays the em dash.
class SwitchBadge extends StatelessWidget {
  final String label;
  final bool? on;
  final double fontSize;
  final bool stale;
  const SwitchBadge(this.label, this.on,
      {super.key, this.fontSize = 12, this.stale = false});

  @override
  Widget build(BuildContext context) {
    final color = on == null
        ? Colors.white38
        : stale
            ? kStale
            : on!
                ? HealthPalette.healthy
                : HealthPalette.idle;
    final word = on == null ? '—' : (on! ? 'on' : 'off');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(on == true ? Icons.toggle_on : Icons.toggle_off,
            size: fontSize + 6, color: color),
        const SizedBox(width: 4),
        Text('$label $word',
            style: staleOr(
                stale && on != null,
                TextStyle(
                    color: color,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600))),
      ],
    );
  }
}

/// A legend entry: a 10 px swatch (a circle for a line series, a rounded
/// square for a band colour) beside its label.
class LegendSwatch extends StatelessWidget {
  final Color color;
  final String label;
  final bool round;
  const LegendSwatch(this.color, this.label, {super.key, this.round = true});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: round
                ? BoxDecoration(color: color, shape: BoxShape.circle)
                : BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      );
}

/// A key/value row. The default layout is the detail-section / fleet-panel
/// row (key left, bold value right); [KvRow.info] is the denser fixed-key-
/// column layout of the detected-device info sheet. #71: [stale] renders a
/// last-known value in the stale style (red, tabular); an em dash value is a
/// never-known one and keeps its plain look.
class KvRow extends StatelessWidget {
  final String k;
  final String v;
  final bool info;
  final bool stale;
  const KvRow(this.k, this.v, {super.key, this.stale = false}) : info = false;
  const KvRow.info(this.k, this.v, {super.key})
      : info = true,
        stale = false;

  @override
  Widget build(BuildContext context) {
    if (info) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: Text(k,
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(color: Colors.white70)),
          Text(v,
              style: staleOr(stale,
                  const TextStyle(fontWeight: FontWeight.w600),
                  text: v)),
        ],
      ),
    );
  }
}
