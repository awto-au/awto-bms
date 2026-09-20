/// shared_preferences-backed per-battery custom names (#44): lets the user give
/// each pack a friendly local label (e.g. "Left battery") shown in place of /
/// alongside the serial. Purely local — nothing is ever sent to the BMS.
///
/// Kept as a small separate pref keyed by serial (a single JSON object of
/// serial -> alias) rather than folded into [FleetRecord], so an alias applies
/// to EVERY discovered pack — in-fleet, non-fleet and remembered offline
/// favourites alike — independent of fleet membership. An in-memory cache backs
/// synchronous reads during `build`; writes persist best-effort through the
/// shared [PrefsStore] base (failures are recorded in Diagnostics).
library;

import 'prefs_store.dart';

/// #56: the three distinct, non-failing outcomes of the rename dialog.
enum AliasEditOutcome {
  /// Cancel / tap outside / back: nothing changed.
  dismissed,

  /// Saved with an empty or whitespace-only name: alias cleared, the display
  /// reverts to the bare serial.
  cleared,

  /// Saved with real text: the alias was set.
  renamed,
}

class AliasStore extends PrefsStore {
  static const _key = 'battery_aliases_v1';

  AliasStore({super.prefs}) : super('AliasStore');

  final Map<String, String> _cache = {};

  /// Load the persisted aliases into the in-memory cache. Best-effort: an
  /// unavailable plugin or a corrupt payload leaves the cache empty.
  Future<void> load() async {
    final decoded = await readJson(_key);
    _cache.clear();
    if (decoded is Map) {
      decoded.forEach((k, v) {
        if (k is String && v is String && v.isNotEmpty) _cache[k] = v;
      });
    }
  }

  /// The alias for [serial], or null when none is set (fall back to the serial).
  String? aliasFor(String? serial) =>
      (serial == null || serial.isEmpty) ? null : _cache[serial];

  /// #56: classify a dialog result: null = dismissed (no change), blank =
  /// clear, anything else = rename. Pure.
  static AliasEditOutcome outcomeFor(String? result) => result == null
      ? AliasEditOutcome.dismissed
      : result.trim().isEmpty
          ? AliasEditOutcome.cleared
          : AliasEditOutcome.renamed;

  /// Set (or, with a null / empty / blank value, clear) the alias for
  /// [serial] and persist. A cleared alias removes the entry so the display
  /// reverts to the bare serial. Never throws: the cache is updated first so
  /// the UI reflects the change at once, and the persist is best-effort (a
  /// failure is recorded in Diagnostics).
  Future<AliasEditOutcome> setAlias(String serial, String? alias) async {
    if (serial.isEmpty) return AliasEditOutcome.dismissed;
    final trimmed = (alias ?? '').trim();
    if (trimmed.isEmpty) {
      _cache.remove(serial);
    } else {
      _cache[serial] = trimmed;
    }
    await writeJson(_key, _cache);
    return trimmed.isEmpty ? AliasEditOutcome.cleared : AliasEditOutcome.renamed;
  }
}

/// Build the display name for a pack: the alias shown alongside the serial in
/// parentheses (e.g. "Left battery (JS-2C14AA)"), or the bare serial when no
/// alias is set. [serial] null/empty falls back to an em dash.
String displayName(String? alias, String? serial) {
  final s = (serial == null || serial.isEmpty) ? '—' : serial;
  if (alias == null || alias.isEmpty) return s;
  return '$alias ($s)';
}
