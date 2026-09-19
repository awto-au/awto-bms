import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:battery_reader/alias_store.dart';

/// #44: per-battery custom name (local alias) persistence + display helper.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AliasStore persistence', () {
    test('save/restore round-trip across a fresh store (restart)', () async {
      final s = AliasStore();
      await s.load();
      await s.setAlias('JS-A', 'Left battery');
      await s.setAlias('RV-B', 'Right battery');
      expect(s.aliasFor('JS-A'), 'Left battery');

      // Simulate an app restart: a brand-new store reading the same prefs.
      final s2 = AliasStore();
      await s2.load();
      expect(s2.aliasFor('JS-A'), 'Left battery');
      expect(s2.aliasFor('RV-B'), 'Right battery');
    });

    test('empty (or blank) clears the alias back to the serial', () async {
      final s = AliasStore();
      await s.load();
      await s.setAlias('JS-A', 'Left battery');
      await s.setAlias('JS-A', ''); // clear
      expect(s.aliasFor('JS-A'), isNull);

      await s.setAlias('JS-A', 'X');
      await s.setAlias('JS-A', '   '); // whitespace-only also clears
      expect(s.aliasFor('JS-A'), isNull);

      final s2 = AliasStore();
      await s2.load();
      expect(s2.aliasFor('JS-A'), isNull, reason: 'cleared alias stays cleared');
    });

    test('aliases are trimmed and unknown serials return null', () async {
      final s = AliasStore();
      await s.load();
      await s.setAlias('JS-A', '  Padded  ');
      expect(s.aliasFor('JS-A'), 'Padded');
      expect(s.aliasFor('JS-UNKNOWN'), isNull);
      expect(s.aliasFor(null), isNull);
    });
  });

  group('displayName helper', () {
    test('no alias shows the bare serial', () {
      expect(displayName(null, 'JS-2C14AA'), 'JS-2C14AA');
      expect(displayName('', 'JS-2C14AA'), 'JS-2C14AA');
    });
    test('an alias shows alongside the serial in parentheses', () {
      expect(displayName('Left battery', 'JS-2C14AA'),
          'Left battery (JS-2C14AA)');
    });
    test('null/empty serial falls back to an em dash', () {
      expect(displayName(null, null), '—');
      expect(displayName('Left', null), 'Left (—)');
    });
  });
}
