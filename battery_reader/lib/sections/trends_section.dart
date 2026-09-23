/// The per-row sparklines section (issue #14) with its window selector and
/// the #69 logging line. Shared by the phone detail page and the desktop
/// detail pane (#68); [dense] halves the card padding.
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../battery_connection.dart';
import '../battery_log.dart' show ReadingInterval, sampleLegendText;
import '../intervals.dart' show GapPolicy, LookbackWindow;
import '../metrics.dart';
import '../sparkline.dart';

/// One shared period selector drives every row; each row shows its metric's
/// recent history as an alpha-blended held/step sparkline with the ACTUAL
/// current value large beside it. Which rows, in which order and colour, comes
/// from the metric catalogue.
class TrendsSection extends StatelessWidget {
  final LookbackWindow window;
  final ValueChanged<LookbackWindow> onWindow;
  final Map<String, List<ReadingInterval>> series;
  final int fromMs;
  final int toMs;
  final BatteryConnection conn;

  /// M6: the last history-load error, or null.
  final String? error;

  /// #53: the sample-interval gap policy for this window.
  final GapPolicy? policy;

  /// #69: the one-line logging status ([loggingStatusLine]).
  final String logging;
  final bool dense;

  const TrendsSection({
    super.key,
    required this.window,
    required this.onWindow,
    required this.series,
    required this.fromMs,
    required this.toMs,
    required this.conn,
    required this.logging,
    this.error,
    this.policy,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: dense
            ? const EdgeInsets.fromLTRB(8, 6, 8, 6)
            : const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.timeline, size: 18),
                const SizedBox(width: 8),
                Text('Trends', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                const Text('window',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<LookbackWindow>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  for (final w in LookbackWindow.values)
                    ButtonSegment(value: w, label: Text(w.label)),
                ],
                selected: {window},
                showSelectedIcon: false,
                onSelectionChanged: (sel) => onWindow(sel.first),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 15, color: kRed),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text("Couldn't load history — $error",
                          style: const TextStyle(color: kRed, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2),
                    ),
                  ],
                ),
              ),
            // #69: the logging status + line-style legend live HERE, on the
            // detail page, not on the Charts page.
            LoggingLine(
              text: logging,
              legend: policy?.hasBackground ?? false,
            ),
            const Divider(height: 20),
            for (final m in sparkMetrics)
              SparkRow(
                label: m.label,
                value: m.format(conn),
                intervals: series[m.key] ?? const [],
                fromMs: fromMs,
                toMs: toMs,
                color: m.sparkColorFor(conn),
                centreZero: m.centreZero,
                policy: policy,
              ),
          ],
        ),
      ),
    );
  }
}

/// #69: the small "Logging" line under the Trends window selector: the
/// logger's state / mode / row count for the window ([loggingStatusLine]) and,
/// while the window holds background samples, the dotted / dashed legend
/// ([sampleLegendText]) that the sparklines and charts share.
class LoggingLine extends StatelessWidget {
  final String text;
  final bool legend;
  const LoggingLine({super.key, required this.text, this.legend = false});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white38, fontSize: 11);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.storage, size: 12, color: Colors.white38),
              ),
              const SizedBox(width: 5),
              Expanded(child: Text(text, style: style)),
            ],
          ),
          if (legend)
            const Padding(
              padding: EdgeInsets.only(top: 2, left: 17),
              child: Text(sampleLegendText, style: style),
            ),
        ],
      ),
    );
  }
}

/// One trend row: label, an inline sparkline (expanded), and the actual current
/// value large/clear with units on the right.
class SparkRow extends StatelessWidget {
  final String label;
  final String value;
  final List<ReadingInterval> intervals;
  final int fromMs;
  final int toMs;
  final Color color;
  final bool centreZero;
  final GapPolicy? policy; // #53

  const SparkRow({
    super.key,
    required this.label,
    required this.value,
    required this.intervals,
    required this.fromMs,
    required this.toMs,
    required this.color,
    this.centreZero = false,
    this.policy,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          Expanded(
            child: Sparkline(
              intervals: intervals,
              fromMs: fromMs,
              toMs: toMs,
              color: color,
              centreZero: centreZero,
              policy: policy,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 96,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
