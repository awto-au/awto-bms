/// Detail header: a fully LINEAR state-of-charge presentation (no rings or
/// gauges; line graphs only). The three PROMINENT values (issue
/// #16) are the big SOC % (SOC-graded colour, issue #13; a fault overrides to
/// red), the signed Current and the remaining capacity Ah. Beneath the numbers
/// a HORIZONTAL SOC bar and the SOC LINE graph over time (the shared sparkline)
/// show charge level and its recent history. Voltage/power/status stay as small
/// secondary details underneath.
///
/// #68: shared by the phone detail page and the desktop detail pane. [dense]
/// halves the padding, shrinks the figures and puts the status line and the
/// switch badges on ONE line; every value, label and formatter is the same.
library;

import 'package:flutter/material.dart';

import '../alias_store.dart' show displayName;
import '../app_theme.dart';
import '../battery_connection.dart';
import '../battery_log.dart' show ReadingInterval;
import '../battery_manager.dart';
import '../fmt.dart';
import '../health_palette.dart';
import '../intervals.dart' show GapPolicy;
import '../live_indicator.dart';
import '../sparkline.dart';
import '../stale.dart';
import '../widgets.dart';
import 'section_card.dart';

class BatteryHeaderLine extends StatelessWidget {
  final BatteryConnection conn;
  final BatteryManager manager; // #53 / #61 sampling state
  final String? alias; // #44 local custom name
  final List<ReadingInterval> socSeries;
  final int fromMs;
  final int toMs;
  final GapPolicy? policy; // #53
  final bool dense;
  const BatteryHeaderLine({
    super.key,
    required this.conn,
    required this.manager,
    required this.socSeries,
    required this.fromMs,
    required this.toMs,
    this.alias,
    this.policy,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final state = conn.state;
    final profile = conn.profile;
    final dir = ChargeStateStyle.of(effState(state));
    final soc = state.socPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    final cap = state.fullAh;
    final alarm = conn.alarmActive;
    // #65 / #71: same rule as the card — no charge state on the status line
    // while there is no data behind it (silent, waiting, offline); every
    // figure then shows its LAST-KNOWN value in the stale style with ONE
    // "last known · … ago" caption on the switches row.
    final offline = conn.isOffline && !manager.isSampling;
    final stale = stalenessOf(conn,
        sampling: manager.isSampling, nextDueMs: manager.nextSampleDueMs);
    final noData = stale != null;
    // Issue #13: SOC colour is graded; an active fault overrides to red.
    final health = HealthPalette.socOrFault((soc ?? 0).toDouble(), fault: alarm);
    final track = HealthPalette.track(Theme.of(context).brightness);

    // The three prominent values — built ONCE, arranged per density.
    const small = TextStyle(fontSize: 12, color: Colors.white54);
    final socBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          soc == null ? '—' : '$soc',
          style: staleOr(
            noData,
            text: soc == null ? '—' : '$soc',
            TextStyle(
              fontSize: dense ? 32 : 56,
              fontWeight: FontWeight.bold,
              height: 1.0,
              color: health,
            ),
          ),
        ),
        const Text('% SOC', style: small),
      ],
    );
    final currentBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Current', style: small),
        Text(
          fSignedA(conn.signedCurrentOrNull),
          style: staleOr(
              noData,
              text: fSignedA(conn.signedCurrentOrNull),
              TextStyle(
                  fontSize: dense ? 20 : 26,
                  fontWeight: FontWeight.bold,
                  color: dir.color)),
        ),
      ],
    );
    final remainingBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Remaining', style: small),
        Text(
          fAh(state.remainingAh),
          style: staleOr(
              noData,
              text: fAh(state.remainingAh),
              TextStyle(
                  fontSize: dense ? 20 : 26, fontWeight: FontWeight.bold)),
        ),
      ],
    );
    // Secondary details (demoted): voltage, power and status — the ONE status
    // line (#61 / #64 / #65): live dot, charge direction while streaming,
    // "No data · <why>" otherwise, figures last-known in the stale style (#71).
    final statusLine = LiveStatusLine(
      conn: conn,
      dir: dir,
      offline: offline,
      sampling: () => manager.isSampling,
      nextDueMs: () => manager.nextSampleDueMs,
      dotSize: 10,
      gap: 8,
      fontSize: 13,
      trailing: (hasData) => [
        Text('${fV(state.packVoltage)}  ·  ${fW(state.power)}',
            style: staleOr(!hasData,
                const TextStyle(color: Colors.white54, fontSize: 13),
                text: '${fV(state.packVoltage)}  ·  ${fW(state.power)}')),
      ],
    );
    // #58: the two MOSFET switches, each on its own (#71: stale look).
    final badges = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchBadge('Charge', state.chargeMos, fontSize: 13, stale: noData),
        const SizedBox(width: 12),
        SwitchBadge('Output', state.dischargeMos, fontSize: 13, stale: noData),
      ],
    );
    // #71: the header's ONE last-known caption, beside the badges.
    final caption = stale == null ? null : StaleCaption(stale, fontSize: 12);

    // #3: compact gaps (2–4 px) between the header's lines on both layouts.
    return Card(
      margin: kCardMargin,
      child: Padding(
        padding: sectionPadding(dense),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${profile.name}   •   ${displayName(alias, state.serial)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, letterSpacing: 0.2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(cap == null ? '— Ah' : '${cap.toStringAsFixed(0)} Ah',
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 4),
            // The three prominent values, side by side: big SOC % (health
            // colour) + Current + remaining Ah.
            if (dense)
              Wrap(
                spacing: 24,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [socBlock, currentBlock, remainingBlock],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  socBlock,
                  const SizedBox(width: 24),
                  // The other two prominent values: current + remaining Ah.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        currentBlock,
                        const SizedBox(height: 4),
                        remainingBlock,
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            // Horizontal SOC bar (linear fill on a track), coloured like the %
            // (dimmed while the figures are last-known, #71).
            SocBar(
              frac: frac,
              fill: noData ? health.withValues(alpha: 0.45) : health,
              track: track,
              height: dense ? 8 : 14,
              radius: dense ? 4 : 8,
            ),
            const SizedBox(height: 4),
            // SOC LINE graph over time (reuse the shared sparkline).
            Row(
              children: [
                const Text('SOC over time', style: small),
                const Spacer(),
                Text(soc == null ? '—' : '$soc%',
                    style: staleOr(
                        noData,
                        text: soc == null ? '—' : '$soc%',
                        TextStyle(
                            fontSize: 12,
                            color: health,
                            fontWeight: FontWeight.w600))),
              ],
            ),
            const SizedBox(height: 2),
            Sparkline(
              intervals: socSeries,
              fromMs: fromMs,
              toMs: toMs,
              color: health,
              height: dense ? 26 : 44,
              policy: policy,
            ),
            const SizedBox(height: 4),
            // #68 dense: status + switch badges (+ the #71 caption) on ONE
            // line; the phone stacks them.
            if (dense)
              Row(
                children: [
                  Expanded(child: statusLine),
                  const SizedBox(width: 12),
                  badges,
                  if (caption != null) ...[
                    const SizedBox(width: 12),
                    Flexible(child: caption),
                  ],
                ],
              )
            else ...[
              statusLine,
              const SizedBox(height: 2),
              Row(
                children: [
                  badges,
                  if (caption != null) ...[
                    const Spacer(),
                    Flexible(child: caption),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
