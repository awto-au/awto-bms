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

/// #3 compact layout: the ONE vertical rhythm every shared card follows on
/// the phone AND the desktop (they stay identical). A data row is exactly one
/// text line with no vertical padding; a card has 6 px inside (4 px above
/// the title) and 2 px margin, so neighbouring cards sit 4 px apart.
const EdgeInsets kCardMargin = EdgeInsets.all(2);
const EdgeInsets kCardPadding = EdgeInsets.fromLTRB(6, 4, 6, 6);

/// The detail page's outer padding (phone and desktop alike).
const EdgeInsets kPagePadding = EdgeInsets.all(4);

/// The title rule under a section title: 2 px, the line, 2 px.
const double kTitleRuleHeight = 5;

/// A section title: the theme's titleMedium on ONE body-text line (20 px at
/// 1x, the same as a data row) instead of its 24 px default.
TextStyle? sectionTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleMedium?.copyWith(height: 1.25);

/// #103: the ONE geometry of the figure-carrying SOC bars — the per-pack list
/// card and the fleet total share it, so the two cannot drift. Phone / dense
/// (desktop) heights and corner radii; just tall enough for the SOC figure.
const double kSocBarHeight = 34;
const double kSocBarHeightDense = 22;
const double kSocBarRadius = 10;
const double kSocBarRadiusDense = 6;

/// A linear state-of-charge bar: a rounded track with a fill that is [frac]
/// (0..1) of the width, optionally with an [overlay] (the figures) laid over
/// it at [overlayPadding]. Used by the list card, the fleet total and the
/// detail header (issue #16: LINEAR bars, never rings). #103: the overlay is
/// centred VERTICALLY in the bar (it used to sit at the top).
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
                  Positioned.fill(
                    child: Padding(
                      padding: overlayPadding,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: overlay,
                      ),
                    ),
                  ),
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
/// never-known one and keeps its plain look. #114: [tooltip] is the long
/// form of a short key ("EFC" → "Equivalent full cycles").
class KvRow extends StatelessWidget {
  final String k;
  final String v;
  final bool info;
  final bool stale;
  final String? tooltip;
  const KvRow(this.k, this.v, {super.key, this.stale = false, this.tooltip})
      : info = false;
  const KvRow.info(this.k, this.v, {super.key})
      : info = true,
        stale = false,
        tooltip = null;

  @override
  Widget build(BuildContext context) {
    if (info) {
      // #3: one text line per row, no vertical padding.
      return Row(
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
      );
    }
    // #3: exactly one text line per row — no vertical padding.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _key(),
        // #107: a long one-line value ("3.312 / 3.338 / 0.026 V") shrinks
        // to fit a narrow card rather than overflow; it never wraps.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(v,
                style: staleOr(stale,
                    const TextStyle(fontWeight: FontWeight.w600),
                    text: v)),
          ),
        ),
      ],
    );
  }

  Widget _key() {
    final label = Text(k, style: const TextStyle(color: Colors.white70));
    final t = tooltip;
    return t == null ? label : Tooltip(message: t, child: label);
  }
}
