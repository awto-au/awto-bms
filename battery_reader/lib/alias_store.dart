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

  /// Set (or, with an empty/blank value, clear) the alias for [serial] and
  /// persist. An empty alias removes the entry so the display reverts to the
  /// bare serial.
  Future<void> setAlias(String serial, String? alias) async {
    if (serial.isEmpty) return;
    final trimmed = (alias ?? '').trim();
    if (trimmed.isEmpty) {
      _cache.remove(serial);
    } else {
      _cache[serial] = trimmed;
    }
    await writeJson(_key, _cache);
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
