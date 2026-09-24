/// GitHub #56: naming a battery must not fail when the user does NOT enter a
/// name. The rename dialog has three distinct, non-failing outcomes:
///
///  * dismissed (Cancel / tap outside / back) -> NO change, no error, no toast;
///  * Save with an EMPTY or whitespace-only field -> the alias is CLEARED back
///    to the bare serial, immediately visible on the card and the detail page;
///  * Save with real text -> the label changes.
///
/// The store itself tolerates null / empty / blank and never throws, even
/// when the preferences plugin is unavailable.
library;

import 'package:battery_reader/alias_store.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/diagnostics.dart';
import 'package:battery_reader/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_57_test.dart' show pumpFor, pumpThroughTransition;
import 'fakes.dart';

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

const _serial = 'JS-TEST01';

/// A page that shows the live display name (as the card and the detail page
/// do) and a button that opens the rename dialog through [editBatteryAlias].
class _Host extends StatefulWidget {
  final AliasStore aliases;
  final void Function(AliasEditOutcome)? onDone;
  const _Host(this.aliases, {this.onDone});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            Text(displayName(widget.aliases.aliasFor(_serial), _serial),
                key: const Key('label')),
            TextButton(
              onPressed: () async {
                final r =
                    await editBatteryAlias(context, widget.aliases, _serial);
                widget.onDone?.call(r);
                if (mounted) setState(() {});
              },
              child: const Text('rename'),
            ),
          ],
        ),
      );
}

Widget _app(Widget home) => MaterialApp(
      navigatorKey: gNavKey,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: home,
    );

String _label(WidgetTester t) =>
    (t.widget<Text>(find.byKey(const Key('label')))).data!;

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('rename'));
  await pumpFor(tester, const Duration(milliseconds: 500));
  expect(find.byType(TextField), findsOneWidget);
}

/// Nothing left over from the dialog: no dialog, no snackbar, no "failed".
void _expectClean(WidgetTester tester) {
  expect(find.byType(TextField), findsNothing);
  expect(find.byType(AlertDialog), findsNothing);
  expect(find.byType(SnackBar), findsNothing);
  expect(find.textContaining('ailed'), findsNothing);
  expect(tester.takeException(), isNull);
}

Future<void> _dismiss(WidgetTester tester, String how) async {
  switch (how) {
    case 'Cancel':
      await tester.tap(find.text('Cancel'));
    case 'tap outside':
      await tester.tapAt(const Offset(5, 5));
    case 'back':
      await gNavKey.currentState!.maybePop();
  }
}

Iterable<AppLogEntry> _storeLog() =>
    AppLog.instance.entries.where((e) => e.source == 'AliasStore');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.instance.clear();
    AppLog.instance.echoToConsole = false;
  });

  group('#56 dismissed: no change, no error, no toast', () {
    for (final how in ['Cancel', 'tap outside', 'back']) {
      testWidgets('$how with an existing alias keeps it', (tester) async {
        final aliases = AliasStore(prefs: _prefs);
        await aliases.load();
        await aliases.setAlias(_serial, 'Left');
        AliasEditOutcome? outcome;
        await tester
            .pumpWidget(_app(_Host(aliases, onDone: (r) => outcome = r)));
        expect(_label(tester), 'Left (JS-TEST01)');
        await _open(tester);
        // Type something, then abandon it: the typed text must NOT be saved.
        await tester.enterText(find.byType(TextField), 'Abandoned');
        await _dismiss(tester, how);
        await pumpThroughTransition(tester);
        _expectClean(tester);
        expect(outcome, AliasEditOutcome.dismissed);
        expect(aliases.aliasFor(_serial), 'Left');
        expect(_label(tester), 'Left (JS-TEST01)');
        expect(_storeLog(), isEmpty);
      });

      testWidgets('$how with no alias set stays unnamed', (tester) async {
        final aliases = AliasStore(prefs: _prefs);
        await aliases.load();
        AliasEditOutcome? outcome;
        await tester
            .pumpWidget(_app(_Host(aliases, onDone: (r) => outcome = r)));
        await _open(tester);
        await _dismiss(tester, how);
        await pumpThroughTransition(tester);
        _expectClean(tester);
        expect(outcome, AliasEditOutcome.dismissed);
        expect(aliases.aliasFor(_serial), isNull);
        expect(_label(tester), 'JS-TEST01');
      });
    }
  });

  group('#56 Save with no name = clear back to the serial', () {
    for (final entry in {'empty': '', 'whitespace': '   \t '}.entries) {
      testWidgets('${entry.key} field clears an existing alias immediately',
          (tester) async {
        final aliases = AliasStore(prefs: _prefs);
        await aliases.load();
        await aliases.setAlias(_serial, 'Left');
        AliasEditOutcome? outcome;
        await tester
            .pumpWidget(_app(_Host(aliases, onDone: (r) => outcome = r)));
        await _open(tester);
        // The field is pre-filled with the current alias.
        expect(find.widgetWithText(TextField, 'Left'), findsOneWidget);
        await tester.enterText(find.byType(TextField), entry.value);
        await tester.tap(find.text('Save'));
        await pumpThroughTransition(tester);
        _expectClean(tester);
        expect(outcome, AliasEditOutcome.cleared);
        expect(aliases.aliasFor(_serial), isNull);
        expect(_label(tester), 'JS-TEST01');
        // Persisted as cleared: a fresh store does not bring 'Left' back.
        final s2 = AliasStore(prefs: _prefs);
        await s2.load();
        expect(s2.aliasFor(_serial), isNull);
        expect(_storeLog(), isEmpty);
      });

      testWidgets('${entry.key} field with no alias set is a no-op clear',
          (tester) async {
        final aliases = AliasStore(prefs: _prefs);
        await aliases.load();
        AliasEditOutcome? outcome;
        await tester
            .pumpWidget(_app(_Host(aliases, onDone: (r) => outcome = r)));
        await _open(tester);
        await tester.enterText(find.byType(TextField), entry.value);
        await tester.tap(find.text('Save'));
        await pumpThroughTransition(tester);
        _expectClean(tester);
        expect(outcome, AliasEditOutcome.cleared);
        expect(aliases.aliasFor(_serial), isNull);
        expect(_label(tester), 'JS-TEST01');
      });
    }

    testWidgets('keyboard "done" on an empty field also clears',
        (tester) async {
      final aliases = AliasStore(prefs: _prefs);
      await aliases.load();
      await aliases.setAlias(_serial, 'Left');
      await tester.pumpWidget(_app(_Host(aliases)));
      await _open(tester);
      await tester.enterText(find.byType(TextField), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumpThroughTransition(tester);
      _expectClean(tester);
      expect(aliases.aliasFor(_serial), isNull);
      expect(_label(tester), 'JS-TEST01');
    });
  });

  group('#56 Save with a real name changes the label', () {
    testWidgets('text is saved (trimmed) and shown at once', (tester) async {
      final aliases = AliasStore(prefs: _prefs);
      await aliases.load();
      AliasEditOutcome? outcome;
      await tester.pumpWidget(_app(_Host(aliases, onDone: (r) => outcome = r)));
      await _open(tester);
      await tester.enterText(find.byType(TextField), '  Left battery ');
      await tester.tap(find.text('Save'));
      await pumpThroughTransition(tester);
      _expectClean(tester);
      expect(outcome, AliasEditOutcome.renamed);
      expect(aliases.aliasFor(_serial), 'Left battery');
      expect(_label(tester), 'Left battery (JS-TEST01)');
    });

    testWidgets('re-saving the SAME name is still "renamed", never an error',
        (tester) async {
      final aliases = AliasStore(prefs: _prefs);
      await aliases.load();
      await aliases.setAlias(_serial, 'Left');
      AliasEditOutcome? outcome;
      await tester.pumpWidget(_app(_Host(aliases, onDone: (r) => outcome = r)));
      await _open(tester);
      await tester.tap(find.text('Save')); // untouched, pre-filled 'Left'
      await pumpThroughTransition(tester);
      _expectClean(tester);
      expect(outcome, AliasEditOutcome.renamed);
      expect(aliases.aliasFor(_serial), 'Left');
    });
  });

  group('#56 the store tolerates null / empty / blank', () {
    test('null, empty and blank all clear, never throw', () async {
      final s = AliasStore(prefs: _prefs);
      await s.load();
      await s.setAlias(_serial, 'Left');
      await s.setAlias(_serial, null);
      expect(s.aliasFor(_serial), isNull);
      await s.setAlias(_serial, 'Left');
      await s.setAlias(_serial, '');
      expect(s.aliasFor(_serial), isNull);
      await s.setAlias(_serial, 'Left');
      await s.setAlias(_serial, ' \n ');
      expect(s.aliasFor(_serial), isNull);
      // Clearing an alias that was never set is a silent no-op.
      await s.setAlias('JS-NEVER', '');
      expect(s.aliasFor('JS-NEVER'), isNull);
      // An empty serial is ignored rather than stored under "".
      await s.setAlias('', 'x');
      expect(s.aliasFor(''), isNull);
      expect(_storeLog(), isEmpty);
    });

    test(
        'an unavailable prefs plugin: clear still updates the cache and '
        'does not throw (failure recorded, not raised)', () async {
      final s = AliasStore(prefs: () => throw StateError('no plugin'));
      await s.load(); // best-effort: cache empty
      await s.setAlias(_serial, 'Left'); // cached, persist fails quietly
      expect(s.aliasFor(_serial), 'Left');
      await s.setAlias(_serial, '');
      expect(s.aliasFor(_serial), isNull);
      await s.setAlias(_serial, null);
      expect(s.aliasFor(_serial), isNull);
      expect(_storeLog(), isNotEmpty,
          reason: 'the failure is diagnosed, never thrown');
    });

    test('outcomeFor maps null / blank / text to the three outcomes', () {
      expect(AliasStore.outcomeFor(null), AliasEditOutcome.dismissed);
      expect(AliasStore.outcomeFor(''), AliasEditOutcome.cleared);
      expect(AliasStore.outcomeFor('  '), AliasEditOutcome.cleared);
      expect(AliasStore.outcomeFor('Left'), AliasEditOutcome.renamed);
      expect(AliasStore.outcomeFor(' Left '), AliasEditOutcome.renamed);
    });
  });

  group('#56 on the real list card and detail page (demo fleet)', () {
    testWidgets('card: clear via the pencil updates the card at once, no toast',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'demo_mode_v1': true,
        'battery_aliases_v1': '{"DEMO-1":"Left"}',
      });
      await tester.pumpWidget(const BatteryReaderApp());
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.textContaining('DEMO 1: Left — test data'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.edit).first);
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('Save'));
      await pumpThroughTransition(tester);
      _expectClean(tester);
      expect(find.textContaining('DEMO 1: Left — test data'), findsNothing);
      expect(find.textContaining('DEMO 1 — test data'), findsWidgets);
      // Cancel from the same card: still nothing changes / no toast.
      await tester.tap(find.byIcon(Icons.edit).first);
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.enterText(find.byType(TextField), 'Nope');
      await tester.tap(find.text('Cancel'));
      await pumpThroughTransition(tester);
      _expectClean(tester);
      expect(find.textContaining('Nope'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('detail page: title follows clear / rename immediately',
        (tester) async {
      final manager = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      manager.startDemoFleet();
      final aliases = AliasStore(prefs: _prefs);
      await aliases.load();
      final conn = manager.batteries.first;
      final serial = conn.state.serial!;
      await aliases.setAlias(serial, 'Left');
      await tester.pumpWidget(_app(
          BatteryDetailPage(conn: conn, manager: manager, aliases: aliases)));
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.text(displayName('Left', serial)), findsOneWidget);
      await tester.tap(find.byIcon(Icons.edit).first);
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await pumpThroughTransition(tester);
      _expectClean(tester);
      expect(find.text(displayName('Left', serial)), findsNothing);
      expect(find.text(displayName(null, serial)), findsOneWidget);
      await tester.tap(find.byIcon(Icons.edit).first);
      await pumpFor(tester, const Duration(seconds: 1));
      await tester.enterText(find.byType(TextField), 'Right');
      await tester.tap(find.text('Save'));
      await pumpThroughTransition(tester);
      _expectClean(tester);
      expect(find.text(displayName('Right', serial)), findsOneWidget);
      manager.disposeAll();
      await tester.pump();
    });
  });
}
