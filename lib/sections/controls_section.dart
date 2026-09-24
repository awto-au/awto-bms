/// Per-battery write controls (issues #12, #17). Every button builds a
/// CMD_GATE_CONTROL frame that flips ONLY its target gate (other gates keep
/// their live values) and sends it on FCF1 — always behind a confirmation that
/// names the battery + exact action. Destructive actions require a second
/// "Are you sure?". Individual controls stay available regardless of fleet
/// state. Includes the heat-up (heater) gate, sleep mode (#42) and the rated-
/// capacity write (#38, CMD_BATTERY); each write is confirmed and read back.
/// Sleep-ON, any switch-off, restart and factory reset double-confirm and
/// name the serial. Every control is a [WriteAction] descriptor run by
/// [runWriteAction]. Shared by both layouts (#68); [dense] halves the padding.
/// The firmware update entry (#41) sits here as a red action beside Restart
/// and Factory reset (#118); its page runs the pre-flight checks and the
/// typed-serial confirmation before anything is sent. #91 adds the
/// low-temp protection and smoke sensor gates (OFF double-confirms; both
/// need the fresh gate base and are read back).
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../battery_connection.dart';
import '../battery_protocol.dart';
import '../fmt.dart';
import '../ota_update.dart' show OtaLock;
import '../ota_update_page.dart';
import '../write_actions.dart';
import 'section_card.dart';

bool _neverAwake() => false;

/// Why the firmware update cannot be opened right now, or null when it can:
/// not connected, serial unknown, another update running, or a write in
/// flight on this battery.
String? firmwareUpdateDisabledReason(BatteryConnection conn, BusyWrites busy) {
  final serial = conn.state.serial;
  if (conn.connState != ConnState.connected) return 'Not connected';
  if (serial == null || serial.isEmpty) return 'Serial unknown';
  if (OtaLock.inProgress) return OtaLock.refuseReason;
  if (busy.any) return 'Write in progress (${busy.current})';
  return null;
}

class ControlsSection extends StatelessWidget {
  final BatteryConnection conn;
  final VoidCallback onChanged;

  /// M4: in-flight write flags (shared with the latched over-temp card).
  final BusyWrites busy;

  /// #62: fleet size — more than one member = a parallel bank, and every
  /// switch-OFF stern page carries the sibling-takes-all-current warning.
  final int fleetSize;

  /// Android: is the monitoring foreground service (wake lock) running?
  /// Feeds the firmware update's "Device will stay awake" check.
  final bool Function() keepAwake;
  final bool dense;
  const ControlsSection({
    super.key,
    required this.conn,
    required this.onChanged,
    required this.busy,
    this.fleetSize = 1,
    this.keepAwake = _neverAwake,
    this.dense = false,
  });

  String get _serial => serialOf(conn);

  Future<void> _run(BuildContext context, WriteAction action) =>
      runWriteAction(context, action, busy: busy, onChanged: onChanged);

  /// #58: one MOSFET switch — Charge (charge MOS, byte[0]) or Output
  /// (discharge MOS, byte[1]) — with its own on/off state and a button that
  /// flips ONLY that switch. Turning it OFF is destructive (double-confirm,
  /// names the serial and the switch; needs a fresh status: [gateOk]);
  /// turning it ON is a single confirm and a safe write ([safeOk], #59).
  /// Read-back + warning (issue #24) are part of [mosSwitchAction].
  Widget _switchRow(
    BuildContext context, {
    required GateAction action,
    required bool gateOk,
    required bool safeOk,
  }) {
    final name = mosSwitchName(action); // 'charge' / 'output'
    final label = action == GateAction.chargeMos
        ? 'Charge (charge MOS)'
        : 'Output (discharge MOS)';
    final isOn = conn.mosState(action) ?? false;
    final target = !isOn;
    final enabled = isOn ? gateOk : safeOk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(isOn ? 'On' : 'Off',
              style: TextStyle(
                  color: isOn ? kGreen : kIdle, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            style: (!target)
                ? FilledButton.styleFrom(foregroundColor: kRed)
                : null,
            onPressed: !enabled
                ? null
                : () => _run(
                    context,
                    mosSwitchAction(conn,
                        action: action, target: target, fleetSize: fleetSize)),
            child: Text(target ? 'Turn $name ON' : 'Turn $name OFF'),
          ),
        ],
      ),
    );
  }

  /// #58: the convenience "Both on" / "Both off" (both MOS bytes together —
  /// the vendor setMos of issue #26). OFF needs a fresh status; ON is safe.
  Widget _bothRow(BuildContext context,
      {required bool gateOk, required bool safeOk}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Expanded(child: Text('Both switches')),
          FilledButton.tonal(
            style: FilledButton.styleFrom(foregroundColor: kRed),
            onPressed: !gateOk
                ? null
                : () => _run(context,
                    bothMosAction(conn, target: false, fleetSize: fleetSize)),
            child: const Text('Both OFF'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: !safeOk
                ? null
                : () => _run(context, bothMosAction(conn, target: true)),
            child: const Text('Both ON'),
          ),
        ],
      ),
    );
  }

  /// #38 capacity write. Shows the current rated capacity and lets the user enter
  /// a new value (Ah). Validated (finite, 1–1000), confirmed (it changes the SOC
  /// / estimator basis), sent, then read back against the type-4 ack / updated
  /// fullAh; warns if not confirmed within ~4 s. The busy key is held from the
  /// value-entry dialog onward, so the action runs inside that same hold.
  Widget _capacityRow(BuildContext context, {required bool enabled}) {
    final current = conn.ratedCapacityAh;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Expanded(child: Text('Rated capacity')),
          Text(current == null ? '—' : fAh(current),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            onPressed: !enabled
                ? null
                : () => busy.run(WriteKeys.capacity, onChanged, () async {
                      final entered = await askCapacity(context, conn);
                      if (entered == null || !context.mounted) return;
                      await runWriteAction(
                          context, capacityAction(conn, entered),
                          busy: null, onChanged: onChanged);
                    }),
            child: const Text('Change…'),
          ),
        ],
      ),
    );
  }

  /// #42 sleep mode. Sleep-ON double-confirms and warns that it may drop the BLE
  /// link / stop telemetry; wake is a single confirm (see [sleepAction]).
  /// #42 / #62: Bluetooth standby (power saving) — the vendor's "sleep"
  /// mode. Enabling it double-confirms ([sleepAction]). The row carries the
  /// vendor's explanation; an unknown state reads "—".
  Widget _sleepRow(BuildContext context, {required bool enabled}) {
    final known = conn.state.sleepModeOn;
    final isOn = known ?? false;
    final target = !isOn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Bluetooth standby (power saving)')),
              Text(known == null ? '—' : (isOn ? 'On' : 'Off'),
                  style: TextStyle(
                      color: known == null
                          ? kIdle
                          : (isOn ? kRed : kGreen),
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              FilledButton.tonal(
                style: target
                    ? FilledButton.styleFrom(foregroundColor: kRed)
                    : null,
                onPressed: !enabled
                    ? null
                    : () => _run(context, sleepAction(conn, target: target)),
                child: Text(target ? 'Turn on' : 'Turn off'),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(standbyExplanation,
                style: TextStyle(color: Colors.white38, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  /// A single-gate toggle row (passive balancing, heater, and #91 low-temp
  /// protection / smoke sensor): label, reported state ("—" while unknown)
  /// and one button whose [actionFor] builds the write for the new target.
  /// Turning a gate off is the red button.
  Widget _toggleRow(
    BuildContext context, {
    required String label,
    required bool? state,
    required bool enabled,
    required WriteAction Function(bool target) actionFor,
  }) {
    final isOn = state ?? false;
    final target = !isOn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(state == null ? '—' : (isOn ? 'On' : 'Off'),
              style: TextStyle(
                  color: isOn ? kGreen : kIdle,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          FilledButton.tonal(
            style: (!target)
                ? FilledButton.styleFrom(foregroundColor: kRed)
                : null,
            onPressed:
                !enabled ? null : () => _run(context, actionFor(target)),
            child: Text(target ? 'Turn on' : 'Turn off'),
          ),
        ],
      ),
    );
  }

  /// #118: Firmware update as a red action (styled like Restart BMS /
  /// Factory reset), with the disabled reason or the current version as a
  /// one-line hint beside it. Opens [FirmwareUpdatePage].
  Widget _firmwareRow(BuildContext context) {
    final reason = firmwareUpdateDisabledReason(conn, busy);
    final version = conn.state.firmwareVersion;
    final hint = reason ?? 'Current ${version ?? 'version unknown'}';
    return Row(
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.system_update_alt, size: 18),
          style: OutlinedButton.styleFrom(
            foregroundColor: kRed,
            side: const BorderSide(color: kRed),
          ),
          onPressed: reason != null
              ? null
              : () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FirmwareUpdatePage(
                        conn: conn,
                        busy: busy,
                        keepAwake: () => otaKeepAwakeOk(keepAwake()),
                        keepAwakeDetail: () => otaKeepAwakeDetail(keepAwake()),
                      ),
                    ),
                  );
                  onChanged();
                },
          label: const Text('Firmware update'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // M2: sleep + capacity are NOT gate writes but still need a link — while
    // disconnected they are disabled with the reason, never "Sent:" into the
    // void followed by a "not confirmed" warning that could never be met.
    final writeReason = conn.writesDisabledReason;
    final connected = writeReason == null;
    // C1: the persistent gate toggles (charge / output switch, passive
    // balancing, heater, low-temp protection, smoke sensor) are disabled unless the gate base is fresh —
    // connected, all six gates reported, BAL_STATUS younger than
    // gateFreshnessMs. The reason is shown.
    final gateReason = conn.gateControlsDisabledReason;
    // #59: the SAFE writes (Charge ON, Output ON, Both ON, Restart — they
    // cannot turn anything off) only need a connected link; see
    // BatteryConnection.safeWriteBase.
    final safeReason = conn.safeWritesDisabledReason;
    // M4: while any write on this battery is in flight (tap -> confirm ->
    // read-back), every write button is disabled.
    final inFlight = busy.any;
    final gateOk = gateReason == null && !inFlight;
    final safeOk = safeReason == null && !inFlight;
    final writeOk = connected && !inFlight;
    return Card(
      child: Padding(
        padding: sectionPadding(dense),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.build_circle_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Controls (writes to the battery)',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(),
            if (inFlight)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Write in progress (${busy.current}) — waiting for '
                        '$_serial to confirm…',
                        style: const TextStyle(
                            color: Colors.amber, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )
            else if (!connected)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Not connected — controls are disabled until it reconnects.',
                  style: TextStyle(color: Colors.amber, fontSize: 12),
                ),
              )
            else if (gateReason != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 15, color: Colors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        // #55: automatic, not an approval — see the note.
                        controlsUnavailableText(gateReason,
                            safeWritesAvailable: safeOk),
                        style: const TextStyle(
                            color: Colors.amber, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            // #58: the two independent MOSFET switches — Charge (byte[0]) and
            // Output (byte[1]) — each flipping ONLY its own byte, plus the
            // convenience "Both" (the vendor setMos of issue #26).
            // #59: turning a switch ON is a safe write (connected is enough);
            // turning one OFF keeps the fresh-status gate.
            _switchRow(context,
                action: GateAction.chargeMos, gateOk: gateOk, safeOk: safeOk),
            _switchRow(context,
                action: GateAction.dischargeMos,
                gateOk: gateOk,
                safeOk: safeOk),
            _bothRow(context, gateOk: gateOk, safeOk: safeOk),
            _toggleRow(
              context,
              label: 'Passive balancing',
              state: conn.isPassiveBalancingOn,
              enabled: gateOk,
              actionFor: (target) => gateToggleAction(conn,
                  label: 'Passive balancing',
                  busyKey: WriteKeys.passive,
                  isOn: !target,
                  action: GateAction.passiveBalance),
            ),
            // #42 heat-up: flips ONLY the heat gate (payload[4]); every other gate
            // keeps its cached value. Confirm on enable — it draws power / heats
            // the pack.
            _toggleRow(
              context,
              label: 'Heater',
              state: conn.isHeatOn,
              enabled: gateOk,
              actionFor: (target) => gateToggleAction(conn,
                  label: 'Heater',
                  busyKey: WriteKeys.heater,
                  isOn: !target,
                  action: GateAction.heatGate,
                  enableNote: 'The self-heating element draws power from '
                      'the pack and warms the cells.'),
            ),
            // #91: low-temp protection (byte[2]) and smoke sensor (byte[3]).
            // Each flips ONLY its own byte from the fresh gate base (ON and
            // OFF both need it: without a fresh base the frame could carry
            // stale switch values). OFF disables a protection, so it
            // double-confirms; both are read back from the next BAL_STATUS.
            _toggleRow(
              context,
              label: 'Low-temp protection',
              state: conn.lowTempProtectionOn,
              enabled: gateOk,
              actionFor: (target) =>
                  lowTempProtectionAction(conn, target: target),
            ),
            _toggleRow(
              context,
              label: 'Smoke sensor',
              state: conn.smokeSensorOn,
              enabled: gateOk,
              actionFor: (target) => smokeSensorAction(conn, target: target),
            ),
            const Divider(height: 24),
            // #42 / #62 Bluetooth standby (power saving). Enabling it may
            // stop the BLE link (double-confirmed).
            _sleepRow(context, enabled: writeOk),
            const Divider(height: 24),
            // #38 rated-capacity write (CMD_BATTERY). Changes the SOC / estimator
            // basis; confirmed + read back against the type-4 ack.
            _capacityRow(context, enabled: writeOk),
            const Divider(height: 24),
            // Restart BMS. The two former buttons ("Restart BMS" and the
            // experimental "Restart (clear-alarm test)") sent the IDENTICAL
            // restart gate and are now merged into this one (shared with the
            // #50 latched over-temp warning card via [restartAction]).
            OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: kRed,
                side: const BorderSide(color: kRed),
              ),
              onPressed: !safeOk
                  ? null
                  : () => _run(context, restartAction(conn)),
              label: const Text('Restart BMS'),
            ),
            const Divider(height: 24),
            // Factory reset — double confirm with a stern warning.
            OutlinedButton.icon(
              icon: const Icon(Icons.warning_amber, size: 18),
              style: OutlinedButton.styleFrom(
                foregroundColor: kRed,
                side: const BorderSide(color: kRed, width: 2),
              ),
              // Factory reset erases configuration: it keeps the fresh gate.
              onPressed: !gateOk
                  ? null
                  : () => _run(context, factoryAction(conn)),
              label: const Text('Factory reset'),
            ),
            const SizedBox(height: 8),
            // #41 / #118: firmware update — red like the two above; the page
            // keeps the pre-flight checks and the typed-serial confirmation.
            _firmwareRow(context),
          ],
        ),
      ),
    );
  }
}
