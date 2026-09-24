/// Pure notification-decision logic (issue #45).
///
/// This file deliberately imports NO plugins and touches NO platform APIs so it
/// can be unit-tested in isolation. It answers one question: given the current
/// alert-relevant state of every battery, WHICH system notifications should be
/// showing right now (id + channel + text + deep-link payload), and — diffed
/// against what is already showing — which to (re)raise and which to cancel.
///
/// The runtime wrapper ([AlertNotificationService] in notification_service.dart)
/// feeds it snapshots built from the live [BatteryConnection]s and applies the
/// resulting plan through flutter_local_notifications.
library;

import 'dart:convert' show utf8;

/// Which Android channel a notification belongs to.
///  * [faults] — high importance (sound + vibration): genuine current / voltage
///    / temperature faults.
///  * [alerts] — default importance: unknown-byte MAJOR changes.
///  * [connection] — low importance, SILENT (no sound, no vibration):
///    fleet-member disconnects. A lost BLE link is shown, never sounded.
enum AlertChannel { faults, alerts, connection }

/// The alert conditions, one stable notification id per (serial, condition) so a
/// re-raise UPDATES the same notification rather than stacking a new one.
enum AlertCondition { fault, unknownChange, disconnect }

/// A per-battery snapshot of the three alert conditions, extracted from a live
/// [BatteryConnection] by the caller. Kept plugin-free and value-typed so the
/// decision logic is pure and trivially testable.
class BatterySnapshot {
  /// Stable identity the notification ids are keyed by (the BLE serial / name).
  final String serial;

  /// Display label shown in the notification text (alias + serial where set).
  final String displayName;

  /// A GENUINE fault is active — real current / voltage / temperature fault per
  /// the existing alarm logic. Temperature-alarm byte[2] (the latched
  /// over-temperature protection, a warning) and the unknown bytes [3]/[6] are
  /// not faults.
  final bool fault;

  /// Human-readable fault kinds ("current, temperature"). Empty when [fault] is
  /// false.
  final String faultReason;

  /// An unknown-byte MAJOR change is active (baseline/change detection).
  final bool unknownChange;

  /// Human-readable changed-metric list. Empty when [unknownChange] is false.
  final String unknownReason;

  /// This is a fleet member that has DROPPED from a live connection (a genuine
  /// disconnect this session — not a launch-time offline placeholder). The
  /// caller decides this so the "was ever connected" bookkeeping stays with the
  /// mutable session state.
  final bool disconnected;

  const BatterySnapshot({
    required this.serial,
    required this.displayName,
    this.fault = false,
    this.faultReason = '',
    this.unknownChange = false,
    this.unknownReason = '',
    this.disconnected = false,
  });
}

/// A single notification to display: its stable id, channel, text and the
/// deep-link payload (the battery serial) tapped notifications carry.
class PendingNotification {
  final int id;
  final AlertChannel channel;
  final String title;
  final String body;

  /// Payload = the battery serial, so a tap can deep-link to that battery.
  final String payload;

  const PendingNotification({
    required this.id,
    required this.channel,
    required this.title,
    required this.body,
    required this.payload,
  });

  @override
  bool operator ==(Object other) =>
      other is PendingNotification &&
      other.id == id &&
      other.channel == channel &&
      other.title == title &&
      other.body == body &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(id, channel, title, body, payload);

  @override
  String toString() =>
      'PendingNotification(id: $id, ${channel.name}, "$title" / "$body")';
}

/// The actions to take this cycle: notifications to (re)show and ids to cancel.
class NotificationPlan {
  final List<PendingNotification> toShow;
  final List<int> toCancel;
  const NotificationPlan({required this.toShow, required this.toCancel});

  bool get isEmpty => toShow.isEmpty && toCancel.isEmpty;
}

/// 32-bit FNV-1a over the UTF-8 bytes of [s]. L14: a hash whose value is fixed
/// by its definition, unlike `String.hashCode` (which the Dart SDK is free to
/// change between releases), so a notification id computed by an older build
/// can still be matched — and cancelled — by a newer one. Pure; unit-tested
/// against the published test vectors.
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// Stable, positive notification id for a (serial, condition). Distinct strings
/// hash to (practically always) distinct ids, so the fault / unknown / disconnect
/// notifications for the same pack never collide, and re-raising the SAME
/// condition reuses the SAME id (so it updates in place). Kept positive because
/// the platform side treats the id as an unsigned int. The hash is [fnv1a32]
/// (L14), stable across Dart SDK upgrades.
int notificationIdFor(String serial, AlertCondition condition) {
  final key = '$serial|${condition.name}';
  return fnv1a32(key) & 0x7fffffff;
}

/// The full set of notifications that SHOULD be showing, keyed by id. Empty when
/// [enabled] is false (so a subsequent [planNotifications] cancels everything —
/// this is how the Settings toggle clears live notifications).
Map<int, PendingNotification> desiredNotifications(
  List<BatterySnapshot> snapshots, {
  required bool enabled,
}) {
  final out = <int, PendingNotification>{};
  if (!enabled) return out;
  for (final s in snapshots) {
    if (s.fault) {
      final id = notificationIdFor(s.serial, AlertCondition.fault);
      out[id] = PendingNotification(
        id: id,
        channel: AlertChannel.faults,
        title: 'Fault — ${s.displayName}',
        body: s.faultReason.isEmpty
            ? 'A battery fault is active.'
            : 'Fault: ${s.faultReason}.',
        payload: s.serial,
      );
    }
    if (s.unknownChange) {
      final id = notificationIdFor(s.serial, AlertCondition.unknownChange);
      out[id] = PendingNotification(
        id: id,
        channel: AlertChannel.alerts,
        title: 'Alert — ${s.displayName}',
        body: s.unknownReason.isEmpty
            ? 'An unknown status byte changed.'
            : 'Changed: ${s.unknownReason}.',
        payload: s.serial,
      );
    }
    if (s.disconnected) {
      final id = notificationIdFor(s.serial, AlertCondition.disconnect);
      out[id] = PendingNotification(
        id: id,
        channel: AlertChannel.connection,
        title: 'Disconnected — ${s.displayName}',
        body: 'This fleet battery has disconnected.',
        payload: s.serial,
      );
    }
  }
  return out;
}

/// Diff the DESIRED notifications against the currently-[active] ones:
///  * show a notification that is new OR whose content changed (de-dupe: an
///    unchanged, already-active notification is NOT re-posted), and
///  * cancel any active notification whose condition has cleared.
NotificationPlan planNotifications({
  required Map<int, PendingNotification> active,
  required Map<int, PendingNotification> desired,
}) {
  final toShow = <PendingNotification>[];
  for (final entry in desired.entries) {
    final current = active[entry.key];
    if (current == null || current != entry.value) {
      toShow.add(entry.value); // new, or content changed -> (re)raise & update
    }
    // else: identical & already active -> de-dupe, do nothing.
  }
  final toCancel = <int>[];
  for (final id in active.keys) {
    if (!desired.containsKey(id)) toCancel.add(id);
  }
  return NotificationPlan(toShow: toShow, toCancel: toCancel);
}
