/// Data-driven write controls (review pass C2, GitHub #51).
///
/// SAFETY: every state-changing write to real hardware goes through ONE
/// executor, [runWriteAction], driven by a [WriteAction] descriptor. Nothing
/// fires on a single tap; the executor owns, in this fixed order:
///
///  1. the confirmation — a single named dialog, or for a DESTRUCTIVE action
///     (one with a [WriteAction.sternWarning]: charge / output / both OFF,
///     sleep ON, restart, factory reset, fleet charge / output / both OFF,
///     low-temp protection / smoke sensor OFF (#91))
///     the two-step confirm whose second page is the stern "Are you sure?";
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
/// The descriptors for each control ([mosSwitchAction] — [chargeAction],
/// [outputAction], [bothMosAction] — [gateToggleAction], [sleepAction],
/// [capacityAction], [restartAction], [factoryAction], [fleetMosAction]) are
/// plain data built from the live connection, so the exact dialog texts and
/// the double-confirm set are unit-tested.
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

/// Two-step confirm for DESTRUCTIVE actions (turn the charge / output switch
/// off, restart, factory reset): first names the battery + action, then a stern
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

/// M3: the ONE funnel for every user-facing write (charge / output switch,
/// passive balancing, heater, sleep, capacity, restart, factory reset, fleet
/// switches). Runs [op]
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
    logLine('WRITE-FAIL', '$label: $e');
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

  /// #54: app-wide number of writes in flight across every [BusyWrites]
  /// (each detail page has its own), so Exit can ask before cutting one off.
  static int inFlight = 0;

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
    inFlight++;
    onChanged();
    try {
      await body();
    } finally {
      _keys.remove(key);
      inFlight--;
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
  /// #58: the Output switch (discharge MOS) — the former single "output".
  static const output = 'output';

  /// #58: the Charge switch (charge MOS).
  static const charge = 'charge';

  /// #58: "Both on / off" (both MOS bytes together).
  static const bothMos = 'charge + output';
  static const passive = 'passive balancing';
  static const heater = 'heater';

  /// #91: the low-temp protection and smoke sensor gate toggles.
  static const lowTemp = 'low-temp protection';
  static const smoke = 'smoke sensor';
  static const sleep = 'sleep';
  static const capacity = 'capacity';
  static const restart = 'restart';
  static const factory = 'factory reset';
  static const fleetOutput = 'fleet output';
  static const fleetCharge = 'fleet charge';
  static const fleetBothMos = 'fleet charge + output';

  /// #62 recovery ladder: re-send wake / reconnect (switches-on shares the
  /// both-MOS key).
  static const wake = 'wake';
  static const reconnect = 'reconnect';

  /// The per-battery busy key for a MOS switch action.
  static String forMos(GateAction action) => switch (action) {
        GateAction.chargeMos => charge,
        GateAction.dischargeMos => output,
        _ => bothMos,
      };

  /// The fleet busy key for a MOS switch action.
  static String forFleetMos(GateAction action) => switch (action) {
        GateAction.chargeMos => fleetCharge,
        GateAction.dischargeMos => fleetOutput,
        _ => fleetBothMos,
      };
}

/// The serial a dialog names (or "this battery" before one is known).
String serialOf(BatteryConnection conn) => conn.state.serial ?? 'this battery';

/// Plain name of a gate action, for the failure label. #58: the MOS switches
/// are "charge", "output" and "charge + output" ([mosSwitchName]).
String gateActionName(GateAction action) => switch (action) {
      GateAction.chargeMos ||
      GateAction.dischargeMos ||
      GateAction.bothMos =>
        mosSwitchName(action),
      GateAction.passiveBalance => 'passive balancing',
      GateAction.heatGate => 'heater',
      GateAction.tempControlGate => 'low-temp protection',
      GateAction.smokeGate => 'smoke sensor',
      GateAction.restart => 'restart BMS',
      GateAction.factory => 'factory reset',
    };

/// #58: the capitalised display label of a MOS switch: "Charge", "Output",
/// "Both".
String mosSwitchLabel(GateAction action) => switch (action) {
      GateAction.chargeMos => 'Charge',
      GateAction.dischargeMos => 'Output',
      _ => 'Both',
    };

/// The "Failed: <label>" label for a gate write.
String gateWriteLabel(GateAction action, {required bool on}) =>
    switch (action) {
      GateAction.restart || GateAction.factory => gateActionName(action),
      _ => '${gateActionName(action)} ${on ? 'ON' : 'OFF'}',
    };

/// #58 (+ #24): a MOS switch control — the Charge switch
/// ([GateAction.chargeMos], byte[0]), the Output switch
/// ([GateAction.dischargeMos], byte[1]) or Both ([GateAction.bothMos], the
/// vendor setMos of issue #26). Sends the frame that flips ONLY that switch
/// (other gates from the fresh status base), then actively READS BACK the
/// streamed BAL_STATUS for THAT switch; if the pack has not reflected the
/// change within ~4 s, warns that the command did not take effect. Turning a
/// switch OFF is destructive (double-confirm, names the serial and the
/// switch); ON is a single confirm and a safe write (#59).
WriteAction mosSwitchAction(BatteryConnection conn,
    {required GateAction action, required bool target, int fleetSize = 1}) {
  assert(isMosAction(action));
  final serial = serialOf(conn);
  final name = mosSwitchName(action); // charge / output / charge + output
  final onOff = target ? 'ON' : 'OFF';
  final what = switch (action) {
    GateAction.chargeMos => 'the charge switch (charge MOS)',
    GateAction.dischargeMos => 'the output switch (discharge MOS)',
    _ => 'both switches (charge + output)',
  };
  final consequence = switch (action) {
    GateAction.chargeMos => 'This stops $serial charging — no current can '
        'flow into the pack until charge is turned back on.',
    GateAction.dischargeMos => 'This cuts $serial\'s output — anything '
        'powered by it will lose power.',
    _ => 'This cuts $serial\'s output — anything powered by it will lose '
        'power — and it will stop charging.',
  };
  final short = action == GateAction.bothMos ? 'both' : name;
  // #62: a switch-off turns Bluetooth standby OFF first when it is ON or
  // unknown; the stern page says so — and, in a parallel bank (more than one
  // pack in the fleet), why the sibling makes standby unwakeable.
  final standby = target
      ? ''
      : '${standbyOffNote(conn, action)}${parallelBankNote(fleetSize)}';
  String reported() => switch (action) {
        GateAction.chargeMos => 'charge ${conn.isChargeOn ? 'ON' : 'OFF'}',
        GateAction.dischargeMos => 'output ${conn.isOutputOn ? 'ON' : 'OFF'}',
        _ => 'charge ${conn.isChargeOn ? 'ON' : 'OFF'}, '
            'output ${conn.isOutputOn ? 'ON' : 'OFF'}',
      };
  return WriteAction(
    busyKey: WriteKeys.forMos(action),
    title: target ? 'Turn $short on' : 'Turn $short OFF',
    message: 'Turn $what $onOff on $serial?'
        '${target ? noFreshBaseNote(conn, action) : ''}',
    sternWarning: target ? null : '$consequence$standby',
    confirmLabel: target ? 'Turn ON' : 'Turn $short OFF',
    label: gateWriteLabel(action, on: target),
    send: () => target
        ? conn.sendGateControl(action, on: true)
        : conn.turnSwitchOff(action),
    sentToast: () => 'Sent: $name $onOff to $serial',
    readBack: () => conn.confirmMosState(action, target),
    warnTitle: action == GateAction.bothMos
        ? 'Switches not confirmed'
        : '${mosSwitchLabel(action)} not confirmed',
    warnMessage: () => 'Command sent, but $serial still reports '
        '${reported()}. The change may not have taken effect — check the '
        'connection and try again.',
  );
}

/// #62: the sentence a switch-off confirmation carries when the pack's
/// Bluetooth standby is ON — the dormancy risk and that standby is turned
/// OFF first. Exact wording is pinned by tests.
const String standbyDormancyWarning =
    'With the output off this pack cannot pass current, so if it enters '
    'Bluetooth standby it cannot be woken by the app, a charger or a load '
    'until it is physically isolated. Standby will be turned OFF first.';

/// #62: the Charge-OFF variant — only charge current is blocked, so a load
/// can still wake it, but a charger and the app cannot.
const String standbyDormancyWarningCharge =
    'With charge off this pack cannot take charge current, so if it enters '
    'Bluetooth standby it cannot be woken by the app or a charger — only by '
    'a load — until it is physically isolated. Standby will be turned OFF '
    'first.';

/// #62: appended to a switch-off stern warning when
/// [BatteryConnection.needsStandbyOffFirst] — standby ON, or unknown (then
/// standby-OFF is sent anyway and the note says the state is not known).
String standbyOffNote(BatteryConnection conn, GateAction action) {
  if (!conn.needsStandbyOffFirst) return '';
  final unknown = conn.state.sleepModeOn == null;
  final text = action == GateAction.chargeMos
      ? standbyDormancyWarningCharge
      : standbyDormancyWarning;
  return '\n\n${unknown ? "This pack's Bluetooth standby state is not known. " : ''}'
      '$text';
}

/// #62: the vendor's explanation of Bluetooth standby (power saving), shown
/// when enabling it and on its row.
const String standbyExplanation =
    'When ON, the BMS stops its Bluetooth comms when it sees no '
    'charge/discharge current; current wakes it; to turn it off you must '
    'apply charge or a load first.';

/// #62: the parallel-bank hazard (live, 2026-09-20: the two packs are
/// permanently paralleled; the sibling took every amp, so the switched-off
/// pack never saw wake current). Exact wording is pinned by tests.
const String parallelBankWarning =
    'In a parallel bank the other pack carries all current, so this pack '
    'cannot see charge current to wake if it enters standby.';

/// #62: appended to a switch-OFF stern page when the fleet has more than one
/// member ([fleetSize] > 1); empty otherwise.
String parallelBankNote(int fleetSize) =>
    fleetSize > 1 ? '\n\n$parallelBankWarning' : '';

/// #58: the Charge switch (charge MOS, byte[0]).
WriteAction chargeAction(BatteryConnection conn,
        {required bool target, int fleetSize = 1}) =>
    mosSwitchAction(conn,
        action: GateAction.chargeMos, target: target, fleetSize: fleetSize);

/// #58: the Output switch (discharge MOS, byte[1]) — the former single
/// "Output" control.
WriteAction outputAction(BatteryConnection conn,
        {required bool target, int fleetSize = 1}) =>
    mosSwitchAction(conn,
        action: GateAction.dischargeMos,
        target: target,
        fleetSize: fleetSize);

/// #58: the convenience "Both on / Both off" (both MOS bytes together).
WriteAction bothMosAction(BatteryConnection conn,
        {required bool target, int fleetSize = 1}) =>
    mosSwitchAction(conn,
        action: GateAction.bothMos, target: target, fleetSize: fleetSize);

// ===========================================================================
// #62 recovery ladder for a connected pack that is not streaming. Every
// step is user-initiated (confirmed, never silent — unlike the vendor app's
// forced-on on every screen change) and reports whether the stream resumed.
// ===========================================================================

/// Why the stream did not resume, for the ladder's warning: the dormant
/// message when the probe said the BMS is not running (dormant OR no reply,
/// #63), else what to try next.
String notStreamingAdvice(BatteryConnection conn, {required String tried}) {
  final serial = serialOf(conn);
  if (conn.bmsNotRunning) {
    return '$tried, but $serial is still silent.\n\n'
        '${BatteryConnection.dormantMessage}';
  }
  return switch (conn.streamClass) {
    StreamClass.awakeNotStreaming => '$tried, but no telemetry followed from '
        '$serial within ${BatteryConnection.resumeTimeout.inSeconds} s. The '
        'BMS answers AT+V, so it is awake: try "Turn switches on", then '
        '"Reconnect".',
    _ => '$tried, but no telemetry followed from $serial within '
        '${BatteryConnection.resumeTimeout.inSeconds} s. Try the next step; '
        'if nothing works: ${BatteryConnection.dormantMessage}',
  };
}

/// Ladder step (i): re-send CMD_BEGIN (the handshake's start-streaming
/// command; it changes nothing on the pack). Single confirm.
WriteAction wakeResendAction(BatteryConnection conn) {
  final serial = serialOf(conn);
  bool? resumed;
  return WriteAction(
    busyKey: WriteKeys.wake,
    title: 'Re-send wake (CMD_BEGIN)',
    message: 'Re-send the start-streaming command (CMD_BEGIN) to $serial? '
        'This is the normal handshake command and changes nothing on the '
        'pack.',
    confirmLabel: 'Re-send wake',
    label: 'wake (CMD_BEGIN)',
    send: () async {
      resumed = await conn.resendWake();
    },
    sentToast: () => resumed == true
        ? 'Stream resumed on $serial'
        : 'Sent: CMD_BEGIN to $serial — no stream yet',
    readBack: () async => resumed ?? false,
    warnTitle: 'Still not streaming',
    warnMessage: () => notStreamingAdvice(conn, tried: 'CMD_BEGIN was sent'),
  );
}

/// Ladder step (ii): the both-MOS-on frame (the vendor app's de-facto wake).
/// A SAFE write (#59: it cannot cut anything), single confirm.
WriteAction wakeSwitchesOnAction(BatteryConnection conn) {
  final serial = serialOf(conn);
  bool? resumed;
  return WriteAction(
    busyKey: WriteKeys.forMos(GateAction.bothMos),
    title: 'Turn switches on',
    message: 'Send charge + output ON to $serial? This is the frame the '
        'vendor app sends after every handshake (its de-facto wake). It turns '
        'both switches on — ${conn.safeWriteMosText(GateAction.bothMos)} — '
        'and can cut nothing.',
    confirmLabel: 'Turn switches ON',
    label: gateWriteLabel(GateAction.bothMos, on: true),
    send: () async {
      resumed = await conn.switchesOnToWake();
    },
    sentToast: () => resumed == true
        ? 'Stream resumed on $serial'
        : 'Sent: charge + output ON to $serial — no stream yet',
    readBack: () async => resumed ?? false,
    warnTitle: 'Still not streaming',
    warnMessage: () =>
        notStreamingAdvice(conn, tried: 'Both switches ON was sent'),
  );
}

/// Ladder step (iii): drop the link and reconnect now. Single confirm.
WriteAction wakeReconnectAction(BatteryConnection conn, BatteryManager manager) {
  final serial = serialOf(conn);
  bool? resumed;
  return WriteAction(
    busyKey: WriteKeys.reconnect,
    title: 'Reconnect',
    message: 'Drop the Bluetooth link to $serial and reconnect now (a fresh '
        'handshake)?',
    confirmLabel: 'Reconnect',
    label: 'reconnect',
    send: () async {
      resumed = await manager.reconnect(conn);
    },
    sentToast: () => resumed == true
        ? 'Reconnected — stream resumed on $serial'
        : 'Reconnected to $serial — no stream yet',
    readBack: () async => resumed ?? false,
    warnTitle: 'Still not streaming',
    warnMessage: () => notStreamingAdvice(conn, tried: 'Reconnected'),
  );
}

/// A single-gate toggle (passive balancing, the #42 heater): flips ONLY its
/// target gate; every other gate keeps its live value. Confirmed with the
/// battery named; [enableNote] is appended when turning ON; an OFF that is
/// [dangerousWhenOff] double-confirms with [offWarning]. [verify] (#91) adds
/// the read-back: the next BAL_STATUS must show the gate at its new value,
/// else the "not confirmed" warning.
WriteAction gateToggleAction(
  BatteryConnection conn, {
  required String label,
  required String busyKey,
  required bool isOn,
  required GateAction action,
  bool dangerousWhenOff = false,
  String? offWarning,
  String? enableNote,
  bool verify = false,
}) {
  final serial = serialOf(conn);
  final target = !isOn;
  final onOff = target ? 'ON' : 'OFF';
  final dangerous = !target && dangerousWhenOff;
  String reported() {
    final s = conn.gateState(action);
    return s == null ? 'no value' : (s ? 'ON' : 'OFF');
  }

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
    readBack: verify ? () => conn.confirmGateState(action, target) : null,
    warnTitle: verify ? '$label not confirmed' : null,
    warnMessage: verify
        ? () => 'Command sent, but $serial still reports $label '
            '${reported()}. The change may not have taken effect — check the '
            'connection and try again.'
        : null,
  );
}

/// #91: the stern second page for turning low-temperature protection OFF.
/// Exact wording is pinned by tests.
String lowTempOffWarning(String serial) =>
    'This DISABLES low-temperature protection on $serial. The BMS will no '
    'longer stop charging when the cells are too cold, and charging lithium '
    'cells below freezing can permanently damage them. Only turn it off if '
    'you are certain.';

/// #91: the stern second page for turning the smoke sensor OFF.
String smokeOffWarning(String serial) =>
    'This DISABLES the smoke sensor on $serial. The BMS will no longer act on '
    'its smoke-sensor input, so smoke or fire at the pack would not be '
    'detected by the BMS.';

/// #91: appended when turning low-temperature protection ON.
const String lowTempEnableNote =
    'With low-temperature protection on, the BMS stops charging when the '
    'cells are too cold.';

/// #91: appended when turning the smoke sensor ON. Honest: every pack seen
/// so far reports it off, and its effect when on is not yet verified.
const String smokeEnableNote =
    'Every pack seen so far reports the smoke sensor off. What the BMS does '
    'with it on — including on a pack with no sensor fitted — has not been '
    'verified; it may raise an alarm or cut output.';

/// #91: the low-temp protection toggle (CMD_GATE_CONTROL byte[2], the vendor
/// setLowTemProtect gate). Flips ONLY byte[2] from the fresh gate base; OFF
/// disables protection, so it double-confirms; read back from BAL_STATUS.
WriteAction lowTempProtectionAction(BatteryConnection conn,
        {required bool target}) =>
    gateToggleAction(
      conn,
      label: 'Low-temp protection',
      busyKey: WriteKeys.lowTemp,
      isOn: !target,
      action: GateAction.tempControlGate,
      dangerousWhenOff: true,
      offWarning: lowTempOffWarning(serialOf(conn)),
      enableNote: lowTempEnableNote,
      verify: true,
    );

/// #91: the smoke-sensor toggle (CMD_GATE_CONTROL byte[3]). Flips ONLY
/// byte[3] from the fresh gate base; OFF double-confirms; read back.
WriteAction smokeSensorAction(BatteryConnection conn,
        {required bool target}) =>
    gateToggleAction(
      conn,
      label: 'Smoke sensor',
      busyKey: WriteKeys.smoke,
      isOn: !target,
      action: GateAction.smokeGate,
      dangerousWhenOff: true,
      offWarning: smokeOffWarning(serialOf(conn)),
      enableNote: smokeEnableNote,
      verify: true,
    );

/// #42 / #62 Bluetooth standby (power saving) — the vendor's "sleep" mode.
/// Enabling it double-confirms with the vendor's explanation and warns that
/// the BLE link / telemetry may stop; turning it off is a single confirm.
/// Read-back via SLEEP_SET_SUCCESS — a timeout on standby-ON is expected (the
/// link may drop), so only a failed standby-OFF raises a warning.
WriteAction sleepAction(BatteryConnection conn, {required bool target}) {
  final serial = serialOf(conn);
  final onOff = target ? 'ON' : 'OFF';
  final label = 'standby $onOff';
  return WriteAction(
    busyKey: WriteKeys.sleep,
    title: target ? 'Turn Bluetooth standby on' : 'Turn Bluetooth standby off',
    message: 'Turn Bluetooth standby (power saving) $onOff on $serial?'
        '${target ? '\n\n$standbyExplanation' : ''}',
    sternWarning: target
        ? 'Once $serial sees no current it will STOP its Bluetooth comms — '
            'the app loses the connection and live data until charge or a '
            'load wakes it. A pack in standby with its output off cannot be '
            'woken at all until it is physically isolated.'
        : null,
    confirmLabel: target ? 'Turn standby ON' : 'Turn standby OFF',
    label: label,
    send: () => conn.setSleepMode(target),
    sentToast: () => 'Sent: Bluetooth standby $onOff to $serial',
    readBack: () => conn.confirmSleepState(target),
    warnTitle: target ? null : 'Standby OFF not confirmed',
    warnMessage: () => 'Command sent, but $serial did not confirm Bluetooth '
        'standby OFF within a few seconds. Its standby setting may still be '
        'ON — check the connection and try again.',
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

/// #55: the note shown while the persistent gate controls are unavailable.
/// This is AUTOMATIC — never a user approval step — so the wording must not
/// read like a permission ("locked", "approve"). [restartAvailable] adds that
/// the momentary Restart / Factory actions still work (their looser rule).
String controlsUnavailableText(String reason,
        {bool safeWritesAvailable = false}) =>
    'Controls unavailable — $reason. They become available again '
    'automatically once the battery is connected and reporting its status.'
    '${safeWritesAvailable ? ' Charge ON, Output ON and Restart BMS stay available.' : ''}';

/// #55: the note under the Restart button while it is unavailable.
String restartUnavailableText(String reason) =>
    'Restart unavailable — $reason. It becomes available automatically once '
    'the battery is connected.';

/// #59 / #58: appended to a switch-ON / Restart confirmation when there is no
/// fresh gate status — the frame still goes out, built from
/// [BatteryConnection.safeWriteBase] (its own MOS byte forced ON, the other
/// switch at its last-known value — both ON for Restart / Both — and the
/// other gates last-known or protective defaults), and the user is told
/// exactly what it carries.
String noFreshBaseNote(BatteryConnection conn, GateAction action) {
  final r = conn.gateControlsDisabledReason;
  // Only for a CONNECTED row without a fresh base: that is the one case the
  // safe write actually goes out on safeWriteBase.
  if (r == null || conn.safeWritesDisabledReason != null) return '';
  final known = conn.lastKnownGates != null;
  return '\n\nNote: no fresh gate status from ${serialOf(conn)} ($r). The '
      'command sets ${conn.safeWriteMosText(action)} and carries '
      '${known ? 'the last-known values' : 'safe defaults (low-temp protection on, smoke and heater off)'} '
      'for the other gates.';
}

/// The ONE Restart-BMS action (double-confirmed, names the serial), shared by
/// the Controls section and the #50 latched over-temp warning card. #55: a
/// momentary action — the connection allows it whenever it is connected and
/// has decoded a gate base on this link, regardless of the base's age.
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
        'inhibits charging while set.${noFreshBaseNote(conn, GateAction.restart)}',
    confirmLabel: 'Restart',
    label: gateWriteLabel(GateAction.restart, on: true),
    send: () => conn.sendGateControl(GateAction.restart, on: true),
    sentToast: () => 'Sent: restart to $serial',
  );
}

/// Factory reset — double confirm with a stern warning. Momentary (#55), like
/// restart.
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

/// Fleet-wide MOS switch (issue #11 / #26 / #58): every member gets the same
/// frame for the Charge switch, the Output switch or Both. OFF lists every
/// affected serial and double-confirms. M3: a member that failed after the C1
/// pre-check is reported by serial in a warning while the others still went
/// through; only an all-OK write toasts.
WriteAction fleetMosAction(BatteryManager manager,
    {required GateAction action, required bool on}) {
  assert(isMosAction(action));
  final serials = [for (final b in manager.fleetMembers) b.state.serial ?? '—'];
  final serialList = serials.join('\n • ');
  final countText = pluralBatteries(serials.length);
  final onOff = on ? 'ON' : 'OFF';
  final name = mosSwitchName(action);
  final short = action == GateAction.bothMos ? 'switches' : name;
  final what = switch (action) {
    GateAction.chargeMos => 'the charge switch (charge MOS)',
    GateAction.dischargeMos => 'the output switch (discharge MOS)',
    _ => 'both switches (charge + output)',
  };
  final list = serials.join(', ');
  final consequence = switch (action) {
    GateAction.chargeMos => 'This will stop charging on every fleet battery '
        '($list); no current can flow into them until charge is turned back on.',
    GateAction.dischargeMos => 'This will cut output to every fleet battery '
        '($list); anything powered by them will lose power.',
    _ => 'This will cut output to every fleet battery ($list) — anything '
        'powered by them will lose power — and stop them charging.',
  };
  // #62: members whose Bluetooth standby is ON / unknown get standby-OFF
  // first; the stern page names them — and, with more than one pack in the
  // fleet (a parallel bank), carries the sibling-takes-all-current warning.
  final standby = manager.fleetNeedingStandbyOff;
  final standbyNote = on
      ? ''
      : '${standby.isEmpty ? '' : '\n\n${action == GateAction.chargeMos ? standbyDormancyWarningCharge : standbyDormancyWarning}'
          ' (${standby.map((b) => b.state.serial ?? '—').join(', ')})'}'
          '${parallelBankNote(serials.length)}';
  FleetWriteResult? result;
  return WriteAction(
    busyKey: WriteKeys.forFleetMos(action),
    title: on ? 'All $short ON' : 'ALL $short OFF',
    message: 'Turn $what $onOff on all $countText in the '
        'fleet?\n\n • $serialList',
    sternWarning: on ? null : '$consequence$standbyNote',
    confirmLabel: 'Turn ALL $short $onOff',
    label: 'fleet $name $onOff',
    send: () async {
      result = await manager.fleetSetMos(action, on: on);
    },
    sentToast: () {
      final r = result;
      if (r == null || !r.allOk) return null;
      return 'Sent: $name $onOff to ${pluralBatteries(r.succeeded.length)}';
    },
    readBack: () async => result?.allOk ?? true,
    warnTitle: 'Fleet write partly failed',
    warnMessage: () {
      final r = result!;
      return 'Sent $name $onOff to ${pluralBatteries(r.succeeded.length)}'
          '${r.succeeded.isEmpty ? '' : ' (${r.succeeded.join(', ')})'}.\n\n'
          'Failed on ${pluralBatteries(r.failed.length)}:\n'
          '${r.failed.entries.map((e) => ' • ${e.key}: ${writeFailureReason(e.value)}').join('\n')}';
    },
  );
}

/// #58: fleet-wide Charge switch.
WriteAction fleetChargeAction(BatteryManager manager, {required bool on}) =>
    fleetMosAction(manager, action: GateAction.chargeMos, on: on);

/// #58: fleet-wide Output switch (the former "All output").
WriteAction fleetOutputAction(BatteryManager manager, {required bool on}) =>
    fleetMosAction(manager, action: GateAction.dischargeMos, on: on);

/// #58: fleet-wide Both switches.
WriteAction fleetBothMosAction(BatteryManager manager, {required bool on}) =>
    fleetMosAction(manager, action: GateAction.bothMos, on: on);

/// Ask for a capacity (validated 1–1000 Ah) or null on cancel.
///
/// #57: the dialog widget OWNS its text controller and disposes it in
/// `State.dispose` (when the route has fully gone). The former "dispose on
/// every exit path" `finally` ran the moment the dialog was popped — while its
/// TextField was still mounted for the pop transition — and the resulting
/// "used after being disposed" throw inside `Element.update` left orphaned
/// dependents behind, which the route teardown then reported as the red
/// `'_dependents.isEmpty': is not true` screen. See `_RenameDialog` in
/// main.dart for the full chain; regression test in test/crash_57_test.dart.
Future<double?> askCapacity(BuildContext context, BatteryConnection conn) {
  final current = conn.ratedCapacityAh;
  return showDialog<double>(
    context: context,
    builder: (_) => _CapacityDialog(
      serial: serialOf(conn),
      initial: current != null ? current.toStringAsFixed(0) : '',
    ),
  );
}

class _CapacityDialog extends StatefulWidget {
  final String serial;
  final String initial;
  const _CapacityDialog({required this.serial, required this.initial});

  @override
  State<_CapacityDialog> createState() => _CapacityDialogState();
}

class _CapacityDialogState extends State<_CapacityDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    final v = double.tryParse(_controller.text.trim());
    if (v == null ||
        !v.isFinite ||
        v < CapacityWrite.minAh ||
        v > CapacityWrite.maxAh) {
      setState(() => _error = 'Enter a number between 1 and 1000');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set rated capacity'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Enter ${widget.serial}'s rated capacity in amp-hours (1–1000 Ah). "
            'This changes the pack’s SOC and remaining-time estimator basis.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Capacity',
              suffixText: 'Ah',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _next,
          child: const Text('Next…'),
        ),
      ],
    );
  }
}
