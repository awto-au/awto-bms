/// #71: the ONE notion of "stale" the shared section widgets use.
///
/// A value is LIVE while the connection is streaming — telemetry within the
/// not-streaming window, or the last background sample (#53) — and the
/// widgets render it in their normal colours. Otherwise (silent, dormant,
/// waiting for the first frame, connecting, an offline remembered
/// favourite) the LAST-KNOWN value renders in the stale style ([kStale], see
/// app_theme.dart) with ONE "last known · 3 d ago" caption per card / row
/// group — never a wall of dashes. A value that was never known still reads
/// "—" (the formatters do that on null).
///
/// [staleFor] is the pure decision, [stalenessOf] applies it to a live
/// connection, and [StaleCaption] is the self-ticking caption widget.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'battery_connection.dart';
import 'fmt.dart';
import 'live_indicator.dart';

/// "The figures shown are last-known" plus when they date from.
/// [lastDataMs] is null when the age is unknown (a snapshot with no stamp);
/// the caption then reads just "last known". [now] is the clock the age is
/// measured on (the connection's, so tests with a fake clock agree).
class Staleness {
  final int? lastDataMs;
  final DateTime Function() now;
  const Staleness({required this.lastDataMs, required this.now});

  /// Milliseconds since the values were decoded, or null when unknown.
  int? get ageMs =>
      lastDataMs == null ? null : now().millisecondsSinceEpoch - lastDataMs!;

  /// The caption: "last known · 12 s ago" / "last known · 3 d ago".
  String get caption {
    final age = ageMs;
    return age == null ? 'last known' : 'last known · ${fmtAgeShort(age)} ago';
  }

  @override
  bool operator ==(Object other) =>
      other is Staleness && other.lastDataMs == lastDataMs;

  @override
  int get hashCode => lastDataMs.hashCode;

  @override
  String toString() => 'Staleness($caption)';
}

/// The pure decision: null while [hasData] (the #65 liveness verdict says
/// the figures are live) and not [offline]; otherwise the staleness of the
/// values stamped [lastDataMs], aged on [now].
Staleness? staleFor({
  required bool hasData,
  required bool offline,
  required int? lastDataMs,
  required DateTime Function() now,
}) {
  if (hasData && !offline) return null;
  return Staleness(lastDataMs: lastDataMs, now: now);
}

/// [staleFor] over a live connection with the manager's sampling state
/// ([sampling] / [nextDueMs], #53). Offline = a remembered favourite that is
/// not connected and not being sampled (the card's rule).
Staleness? stalenessOf(
  BatteryConnection c, {
  bool sampling = false,
  int? nextDueMs,
}) {
  final now = c.now().millisecondsSinceEpoch;
  final offline = c.isOffline && !sampling;
  final live =
      liveStatusOf(c, sampling: sampling, nextDueMs: nextDueMs, nowMs: now);
  return staleFor(
    hasData: live.hasData,
    offline: offline,
    lastDataMs: c.lastDataMs,
    now: c.now,
  );
}

/// The one "last known · … ago" caption of a card / row group. Self-ticking
/// (1 s) so the age advances on its own without the page repainting; it
/// rebuilds only when its text changes.
class StaleCaption extends StatefulWidget {
  final Staleness stale;
  final double fontSize;
  final TextAlign textAlign;

  const StaleCaption(this.stale,
      {super.key, this.fontSize = 11, this.textAlign = TextAlign.right});

  @override
  State<StaleCaption> createState() => _StaleCaptionState();
}

class _StaleCaptionState extends State<StaleCaption> {
  Timer? _timer;
  late String _text = widget.stale.caption;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = widget.stale.caption;
      if (next == _text) return;
      setState(() => _text = next);
    });
  }

  @override
  void didUpdateWidget(StaleCaption old) {
    super.didUpdateWidget(old);
    _text = widget.stale.caption;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // No stamp = nothing was ever known: the figures read "—" and need no
    // "last known" caption.
    if (widget.stale.lastDataMs == null) return const SizedBox.shrink();
    return Text(
        _text,
        textAlign: widget.textAlign,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: staleFigure(TextStyle(
            fontSize: widget.fontSize, fontWeight: FontWeight.w600)),
      );
  }
}
