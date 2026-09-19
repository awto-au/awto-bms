/// Data-driven write controls (review pass C2, GitHub #51).
///
/// SAFETY: every state-changing write to real hardware goes through ONE
/// executor, [runWriteAction], driven by a [WriteAction] descriptor. Nothing
/// fires on a single tap; the executor owns, in this fixed order:
///
///  1. the confirmation — a single named dialog, or for a DESTRUCTIVE action
///     (one with a [WriteAction.sternWarning]: output OFF, sleep ON, restart,
///     factory reset, fleet output OFF) the two-step confirm whose second page
///     is the stern "Are you sure?";
///  2. the busy hold (M4): the action's [WriteAction.busyKey] is held in the
///     battery's [BusyWrites] from the tap until the read-back completes, and
///     every write button on that battery is disabled meanwhile;
///  3. the send, through [runWrite] (M3): ANY failure — the C1 freshness-gate
///     refusal, the M2 "not connected" refusal, a GATT error — is caught and
///     shown as "Failed: <label> — <reason>", never an unhandled error;
///  4. the "Sent: …" toast (only ever that the frame was sent, never that it
///     took effect on the pack);
///  5. the optional read-back (#24 / #38 / #42): wait for the pack to report
///     the change and, if it does not, the modal warning.
///
/// The descriptors for each control ([outputAction], [gateToggleAction],
/// [sleepAction], [capacityAction], [restartAction], [factoryAction],
/// [fleetOutputAction]) are plain data built from the live connection, so the
/// exact dialog texts and the double-confirm set are unit-tested.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'battery_connection.dart';
import 'battery_manager.dart';
import 'battery_protocol.dart';
import 'fmt.dart';
import 'health_palette.dart';

const _red = HealthPalette.faultRed;

// ===========================================================================
// Dialogs.
// ===========================================================================

/// Single confirmation that names the exact action. Returns true to proceed.
Future<bool> confirmWrite(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool danger = false,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: danger
                  ? FilledButton.styleFrom(backgroundColor: _red)
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

/// Two-step confirm for DESTRUCTIVE actions (turn output/charge MOS off,
/// restart, factory reset): first names the battery + action, then a stern
/// "Are you sure?" that spells out the consequence. Both steps must be accepted.
Future<bool> confirmDangerous(
  BuildContext context, {
  required String title,
  required String message,
  required String sternWarning,
  String confirmLabel = 'Confirm',
}) async {
  final first = await confirmWrite(
    context,
    title: title,
    message: message,
    confirmLabel: 'Continue…',
    danger: true,
  );
  if (!first || !context.mounted) return false;
  return confirmWrite(
    context,
    title: 'Are you sure?',
    message: '⚠  $sternWarning',
    confirmLabel: confirmLabel,
    danger: true,
  );
}

/// Brief confirmation that a write frame was sent (never that it succeeded on
/// the pack — the BMS ack is shown separately in the Gates section).
void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

/// Modal warning (issue #24): a control write was sent but the pack did not
/// report the expected change. More prominent than a toast so it is not missed.
Future<void> warnDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber, color: _red),
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _red),
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

// ===========================================================================
// The send funnel + busy state.
// ===========================================================================

/// M3: the ONE funnel for every user-facing write (output, passive balancing,
/// heater, sleep, capacity, restart, factory reset, fleet output). Runs [op]
/// and catches ANY error — a C1 freshness-gate [StateError], the M2 "not
/// connected" [StateError], an FBP `deviceIsDisconnected`, a WinRT GATT
/// failure, an [ArgumentError] from a frame builder — logs it, and shows
/// "Failed: <label> — <reason>" instead of letting it escape as an unhandled
/// async error. Returns true iff [op] completed, so callers can skip the
/// "Sent:" toast and the read-back on failure.
Future<bool> runWrite(
  BuildContext context,
  String label,
  Future<void> Function() op,
) async {
  try {
    await op();
    return true;
  } catch (e) {
    final reason = writeFailureReason(e);
    // ignore: avoid_print
    print('[WRITE-FAIL] $label: $e');
    if (context.mounted) {
      await warnDialog(context,
          title: 'Write failed', message: 'Failed: $label — $reason');
    }
    return false;
  }
}

/// Human-readable reason for a failed write: the message of a [StateError] /
/// [ArgumentError] (already worded for the user), else the error's text.
/// Pure — unit-tested.
String writeFailureReason(Object e) => switch (e) {
      StateError(:final message) => message,
      ArgumentError(:final message) when message != null => '$message',
      TimeoutException(:final message) when message != null => message,
      _ => '$e',
    };

/// M4: per-action in-flight flags for ONE battery's write controls (or the
/// fleet's), owned by the page and shared by every section that can write.
/// A key is held from the moment the button is tapped (before its confirmation
/// dialog) until the read-back completes, and EVERY write button on that
/// battery is disabled while any key is held: a second gate frame built while
/// the first is still unconfirmed would carry the stale gate base and could
/// undo the first write.
class BusyWrites {
  final Set<String> _keys = {};

  bool get any => _keys.isNotEmpty;
  bool contains(String key) => _keys.contains(key);

  /// The action in flight, for the "Write in progress" note.
  String? get current => _keys.isEmpty ? null : _keys.first;

  /// Hold [key] for the duration of [body]; a re-entrant call for a held key
  /// (a double-tap that beat the disabled repaint) is dropped. [onChanged]
  /// repaints the owner on both edges.
  Future<void> run(
      String key, VoidCallback onChanged, Future<void> Function() body) async {
    if (_keys.contains(key)) return;
    _keys.add(key);
    onChanged();
    try {
      await body();
    } finally {
      _keys.remove(key);
      onChanged();
    }
  }
}

// ===========================================================================
// The descriptor + executor.
// ===========================================================================

/// One user-facing write, as data. See the library note for the sequence the
/// executor runs it through.
class WriteAction {
  /// M4 busy key held for the whole action.
  final String busyKey;

  /// First (or only) confirmation dialog.
  final String title;
  final String message;
  final String confirmLabel;

  /// Red confirm button on a single-step confirm (a two-step confirm is always
  /// red).
  final bool danger;

  /// Non-null => DESTRUCTIVE: two-step confirm whose second page shows this.
  final String? sternWarning;

  /// Names the write in the "Failed: <label> — <reason>" warning (M3).
  final String label;

  /// The write itself (throws on any failure — caught by [runWrite]).
  final Future<void> Function() send;

  /// The "Sent: …" toast once [send] completed, or null for none.
  final String? Function() sentToast;

  /// Optional read-back: completes true once the pack reflects the change,
  /// false on timeout.
  final Future<bool> Function()? readBack;

  /// The modal warning after a failed read-back; a null [warnTitle] means a
  /// failed read-back is silently accepted (sleep ON may drop the link).
  final String? warnTitle;
  final String Function()? warnMessage;

  const WriteAction({
    required this.busyKey,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.label,
    required this.send,
    required this.sentToast,
    this.danger = false,
    this.sternWarning,
    this.readBack,
    this.warnTitle,
    this.warnMessage,
  });

  /// True iff this action needs the two-step confirm.
  bool get dangerous => sternWarning != null;
}

/// THE executor. Confirms (once or twice), sends through [runWrite], toasts,
/// reads back and warns — holding [action]'s busy key in [busy] throughout.
/// Pass `busy: null` ONLY when the caller already holds the key (the capacity
/// control, whose value-entry dialog runs inside the same hold).
Future<void> runWriteAction(
  BuildContext context,
  WriteAction action, {
  required VoidCallback onChanged,
  required BusyWrites? busy,
}) {
  Future<void> body() async {
    final ok = action.dangerous
        ? await confirmDangerous(
            context,
            title: action.title,
            message: action.message,
            sternWarning: action.sternWarning!,
            confirmLabel: action.confirmLabel,
          )
        : await confirmWrite(
            context,
            title: action.title,
            message: action.message,
            confirmLabel: action.confirmLabel,
            danger: action.danger,
          );
    if (!ok || !context.mounted) return;
    final sent = await runWrite(context, action.label, action.send);
    onChanged();
    if (!sent) return;
    final toast = action.sentToast();
    if (toast != null && context.mounted) showToast(context, toast);
    final readBack = action.readBack;
    if (readBack == null) return;
    final applied = await readBack();
    final warnTitle = action.warnTitle;
    if (!applied && warnTitle != null && context.mounted) {
      await warnDialog(context,
          title: warnTitle, message: action.warnMessage!());
      onChanged();
    }
  }

  if (busy == null) return body();
  return busy.run(action.busyKey, onChanged, body);
}

// ===========================================================================
// The controls, as descriptors.
// ===========================================================================

/// Busy keys (M4), one per action.
class WriteKeys {
  static const output = 'output';
  static const passive = 'passive balancing';
  static const heater = 'heater';
  static const sleep = 'sleep';
  static const capacity = 'capacity';
  static const restart = 'restart';
  static const factory = 'factory reset';
  static const fleetOutput = 'fleet output';
}

/// The serial a dialog names (or "this battery" before one is known).
String serialOf(BatteryConnection conn) => conn.state.serial ?? 'this battery';

/// Plain name of a gate action, for the failure label.
String gateActionName(GateAction action) => switch (action) {
      GateAction.output => 'output',
      GateAction.passiveBalance => 'passive balancing',
      GateAction.heatGate => 'heater',
      GateAction.tempControlGate => 'low-temp protection',
      GateAction.smokeGate => 'smoke sensor',
      GateAction.chargeMos => 'charge MOS',
      GateAction.dischargeMos => 'discharge MOS',
      GateAction.restart => 'restart BMS',
      GateAction.factory => 'factory reset',
    };

/// The "Failed: <label>" label for a gate write.
String gateWriteLabel(GateAction action, {required bool on}) =>
    switch (action) {
      GateAction.restart || GateAction.factory => gateActionName(action),
      _ => '${gateActionName(action)} ${on ? 'ON' : 'OFF'}',
    };

/// Issue #26 + #24: the single Output control. Sends the vendor setMos frame
/// ([GateAction.output] — byte[0]=byte[1]=target), then actively READS BACK the
/// streamed BAL_STATUS; if the pack has not reflected the change within ~4 s,
/// warns that the command did not take effect. Turning output OFF is
/// destructive (double-confirm, names the serial); ON is a single confirm.
WriteAction outputAction(BatteryConnection conn, {required bool target}) {
  final serial = serialOf(conn);
  return WriteAction(
    busyKey: WriteKeys.output,
    title: target ? 'Turn output on' : 'Turn output OFF',
    message: 'Turn the output (charge + discharge MOS) ${target ? 'ON' : 'OFF'} '
        'on $serial?',
    sternWarning: target
        ? null
        : 'This cuts $serial\'s output — anything powered by it will lose '
            'power, and it will stop charging.',
    confirmLabel: target ? 'Turn ON' : 'Turn output OFF',
    label: gateWriteLabel(GateAction.output, on: target),
    send: () => conn.sendGateControl(GateAction.output, on: target),
    sentToast: () => 'Sent: output ${target ? 'ON' : 'OFF'} to $serial',
    readBack: () => conn.confirmOutputState(target),
    warnTitle: 'Output not confirmed',
    warnMessage: () => 'Command sent, but $serial still reports output '
        '${conn.isOutputOn ? 'ON' : 'OFF'}. The change may not have taken '
        'effect — check the connection and try again.',
  );
}

/// A single-gate toggle (passive balancing, the #42 heater): flips ONLY its
/// target gate; every other gate keeps its live value. Confirmed with the
/// battery named; [enableNote] is appended when turning ON; an OFF that is
/// [dangerousWhenOff] double-confirms with [offWarning].
WriteAction gateToggleAction(
  BatteryConnection conn, {
  required String label,
  required String busyKey,
  required bool isOn,
  required GateAction action,
  bool dangerousWhenOff = false,
  String? offWarning,
  String? enableNote,
}) {
  final serial = serialOf(conn);
  final target = !isOn;
  final onOff = target ? 'ON' : 'OFF';
  final dangerous = !target && dangerousWhenOff;
  return WriteAction(
    busyKey: busyKey,
    title: dangerous
        ? 'Turn $label OFF'
        : (target ? 'Turn $label on' : 'Turn $label off'),
    message: 'Turn $label $onOff on $serial?'
        '${target && enableNote != null ? '\n\n$enableNote' : ''}',
    sternWarning:
        dangerous ? (offWarning ?? 'This turns $label off on $serial.') : null,
    confirmLabel: dangerous ? 'Turn $label OFF' : 'Turn $onOff',
    danger: !target,
    label: gateWriteLabel(action, on: target),
    send: () => conn.sendGateControl(action, on: target),
    sentToast: () => 'Sent: $label $onOff to $serial',
  );
}

/// #42 sleep mode. Sleep-ON double-confirms and warns that it may drop the BLE
/// link / stop telemetry; wake is a single confirm. Read-back via
/// SLEEP_SET_SUCCESS — a timeout on sleep-ON is expected (the link may drop),
/// so only a failed WAKE raises a warning.
WriteAction sleepAction(BatteryConnection conn, {required bool target}) {
  final serial = serialOf(conn);
  final label = 'sleep ${target ? 'ON' : 'OFF'}';
  return WriteAction(
    busyKey: WriteKeys.sleep,
    title: target ? 'Put BMS to sleep' : 'Wake BMS',
    message: target
        ? 'Put $serial into sleep mode?'
        : 'Wake $serial from sleep mode?',
    sternWarning: target
        ? 'Sleeping the BMS may DROP the BLE link and STOP telemetry from '
            '$serial — you may lose the connection and live data until it '
            'wakes.'
        : null,
    confirmLabel: target ? 'Sleep now' : 'Wake',
    label: label,
    send: () => conn.setSleepMode(target),
    sentToast: () => 'Sent: $label to $serial',
    readBack: () => conn.confirmSleepState(target),
    warnTitle: target ? null : 'Wake not confirmed',
    warnMessage: () => 'Command sent, but $serial did not report waking '
        'within a few seconds. It may still be asleep — check the connection '
        'and try again.',
  );
}

/// #38 rated-capacity write (CMD_BATTERY) of an already-validated [ah].
/// Confirmed (it changes the SOC / estimator basis), sent, then read back
/// against the type-4 ack / updated fullAh; warns if not confirmed within ~4 s.
WriteAction capacityAction(BatteryConnection conn, double ah) {
  final serial = serialOf(conn);
  final label = 'capacity ${ah.toStringAsFixed(0)} Ah';
  return WriteAction(
    busyKey: WriteKeys.capacity,
    title: 'Write rated capacity',
    message: "Set $serial's rated capacity to ${ah.toStringAsFixed(0)} Ah?\n\n"
        'This rewrites the pack’s SOC and remaining-time estimator basis.',
    confirmLabel: 'Write capacity',
    danger: true,
    label: label,
    send: () => conn.writeCapacity(ah),
    sentToast: () => 'Sent: $label to $serial',
    readBack: () => conn.confirmCapacityWrite(ah),
    warnTitle: 'Capacity write not confirmed',
    warnMessage: () => 'Command sent, but $serial did not acknowledge the new '
        'capacity within a few seconds. It may not have taken effect — '
        'check the connection and try again.',
  );
}

/// The ONE Restart-BMS action (double-confirmed, names the serial), shared by
/// the Controls section and the #50 latched over-temp warning card. Refused by
/// the connection unless the gate base is fresh (C1).
WriteAction restartAction(BatteryConnection conn) {
  final serial = serialOf(conn);
  return WriteAction(
    busyKey: WriteKeys.restart,
    title: 'Restart BMS',
    message: 'Restart (reboot) the BMS on $serial?',
    sternWarning:
        'The battery management system on $serial will reboot; output may '
        'drop briefly and the link will reconnect. A restart also CLEARS the '
        'latched over-temperature protection (temp-alarm byte[2]), which '
        'inhibits charging while set.',
    confirmLabel: 'Restart',
    label: gateWriteLabel(GateAction.restart, on: true),
    send: () => conn.sendGateControl(GateAction.restart, on: true),
    sentToast: () => 'Sent: restart to $serial',
  );
}

/// Factory reset — double confirm with a stern warning.
WriteAction factoryAction(BatteryConnection conn) {
  final serial = serialOf(conn);
  return WriteAction(
    busyKey: WriteKeys.factory,
    title: 'Factory reset',
    message: 'FACTORY RESET $serial?',
    sternWarning: 'This erases $serial\'s configuration and restores '
        'factory defaults. It cannot be undone and may cut output. '
        'Only do this if you are certain.',
    confirmLabel: 'Factory reset',
    label: gateWriteLabel(GateAction.factory, on: true),
    send: () => conn.sendGateControl(GateAction.factory, on: true),
    sentToast: () => 'Sent: FACTORY RESET to $serial',
  );
}

/// Fleet-wide output (issue #11 / #26): every member gets the same setMos
/// frame. OFF lists every affected serial and double-confirms. M3: a member
/// that failed after the C1 pre-check is reported by serial in a warning
/// while the others still went through; only an all-OK write toasts.
WriteAction fleetOutputAction(BatteryManager manager, {required bool on}) {
  final serials = [for (final b in manager.fleetMembers) b.state.serial ?? '—'];
  final serialList = serials.join('\n • ');
  final countText = pluralBatteries(serials.length);
  final onOff = on ? 'ON' : 'OFF';
  FleetWriteResult? result;
  return WriteAction(
    busyKey: WriteKeys.fleetOutput,
    title: on ? 'All output ON' : 'ALL output OFF',
    message: 'Turn the discharge MOS (output) $onOff on all $countText in the '
        'fleet?\n\n • $serialList',
    sternWarning: on
        ? null
        : 'This will cut output to every fleet battery '
            '(${serials.join(', ')}); anything powered by them will lose power.',
    confirmLabel: 'Turn ALL output $onOff',
    label: 'fleet output $onOff',
    send: () async {
      result = await manager.fleetSetOutput(on);
    },
    sentToast: () {
      final r = result;
      if (r == null || !r.allOk) return null;
      return 'Sent: output $onOff to ${pluralBatteries(r.succeeded.length)}';
    },
    readBack: () async => result?.allOk ?? true,
    warnTitle: 'Fleet write partly failed',
    warnMessage: () {
      final r = result!;
      return 'Sent output $onOff to ${pluralBatteries(r.succeeded.length)}'
          '${r.succeeded.isEmpty ? '' : ' (${r.succeeded.join(', ')})'}.\n\n'
          'Failed on ${pluralBatteries(r.failed.length)}:\n'
          '${r.failed.entries.map((e) => ' • ${e.key}: ${writeFailureReason(e.value)}').join('\n')}';
    },
  );
}

/// Ask for a capacity (validated 1–1000 Ah) or null on cancel. L7: the text
/// controller is disposed on every exit path.
Future<double?> askCapacity(BuildContext context, BatteryConnection conn) async {
  final serial = serialOf(conn);
  final current = conn.ratedCapacityAh;
  final controller = TextEditingController(
      text: current != null ? current.toStringAsFixed(0) : '');
  try {
    return await showDialog<double>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Set rated capacity'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Enter $serial's rated capacity in amp-hours (1–1000 Ah). "
                  'This changes the pack’s SOC and remaining-time estimator basis.',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Capacity',
                    suffixText: 'Ah',
                    errorText: error,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final v = double.tryParse(controller.text.trim());
                  if (v == null ||
                      !v.isFinite ||
                      v < CapacityWrite.minAh ||
                      v > CapacityWrite.maxAh) {
                    setLocal(
                        () => error = 'Enter a number between 1 and 1000');
                    return;
                  }
                  Navigator.pop(ctx, v);
                },
                child: const Text('Next…'),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    controller.dispose();
  }
}
