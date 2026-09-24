/// The fleet-total panel (combined SOC bar + totals + fleet controls) — the
/// bottom half of the phone list screen and the footer of the desktop left
/// pane (#68). [dense] is the desktop density: halved padding, a shorter bar
/// and smaller figures; the rows, labels and formatters are the same.
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../battery_manager.dart';
import '../battery_protocol.dart';
import '../fmt.dart';
import '../health_palette.dart';
import '../stale.dart';
import '../widgets.dart';
import '../write_actions.dart';

/// Bottom panel: one combined gauge + totals across favourited batteries.
/// Public so the #65 widget tests can pump it for a hand-built fleet.
class FleetTotal extends StatelessWidget {
  final BatteryManager manager;
  final bool dense;
  const FleetTotal({super.key, required this.manager, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final favs = manager.fleetMembers;
    final soc = manager.combinedSocPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    // Issue #21: the fleet bar MIRRORS the batteries. Its fill uses the SAME
    // SOC-graded palette and the SAME thresholds as every per-battery bar —
    // HealthPalette.socOrFault on the combined fleet SOC, with the identical
    // fault-red override (any member in alarm). No separate fleet colour set.
    final alarm = manager.fleetAlarmActive;
    final color = HealthPalette.socOrFault((soc ?? 0).toDouble(), fault: alarm);
    // Direction word ("Charging"/"Idle · no load"/"Discharging") still comes
    // from the net-power state; only the COLOUR is now SOC-graded. #65: the
    // state is derived from STREAMING members only. #71: with none, the
    // Status and switch counts come from every member's LAST-KNOWN values,
    // in the stale style with ONE caption; "No data" only when no member has
    // ever reported a state.
    final fleetState = manager.fleetStreamingState;
    final nothingLive = fleetState == null;
    final lastKnown = nothingLive ? manager.fleetLastKnownState : null;
    final label = fleetState != null
        ? ChargeStateStyle.of(fleetState).label
        : lastKnown != null
            ? ChargeStateStyle.of(lastKnown).label
            : 'No data';
    // #103: ONE shared rule (the manager's) for the stale look, so the phone
    // and the desktop pane agree — it no longer needs a known charge state.
    final staleRows = manager.fleetShowsLastKnown;
    final stale = staleRows
        ? Staleness(lastDataMs: manager.fleetLastDataMs, now: manager.now)
        : null;
    final net = manager.netPowerW;
    final netText = net == 0
        ? '0 W'
        : '${net.abs().toStringAsFixed(0)} W ${net > 0 ? 'in' : 'out'}';
    // #103: the Ah and power figures sit INSIDE the bar on one line —
    // "186.0 / 200.0 Ah  ·  1265 W out  24.4 A" — so Total capacity / Total
    // remaining are no longer rows of their own.
    final full = manager.totalCapacityAh;
    final ahText = full <= 0
        ? '—'
        : '${manager.totalRemainingAh.toStringAsFixed(1)} / ${fAh(full)}';
    // #103: W and A are LIVE-only figures — with nothing live they are
    // hidden, never "0 W  0.0 A".
    final figures = nothingLive
        ? ahText
        : '$ahText  ·  $netText  '
            '${manager.netCurrentA.abs().toStringAsFixed(1)} A';
    final offline = manager.offlineFleetMembers.length;
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];
    const small = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

    // The fleet-total panel lives in a fixed-height Expanded slot (half the home
    // screen). Its row count grows (offline members, aggregates, fleet
    // controls), so it must SCROLL rather than overflow the slot — this was
    // the "BOTTOM OVERFLOWED BY N PIXELS" bar (mis-filed as the #30 "zebra"
    // background). SingleChildScrollView gives it a viewport at any phone height.
    return SingleChildScrollView(
      child: Padding(
        padding: dense
            ? const EdgeInsets.fromLTRB(8, 6, 8, 8)
            : const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.dashboard_customize_outlined, size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('Fleet total · ${pluralBatteries(favs.length)}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            SizedBox(height: dense ? 4 : 8),
            // #103: the SAME bar geometry and type sizes as the per-pack bars
            // (SummaryCard): SOC large on the left, the rest on one line at the
            // right, scaled down (never wrapped, never overflowing) when narrow.
            // #71: with nothing live every figure is last-known — stale style
            // and a dimmed fill, exactly like a silent pack's card.
            SocBar(
              frac: frac,
              fill: staleRows ? color.withValues(alpha: 0.45) : color,
              track: kTrack,
              height: dense ? kSocBarHeightDense : kSocBarHeight,
              radius: dense ? kSocBarRadiusDense : kSocBarRadius,
              overlayPadding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12),
              overlay: Row(
                children: [
                  Text(
                    fPct(soc),
                    key: const Key('fleet-bar-soc'),
                    style: staleOr(
                      staleRows,
                      text: fPct(soc),
                      TextStyle(
                        fontSize: dense ? 15 : 22,
                        fontWeight: FontWeight.bold,
                        color: HealthPalette.onHealth,
                        shadows: shadow,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        figures,
                        key: const Key('fleet-bar-figures'),
                        maxLines: 1,
                        style: staleOr(
                          staleRows,
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
            // #103: Status, Switches (#58) and Offline members (#34) folded
            // into ONE wrapping line under the bar; #71: last-known values in
            // the stale style with the panel's ONE caption at its end.
            // Items are spaced, not dot-separated, so a wrap at phone width
            // never leaves a dangling separator.
            Wrap(
              spacing: 14,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(label,
                    key: const Key('fleet-status'),
                    style: staleOr(staleRows, small, text: label)),
                if (favs.isNotEmpty)
                  Text(
                      'Charge ${manager.fleetChargeOnCount}/${favs.length} on  ·  '
                      'Output ${manager.fleetOutputOnCount}/${favs.length} on',
                      key: const Key('fleet-switches'),
                      style: staleOr(staleRows, small)),
                // #34: offline members keep their last-known Ah in the bar but
                // are excluded from the live W / A.
                if (offline > 0)
                  Tooltip(
                    message: 'Offline members are excluded from live power',
                    child: Text('$offline of ${favs.length} offline',
                        key: const Key('fleet-offline'),
                        style: small.copyWith(color: Colors.white70)),
                  ),
                if (stale != null) StaleCaption(stale),
              ],
            ),
            // Issue #31: net current is shown once, on the bar.
            // Issue #29: the fleet signal (dBm) row is removed from this panel.
            // #37: LIFETIME totals are always maintained (incrementally, cheaply)
            // and always shown — no toggle. #103: one line of their own,
            // headed "Lifetime", so they are not confused with the live bar.
            SizedBox(height: dense ? 4 : 6),
            () {
              final agg = manager.fleetAggregate;
              const lifetimeStyle =
                  TextStyle(fontSize: 12, fontWeight: FontWeight.w600);
              const heading = Text('Lifetime',
                  style: TextStyle(fontSize: 12, color: Colors.white70));
              // #121: until the store has loaded, a neutral "Lifetime …" —
              // never the 0.0 Ah sum of totals not read yet.
              if (!manager.fleetAggregateLoaded) {
                return const Wrap(
                  key: Key('fleet-lifetime'),
                  spacing: 14,
                  children: [
                    heading,
                    Tooltip(
                      message: 'Loading lifetime totals',
                      child: Text('…',
                          key: Key('fleet-lifetime-loading'),
                          style:
                              TextStyle(fontSize: 12, color: Colors.white38)),
                    ),
                  ],
                );
              }
              return Wrap(
                key: const Key('fleet-lifetime'),
                spacing: 14,
                children: [
                  heading,
                  Text('${fAh(agg.chargeAh)} in', style: lifetimeStyle),
                  Text('${fAh(agg.dischargeAh)} out', style: lifetimeStyle),
                  Tooltip(
                    message: 'Lifetime charged in / discharged out, and '
                        'equivalent full cycles',
                    child: Text('${fCycles(agg.efc)} EFC',
                        style: lifetimeStyle),
                  ),
                ],
              );
            }(),
            Divider(height: dense ? 12 : 20),
            FleetControls(manager: manager),
          ],
        ),
      ),
    );
  }
}

/// Fleet-level write controls (issue #11 / #58). "All charge on/off", "All
/// output on/off" and "All switches on/off". Enabled ONLY when every fleet
/// member is currently connected (and, for an OFF, reporting a fresh gate
/// status); otherwise disabled with the reason shown. All actions go through
/// the same confirmation + safety rules as the per-battery controls
/// ([runWriteAction] with [fleetMosAction]), and destructive ones list every
/// affected serial.
class FleetControls extends StatefulWidget {
  final BatteryManager manager;
  const FleetControls({super.key, required this.manager});

  @override
  State<FleetControls> createState() => _FleetControlsState();
}

class _FleetControlsState extends State<FleetControls> {
  /// M4: a fleet write in flight (tap -> confirm -> every member written).
  /// Both buttons are disabled meanwhile so a double-tap cannot overlap two
  /// fleet-wide writes (both share the one fleet busy key).
  final _busy = BusyWrites();

  BatteryManager get manager => widget.manager;

  void _changed() {
    if (mounted) setState(() {});
  }

  /// One OFF (red, outlined) + ON button pair for the switch [action].
  Widget _pair(BuildContext context, GateAction action,
      {required bool offEnabled, required bool onEnabled}) {
    final short =
        action == GateAction.bothMos ? 'switches' : mosSwitchName(action);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.power_settings_new, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: kRed,
                side: const BorderSide(color: kRed),
              ),
              onPressed: !offEnabled
                  ? null
                  : () => runWriteAction(
                        context,
                        fleetMosAction(manager, action: action, on: false),
                        busy: _busy,
                        onChanged: _changed,
                      ),
              label: Text('All $short OFF'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.power, size: 18),
              onPressed: !onEnabled
                  ? null
                  : () => runWriteAction(
                        context,
                        fleetMosAction(manager, action: action, on: true),
                        busy: _busy,
                        onChanged: _changed,
                      ),
              label: Text('All $short ON'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // C1: the fleet switch-OFF buttons are real gate writes — also disabled
    // while any member lacks a fresh BAL_STATUS (the reason names the member).
    final reason = _busy.any
        ? 'Fleet write in progress…'
        : manager.fleetGateWriteDisabledReason;
    final enabled = reason == null;
    // #59: a switch ON cannot turn anything off — every member merely has to
    // be connected. Charge ON, Output ON and Both ON share that rule.
    final onReason = _busy.any
        ? 'Fleet write in progress…'
        : manager.fleetMosWriteDisabledReason(GateAction.dischargeMos,
            on: true);
    final onEnabled = onReason == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.hub_outlined, size: 18),
            const SizedBox(width: 8),
            Text('Fleet controls',
                style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        if (!enabled)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const Icon(Icons.lock_outline, size: 15, color: Colors.amber),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(reason,
                      style:
                          const TextStyle(color: Colors.amber, fontSize: 12)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        // #58: one pair per switch, plus the convenience "all switches".
        _pair(context, GateAction.chargeMos,
            offEnabled: enabled, onEnabled: onEnabled),
        _pair(context, GateAction.dischargeMos,
            offEnabled: enabled, onEnabled: onEnabled),
        _pair(context, GateAction.bothMos,
            offEnabled: enabled, onEnabled: onEnabled),
      ],
    );
  }
}
