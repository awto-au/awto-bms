/// The "Alarm events" section of the battery detail page (#67), merged with
/// the fault / alarm timeline (#123, moved here from the Charts page): a slim
/// band over the Trends window (red where an alarm was active, grey where the
/// pack was offline) and the timestamped list — one row per alarm WINDOW
/// (a bit's set paired with its clear), newest first, with the full local
/// date-time to the millisecond in the raw log's format, the bit name and the
/// measured values / last command at the moment it tripped. The last
/// [AlarmEventsSection.pageSize] events are loaded, with a "Show all" when
/// more exist; Copy puts every loaded event (with its full snapshot) on the
/// clipboard.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'alarm_events.dart';
import 'battery_log.dart' show BatteryLogger, Flags;
import 'fmt.dart';
import 'health_palette.dart';
import 'intervals.dart';
import 'widgets.dart' show kCardMargin, kCardPadding, sectionTitleStyle;

/// #123: what the timeline band draws — the packed `flags` history over the
/// detail page's Trends window, with that window's gap policy.
class FaultTimeline {
  final int fromMs;
  final int toMs;
  final List<ReadingInterval> flags;
  final GapPolicy policy;

  /// The Trends window's label ("24 h"), shown under the band.
  final String windowLabel;

  const FaultTimeline({
    required this.fromMs,
    required this.toMs,
    required this.flags,
    required this.windowLabel,
    this.policy = GapPolicy.continuous,
  });
}

class AlarmEventsSection extends StatelessWidget {
  /// How many rows the section loads before "Show all".
  static const int pageSize = 50;

  final String serial;

  /// The loaded events, NEWEST first.
  final List<AlarmEvent> events;

  /// How many are stored in total (drives "Show all N").
  final int total;
  final bool showingAll;
  final VoidCallback? onShowAll;

  /// Why the load failed (DB error), or null.
  final String? error;

  /// #68: desktop density (halved card padding).
  final bool dense;

  /// #123: the band above the list; null draws no band.
  final FaultTimeline? timeline;

  const AlarmEventsSection({
    super.key,
    required this.serial,
    required this.events,
    required this.total,
    this.showingAll = false,
    this.onShowAll,
    this.error,
    this.dense = false,
    this.timeline,
  });

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(
        ClipboardData(text: alarmEventsCopyText(serial, events)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alarm events copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final more = total > events.length;
    final windows = alarmWindows(events);
    final tl = timeline;
    // #3: compact card; every event is one line, no padding between them.
    return Card(
      margin: kCardMargin,
      child: Padding(
        padding: kCardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Alarm events${total > 0 ? ' ($total)' : ''}',
                      style: sectionTitleStyle(context)),
                ),
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: events.isEmpty ? null : () => _copy(context),
                ),
              ],
            ),
            if (tl != null) ...[
              const SizedBox(height: 2),
              FaultTimelineStrip(timeline: tl, windows: windows),
            ],
            const Divider(height: 5),
            if (error != null)
              Text('Could not load alarm events: $error',
                  style: TextStyle(color: theme.colorScheme.error))
            else if (events.isEmpty)
              const Text('None recorded — every alarm set and clear is '
                  'listed here to the millisecond, with the current, '
                  'voltage, MOS state and the last command at that moment.',
                  style: TextStyle(color: Colors.white70)),
            for (final w in windows)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    w.open ? Icons.warning_amber : Icons.check_circle_outline,
                    size: 16,
                    color: w.open ? Colors.amber : Colors.white54,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: w.snapshotText(),
                      child: Text(w.describe(),
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            if (more && !showingAll && onShowAll != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onShowAll,
                  child: Text('Show all $total'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// #123: the alarm band — a LINEAR strip along the Trends window (never a
/// ring or gauge): red where the logged `flags` had a fault bit set or a
/// listed alarm window was open, grey where the pack was offline (no flags
/// coverage, left unbridged), with the window's ends and a key underneath.
class FaultTimelineStrip extends StatelessWidget {
  final FaultTimeline timeline;
  final List<AlarmWindow> windows;

  const FaultTimelineStrip(
      {super.key, required this.timeline, this.windows = const []});

  @override
  Widget build(BuildContext context) {
    final t = timeline;
    final active = <(int, int)>[
      for (final iv in t.flags)
        if (Flags.faultActive((iv.valueNum ?? 0).toInt()))
          (iv.startMs, iv.endMs),
      for (final w in windows)
        if (w.startMs != null)
          (w.startMs!, w.endMs ?? w.startMs!),
    ];
    final offline = uncoveredGaps(t.flags, t.fromMs, t.toMs,
        gapMs: BatteryLogger.gapMs, policy: t.policy);
    final span = (t.toMs - t.fromMs).toDouble();
    const caption = TextStyle(color: Colors.white54, fontSize: 10);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 14,
          child: CustomPaint(
            size: Size.infinite,
            painter: FaultTimelinePainter(
              fromMs: t.fromMs,
              toMs: t.toMs,
              active: active,
              offline: offline,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Text(span > 0 ? fmtTick(t.fromMs, span) : '', style: caption),
            Expanded(
              child: Text(
                '${t.windowLabel} · red alarm · grey offline',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: caption,
              ),
            ),
            Text(span > 0 ? fmtTick(t.toMs, span) : '', style: caption),
          ],
        ),
      ],
    );
  }
}

/// Paints the band: offline grey first, then active alarms red on top (at
/// least 2 px, so a sub-second alarm stays visible on a 24 h window).
class FaultTimelinePainter extends CustomPainter {
  final int fromMs;
  final int toMs;
  final List<(int, int)> active;
  final List<(int, int)> offline;

  FaultTimelinePainter({
    required this.fromMs,
    required this.toMs,
    required this.active,
    required this.offline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final span = (toMs - fromMs).toDouble();
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF1E2731));
    if (span <= 0) return;

    canvas.save();
    canvas.clipRRect(rrect);

    void band(int start, int end, Color color, {double minW = 0}) {
      if (end < fromMs || start > toMs) return;
      final x0 = ((start - fromMs) / span * size.width).clamp(0, size.width);
      final x1 = ((end - fromMs) / span * size.width).clamp(0, size.width);
      final w = (x1 - x0).clamp(minW, size.width);
      canvas.drawRect(
          Rect.fromLTWH(x0.toDouble(), 0, w.toDouble(), size.height),
          Paint()..color = color);
    }

    for (final (s, e) in offline) {
      band(s, e, const Color(0xFF3A4450));
    }
    for (final (s, e) in active) {
      band(s, e, HealthPalette.faultRed, minW: 2);
    }
    canvas.restore();
  }

  // Value comparison (records compare structurally), not list identity.
  @override
  bool shouldRepaint(FaultTimelinePainter old) =>
      old.fromMs != fromMs ||
      old.toMs != toMs ||
      !listEquals(old.active, active) ||
      !listEquals(old.offline, offline);
}
