import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/alert_notifications.dart';

/// #45: pure notification-decision logic — which conditions raise/clear which
/// notification id/channel, stable ids, and de-dupe against what is showing.
void main() {
  BatterySnapshot snap(
    String serial, {
    bool fault = false,
    String faultReason = '',
    bool unknownChange = false,
    String unknownReason = '',
    bool disconnected = false,
  }) =>
      BatterySnapshot(
        serial: serial,
        displayName: serial,
        fault: fault,
        faultReason: faultReason,
        unknownChange: unknownChange,
        unknownReason: unknownReason,
        disconnected: disconnected,
      );

  group('notificationIdFor', () {
    test('is stable and positive for a (serial, condition)', () {
      final a = notificationIdFor('JS-1', AlertCondition.fault);
      final b = notificationIdFor('JS-1', AlertCondition.fault);
      expect(a, b, reason: 'same inputs -> same id (updates in place)');
      expect(a, greaterThanOrEqualTo(0));
    });

    test('differs by condition and by serial', () {
      final fault = notificationIdFor('JS-1', AlertCondition.fault);
      final unknown = notificationIdFor('JS-1', AlertCondition.unknownChange);
      final disc = notificationIdFor('JS-1', AlertCondition.disconnect);
      final other = notificationIdFor('JS-2', AlertCondition.fault);
      expect({fault, unknown, disc, other}.length, 4,
          reason: 'no collisions across the conditions/serials used here');
    });
  });

  group('desiredNotifications', () {
    test('a genuine fault -> one Faults-channel notification with the reason',
        () {
      final d = desiredNotifications(
          [snap('JS-1', fault: true, faultReason: 'current, temperature')],
          enabled: true);
      expect(d.length, 1);
      final n = d.values.single;
      expect(n.channel, AlertChannel.faults);
      expect(n.payload, 'JS-1'); // deep-link payload = serial
      expect(n.title, contains('JS-1'));
      expect(n.body, contains('current, temperature'));
      expect(n.id, notificationIdFor('JS-1', AlertCondition.fault));
    });

    test('an unknown-byte change -> Alerts channel', () {
      final d = desiredNotifications(
          [snap('JS-1', unknownChange: true, unknownReason: 'unknownB3')],
          enabled: true);
      final n = d.values.single;
      expect(n.channel, AlertChannel.alerts);
      expect(n.body, contains('unknownB3'));
      expect(n.id, notificationIdFor('JS-1', AlertCondition.unknownChange));
    });

    test('a fleet disconnect -> Alerts channel', () {
      final d =
          desiredNotifications([snap('JS-1', disconnected: true)], enabled: true);
      final n = d.values.single;
      expect(n.channel, AlertChannel.alerts);
      expect(n.title, contains('Disconnected'));
      expect(n.id, notificationIdFor('JS-1', AlertCondition.disconnect));
    });

    test('a pack with several conditions -> one notification per condition', () {
      final d = desiredNotifications([
        snap('JS-1',
            fault: true,
            faultReason: 'voltage',
            unknownChange: true,
            unknownReason: 'unknownB1',
            disconnected: true),
      ], enabled: true);
      expect(d.length, 3);
      expect(d.values.map((n) => n.channel).toSet(),
          {AlertChannel.faults, AlertChannel.alerts});
    });

    test('disabled -> empty desired set (so everything is cancelled)', () {
      final d = desiredNotifications([snap('JS-1', fault: true)], enabled: false);
      expect(d, isEmpty);
    });

    test('no active conditions -> nothing desired', () {
      final d = desiredNotifications([snap('JS-1'), snap('JS-2')], enabled: true);
      expect(d, isEmpty);
    });
  });

  group('planNotifications (diff / de-dupe)', () {
    test('new conditions are shown; nothing cancelled', () {
      final desired =
          desiredNotifications([snap('JS-1', fault: true)], enabled: true);
      final plan = planNotifications(active: const {}, desired: desired);
      expect(plan.toShow.length, 1);
      expect(plan.toCancel, isEmpty);
    });

    test('an unchanged, already-active notification is NOT re-posted (de-dupe)',
        () {
      final desired =
          desiredNotifications([snap('JS-1', fault: true)], enabled: true);
      final plan = planNotifications(active: desired, desired: desired);
      expect(plan.toShow, isEmpty, reason: 'identical & active -> de-duped');
      expect(plan.toCancel, isEmpty);
    });

    test('a changed body re-raises the SAME id (update in place)', () {
      final before = desiredNotifications(
          [snap('JS-1', fault: true, faultReason: 'current')],
          enabled: true);
      final after = desiredNotifications(
          [snap('JS-1', fault: true, faultReason: 'current, temperature')],
          enabled: true);
      final plan = planNotifications(active: before, desired: after);
      expect(plan.toShow.length, 1);
      expect(plan.toShow.single.id, before.values.single.id,
          reason: 'same id -> updates rather than stacks');
      expect(plan.toCancel, isEmpty);
    });

    test('a cleared condition is cancelled by its id', () {
      final before =
          desiredNotifications([snap('JS-1', fault: true)], enabled: true);
      final after = desiredNotifications([snap('JS-1')], enabled: true);
      final plan = planNotifications(active: before, desired: after);
      expect(plan.toShow, isEmpty);
      expect(plan.toCancel, [notificationIdFor('JS-1', AlertCondition.fault)]);
    });

    test('disabling cancels every active notification', () {
      final before = desiredNotifications(
          [snap('JS-1', fault: true), snap('JS-2', disconnected: true)],
          enabled: true);
      final after = desiredNotifications(
          [snap('JS-1', fault: true), snap('JS-2', disconnected: true)],
          enabled: false);
      final plan = planNotifications(active: before, desired: after);
      expect(plan.toShow, isEmpty);
      expect(plan.toCancel.toSet(), before.keys.toSet());
    });

    test('mixed cycle: one raised, one updated, one cleared', () {
      final active = desiredNotifications([
        snap('JS-1', fault: true, faultReason: 'current'), // will update
        snap('JS-2', disconnected: true), // will clear
      ], enabled: true);
      final desired = desiredNotifications([
        snap('JS-1', fault: true, faultReason: 'voltage'), // updated body
        snap('JS-3', unknownChange: true, unknownReason: 'x'), // new
      ], enabled: true);
      final plan = planNotifications(active: active, desired: desired);
      final shownIds = plan.toShow.map((n) => n.id).toSet();
      expect(shownIds, {
        notificationIdFor('JS-1', AlertCondition.fault),
        notificationIdFor('JS-3', AlertCondition.unknownChange),
      });
      expect(plan.toCancel,
          [notificationIdFor('JS-2', AlertCondition.disconnect)]);
    });
  });
}
