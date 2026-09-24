/// #110: the compact one-line row for a known battery that is offline and not
/// in the fleet, the group headings of the battery list, and the "Forget
/// battery" confirmation. Shared by the phone list and the desktop left pane.
library;

import 'package:flutter/material.dart';

import '../alias_store.dart' show displayName;
import '../app_theme.dart';
import '../battery_connection.dart';
import '../fmt.dart';

/// One line: star, name, last-known SOC and remaining Ah in the stale style,
/// how long ago it was last seen, and a menu (Rename, Forget battery…).
/// Tapping opens the battery like a full card does.
class KnownBatteryRow extends StatelessWidget {
  final BatteryConnection conn;
  final String? alias;
  final VoidCallback onTap;
  final VoidCallback onToggleFleet;

  /// Opens the rename dialog; null when the pack has no serial.
  final VoidCallback? onEditAlias;

  /// Asks to forget the battery; null (with [forgetDisabledReason]) when it
  /// cannot be forgotten right now.
  final VoidCallback? onForget;
  final String? forgetDisabledReason;

  /// Desktop density.
  final bool dense;

  /// The row open in the desktop detail pane.
  final bool selected;

  /// Clock for the last-seen age (tests pass a fixed one).
  final int? nowMs;

  const KnownBatteryRow({
    super.key,
    required this.conn,
    required this.onTap,
    required this.onToggleFleet,
    this.alias,
    this.onEditAlias,
    this.onForget,
    this.forgetDisabledReason,
    this.dense = false,
    this.selected = false,
    this.nowMs,
  });

  @override
  Widget build(BuildContext context) {
    final s = conn.state;
    final figures = '${fPct(s.socPercent)}  ·  ${fAh(s.remainingAh)}';
    final seenMs = conn.lastSeenMs ?? conn.lastDataMs;
    final now = nowMs ?? conn.now().millisecondsSinceEpoch;
    final age = seenMs == null ? null : fmtAgeShort(now - seenMs);
    final fs = dense ? 12.0 : 13.0;
    const button = BoxConstraints.tightFor(width: 30, height: 30);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 1 : 2),
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: dense ? 30 : 36,
            child: Row(
              children: [
                IconButton(
                  constraints: button,
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  tooltip: conn.inFleet ? 'Remove from fleet' : 'Add to fleet',
                  icon: Icon(
                    conn.inFleet ? Icons.star : Icons.star_border,
                    color: conn.inFleet ? Colors.amber : Colors.white38,
                  ),
                  onPressed: onToggleFleet,
                ),
                Expanded(
                  child: GestureDetector(
                    onLongPress: onEditAlias,
                    child: Text(
                      displayName(alias, s.serial),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: fs,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  figures,
                  maxLines: 1,
                  style: staleOr(
                      true,
                      text: figures,
                      TextStyle(fontSize: fs, fontWeight: FontWeight.w700)),
                ),
                if (age != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: 'Offline · last seen $age ago',
                      child: Text(
                        age,
                        maxLines: 1,
                        style:
                            TextStyle(fontSize: fs - 2, color: Colors.white38),
                      ),
                    ),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 180),
                  icon: const Icon(Icons.more_vert,
                      size: 18, color: Colors.white38),
                  iconSize: 18,
                  style: IconButton.styleFrom(
                      minimumSize: const Size(30, 30),
                      fixedSize: const Size(30, 30),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onSelected: (v) {
                    if (v == 'rename') onEditAlias?.call();
                    if (v == 'forget') onForget?.call();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'rename',
                      enabled: onEditAlias != null,
                      child: const Text('Rename'),
                    ),
                    PopupMenuItem(
                      value: 'forget',
                      enabled: onForget != null,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Forget battery…'),
                        subtitle: forgetDisabledReason == null
                            ? null
                            : Text(forgetDisabledReason!),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small heading above one group of the battery list ("Fleet · 2").
class ListGroupHeading extends StatelessWidget {
  final String label;
  final int count;
  final bool dense;
  const ListGroupHeading(this.label, this.count,
      {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(6, dense ? 4 : 6, 6, dense ? 1 : 2),
        child: Text(
          '${label.toUpperCase()} · $count',
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Colors.white54),
        ),
      );
}

/// The "Forget battery" confirmation. True = the user chose Forget. The
/// default (and only) choice keeps every stored reading: the row is hidden
/// and the battery leaves the fleet.
Future<bool> confirmForgetBattery(BuildContext context, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Forget $name?'),
      content: const Text(
          'The battery is hidden from the list and leaves the fleet.\n\n'
          'Its history is kept: every stored reading, its charts, lifetime '
          'totals and exports stay as they are.\n\n'
          'It comes back if it is found again.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Forget'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
