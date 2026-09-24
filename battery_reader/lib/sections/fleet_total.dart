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
    final color =
        HealthPalette.socOrFault((soc ?? 0).toDouble(), fault: alarm);
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
    final staleRows = nothingLive && lastKnown != null;
    final stale = staleRows
        ? Staleness(lastDataMs: manager.fleetLastDataMs, now: manager.now)
        : null;
    final net = manager.netPowerW;
    final netText = net == 0
        ? '0 W'
        : '${net.abs().toStringAsFixed(0)} W ${net > 0 ? 'in' : 'out'}';
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];

    // The fleet-total panel lives in a fixed-height Expanded slot (half the home
    // screen). Its row count grows (capacity totals, offline members, aggregates,
    // fleet controls), so it must SCROLL rather than overflow the slot — this was
    // the "BOTTOM OVERFLOWED BY N PIXELS" bar (mis-filed as the #30 "zebra"
    // background). SingleChildScrollView gives it a viewport at any phone height.
    return SingleChildScrollView(
      child: Padding(
      padding: dense
          ? const EdgeInsets.fromLTRB(8, 6, 8, 8)
          : const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.dashboard_customize_outlined, size: 18),
              const SizedBox(width: 8),
              Text('Fleet total · ${pluralBatteries(favs.length)}',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          SizedBox(height: dense ? 6 : 12),
          SocBar(
            frac: frac,
            fill: color,
            track: kTrack,
            height: dense ? 40 : 84,
            radius: dense ? 8 : 16,
            overlayPadding: EdgeInsets.symmetric(horizontal: dense ? 10 : 18),
            overlay: Row(
              children: [
                Text(
                  soc == null ? '—' : '$soc%',
                  style: TextStyle(
                    fontSize: dense ? 20 : 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: shadow,
                  ),
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(netText,
                        style: TextStyle(
                            fontSize: dense ? 13 : 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            shadows: shadow)),
                    Text('${manager.netCurrentA.abs().toStringAsFixed(1)} A',
                        style: TextStyle(
                            fontSize: dense ? 11 : 14,
                            color: Colors.white,
                            shadows: shadow)),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: dense ? 6 : 12),
          KvRow('Status', label, stale: staleRows),
          // #58: how many members have each MOSFET switch on (#71: last-known
          // counts in the stale style while nothing is live).
          if (favs.isNotEmpty)
            KvRow(
                'Switches',
                'Charge ${manager.fleetChargeOnCount}/${favs.length} on  ·  '
                'Output ${manager.fleetOutputOnCount}/${favs.length} on',
                stale: staleRows),
          if (stale != null)
            Align(alignment: Alignment.centerRight, child: StaleCaption(stale)),
          // #36: total battery capacity = sum of every fleet member's fullAh
          // (offline members keep contributing their last-known fullAh, so the
          // total stays stable when a pack drops off), and total remaining Ah.
          KvRow('Total capacity', fAh(manager.totalCapacityAh)),
          KvRow('Total remaining', fAh(manager.totalRemainingAh)),
          // #34: offline members are shown in membership with last-known values
          // but excluded from the live net current/power on the gauge above.
          if (manager.offlineFleetMembers.isNotEmpty)
            KvRow('Offline members',
                '${manager.offlineFleetMembers.length} of ${favs.length} (excluded from live power)'),
          // Issue #31: net current is already shown once on the gauge above, so
          // the redundant "Net current" row is gone.
          // Issue #29: the fleet signal (dBm) row is removed from this panel.
          // #37: LIFETIME totals are always maintained (incrementally, cheaply)
          // and always shown — no toggle. Grouped under their own sub-header so
          // they are not confused with the live "Fleet total" gauge above.
          Divider(height: dense ? 12 : 20),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('Lifetime totals',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white70)),
          ),
          ...() {
            final agg = manager.fleetAggregate;
            return [
              KvRow('Lifetime charged', fAh(agg.chargeAh)),
              KvRow('Lifetime discharged', fAh(agg.dischargeAh)),
              KvRow('Equivalent full cycles', fCycles(agg.efc)),
            ];
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
    final short = action == GateAction.bothMos
        ? 'switches'
        : mosSwitchName(action);
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
                      style: const TextStyle(
                          color: Colors.amber, fontSize: 12)),
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
