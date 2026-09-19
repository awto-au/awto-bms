/// Shared presentational widgets (review pass C2, GitHub #51). Each one
/// replaces two or three hand-copied layouts in main.dart / battery_charts.dart
/// and renders them pixel-for-pixel as before — the parameters exist only to
/// carry the differences the original copies had.
library;

import 'package:flutter/material.dart';

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

/// The "● Charging … values" status line: a coloured dot, the direction word
/// in the same colour, a Spacer and the trailing figures.
class StatusLine extends StatelessWidget {
  final Color color;
  final String label;
  final double dotSize;
  final double gap;
  final double? fontSize;
  final List<Widget> trailing;

  const StatusLine({
    super.key,
    required this.color,
    required this.label,
    required this.dotSize,
    required this.gap,
    required this.trailing,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: gap),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: fontSize, fontWeight: FontWeight.w600)),
          const Spacer(),
          ...trailing,
        ],
      );
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
/// column layout of the detected-device info sheet.
class KvRow extends StatelessWidget {
  final String k;
  final String v;
  final bool info;
  const KvRow(this.k, this.v, {super.key}) : info = false;
  const KvRow.info(this.k, this.v, {super.key}) : info = true;

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
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
