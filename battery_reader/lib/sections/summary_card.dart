/// One row in the battery list (#68: shared by the phone list and the desktop
/// left pane). [dense] is the desktop density — halved padding, a shorter SOC
/// bar and smaller figures; [selected] tints the row that is open in the
/// desktop right pane. With both false the card is the phone card, unchanged.
library;

import 'package:flutter/material.dart';

import '../alias_store.dart' show displayName;
import '../app_theme.dart';
import '../battery_connection.dart';
import '../battery_manager.dart';
import '../fmt.dart';
import '../health_palette.dart';
import '../live_indicator.dart';
import '../stale.dart';
import '../widgets.dart';
import 'signal_chip.dart';

/// One row in the list: serial, a compact SOC bar with figures, a fleet
/// (add/remove) star, tappable to open the detail page. Public so the #65
/// widget tests can pump a card for a hand-built connection.
class SummaryCard extends StatelessWidget {
  final BatteryConnection conn;
  /// #53 / #61: sampling state for the live indicator.
  final BatteryManager manager;
  final VoidCallback onTap;
  final VoidCallback onToggleFleet;
  /// #44: local custom name (null = show the bare serial).
  final String? alias;
  /// #44: opens the rename dialog; null when the pack has no serial yet.
  final VoidCallback? onEditAlias;
  /// #68: desktop density (halved padding, smaller bar and figures).
  final bool dense;
  /// #68: the row currently shown in the desktop detail pane.
  final bool selected;
  const SummaryCard({
    super.key,
    required this.conn,
    required this.manager,
    required this.onTap,
    required this.onToggleFleet,
    this.alias,
    this.onEditAlias,
    this.dense = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = conn.state;
    final dir = ChargeStateStyle.of(effState(s));
    final soc = s.socPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    final alarm = conn.alarmActive;
    // #34: an offline favourite placeholder — show its last-known SOC dimmed
    // and labelled "Offline · last seen …", never as a live/alarm card.
    // #53: a pack released between background samples is NOT offline.
    final offline = conn.isOffline && !manager.isSampling;
    // #65 / #71: no data behind the screen (silent / dormant / waiting /
    // offline): the status line reads "No data · …" / "Offline · …" and the
    // figures show the LAST-KNOWN values in the stale style (red, dimmed,
    // tabular) with ONE "last known · … ago" caption on the switches row.
    // Never-known values still read "—". The SOC bar's fill is dimmed.
    final stale = stalenessOf(conn,
        sampling: manager.isSampling, nextDueMs: manager.nextSampleDueMs);
    final noData = stale != null;
    final track = HealthPalette.track(Theme.of(context).brightness);
    // Issue #13: SOC-graded fill / identity accent; a fault overrides to red.
    final health = HealthPalette.socOrFault((soc ?? 0).toDouble(), fault: alarm);
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];
    // #68: the selected-row tint (desktop only; an alarm card keeps its red).
    final Color? cardColor = alarm
        ? const Color(0xFF3A1414)
        : selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: cardColor,
      shape: alarm
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: kRed, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Identity accent (issue #13): a SOC-graded left edge on the card.
              Container(width: 5, color: health),
              Expanded(
                child: Padding(
                  padding: dense
                      ? const EdgeInsets.fromLTRB(6, 4, 2, 5)
                      : const EdgeInsets.fromLTRB(12, 8, 4, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            // #44: long-press the name to rename the pack.
                            child: GestureDetector(
                              onLongPress: onEditAlias,
                              child: Text(
                                '${conn.profile.name}   •   ${displayName(alias, s.serial)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          // #44: explicit rename affordance beside the name.
                          if (onEditAlias != null)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Rename',
                              icon: const Icon(Icons.edit,
                                  size: 16, color: Colors.white38),
                              onPressed: onEditAlias,
                            ),
                          // RSSI/signal chip on the per-battery list card
                          // (restored). Offline placeholders have no live signal.
                          if (!offline)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: SignalChip(s.rssi),
                            ),
                          if (alarm)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.error, color: kRed, size: 20),
                            ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: conn.inFleet
                                ? 'Remove from fleet'
                                : 'Add to fleet',
                            icon: Icon(
                              conn.inFleet ? Icons.star : Icons.star_border,
                              color:
                                  conn.inFleet ? Colors.amber : Colors.white38,
                            ),
                            onPressed: onToggleFleet,
                          ),
                        ],
                      ),
                      if (alarm && conn.alarmReasons.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2, bottom: 2),
                          child: Text(
                            conn.alarmReasons.last,
                            style: const TextStyle(
                                color: kRed,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      // #50: latched over-temperature protection — a WARNING
                      // (amber), not a live fault. Cleared by a BMS restart.
                      if (!offline && s.overTempLatched)
                        const Padding(
                          padding: EdgeInsets.only(top: 2, bottom: 2),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber,
                                  size: 14, color: Colors.amber),
                              SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  'Over-temp protection latched — charging may '
                                  'be inhibited. Restart BMS to clear.',
                                  style: TextStyle(
                                      color: Colors.amber,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 2),
                      // Prominent (issue #16): SOC %, signed current, remaining
                      // Ah. Voltage is demoted to the small line below. With no
                      // data (#34 offline, #65 silent, #71) the bar is dimmed
                      // and the figures are last-known, in the stale style.
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      SocBar(
                        frac: frac,
                        fill: noData ? health.withValues(alpha: 0.45) : health,
                        track: track,
                        height: dense ? 26 : 46,
                        radius: dense ? 7 : 12,
                        overlayPadding: EdgeInsets.symmetric(
                            horizontal: dense ? 8 : 12),
                        overlay: Row(
                          children: [
                            // SOC, current and remaining Ah on ONE line
                            // (#28 fix): "93%  ·  -12.3 A out  ·  87 Ah".
                            Text(
                              fPct(soc),
                              style: staleOr(
                                noData,
                                text: fPct(soc),
                                TextStyle(
                                  fontSize: dense ? 15 : 22,
                                  fontWeight: FontWeight.bold,
                                  color: HealthPalette.onHealth,
                                  shadows: shadow,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  '${fSignedA(conn.signedCurrentOrNull)}  ·  ${fAh(s.remainingAh)}',
                                  maxLines: 1,
                                  style: staleOr(
                                    noData,
                                    text:
                                        '${fSignedA(conn.signedCurrentOrNull)}  ·  ${fAh(s.remainingAh)}',
                                    TextStyle(
                                      fontSize: dense ? 12 : 16,
                                      fontWeight: FontWeight.w700,
                                      color: HealthPalette.onHealth,
                                      shadows: shadow,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: dense ? 2 : 4),
                      // Issue #28: the real numeric values, readable at a glance
                      // with units — pack voltage and signed current sit on their
                      // own line (SOC % is the big number in the bar above).
                      // #61 / #64 / #65: the ONE status line — its dot is the
                      // live dot (green blinking per cycle, amber stale, red
                      // silent), its text the charge direction while data
                      // flows and "No data · <why>" / "Offline · last seen …"
                      // when it does not; the figures are then last-known,
                      // in the stale style (#71).
                      LiveStatusLine(
                        conn: conn,
                        dir: dir,
                        offline: offline,
                        sampling: () => manager.isSampling,
                        nextDueMs: () => manager.nextSampleDueMs,
                        dotSize: 8,
                        gap: 6,
                        fontSize: 12,
                        trailing: (hasData) => [
                          Text(fV(s.packVoltage),
                              style: staleOr(
                                  !hasData,
                                  text: fV(s.packVoltage),
                                  TextStyle(
                                      color: Colors.white,
                                      fontSize: dense ? 12 : 14,
                                      fontWeight: FontWeight.w600))),
                          const Text('  ·  ',
                              style: TextStyle(color: Colors.white38)),
                          Text(fSignedA(conn.signedCurrentOrNull),
                              style: staleOr(
                                  !hasData,
                                  text: fSignedA(conn.signedCurrentOrNull),
                                  TextStyle(
                                      color: dir.color,
                                      fontSize: dense ? 12 : 14,
                                      fontWeight: FontWeight.w600))),
                        ],
                      ),
                      SizedBox(height: dense ? 1 : 3),
                      // #58: the two MOSFET switches, each on its own; #71:
                      // stale look + the card's ONE last-known caption.
                      Row(
                        children: [
                          SwitchBadge('Charge', s.chargeMos, stale: noData),
                          const SizedBox(width: 10),
                          SwitchBadge('Output', s.dischargeMos, stale: noData),
                          if (stale != null) ...[
                            const Spacer(),
                            Flexible(child: StaleCaption(stale)),
                          ],
                        ],
                      ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
