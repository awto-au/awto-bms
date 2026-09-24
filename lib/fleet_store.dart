/// shared_preferences-backed [FleetStore] (issue #27, extended in #34): persists
/// the favourite fleet durably so membership — and each pack's last-known
/// summary — survives an app kill/restart.
///
/// Since #34 the stored shape is a JSON [FleetRecord] per in-fleet serial
/// (serial + profile + remoteId + last-known SOC / V / Ah / lastSeen), not just
/// the bare serial. A legacy serial-set (#27) is migrated on first load. The
/// legacy key is kept in sync on save so an older build still sees the fleet.
///
/// Kept separate from [BatteryManager] so the manager itself never imports the
/// plugin and stays trivially testable with an in-memory fake store. Built on
/// the shared [PrefsStore] base (pass C1): every read/write is best-effort and
/// every failure — including a corrupt row — is recorded in Diagnostics.
library;

import 'dart:convert';

import 'battery_manager.dart';
import 'diagnostics.dart';
import 'prefs_store.dart';

class SharedPrefsFleetStore extends PrefsStore implements FleetStore {
  /// Preferences key holding the per-serial favourite records (a JSON string
  /// list, one object per record).
  static const _recordsKey = 'fleet_records_v1';

  /// Legacy key (#27): a plain list of in-fleet serials. Read once for migration
  /// and kept in sync on save for backward compatibility.
  static const _legacySerialsKey = 'fleet_serials_v1';

  SharedPrefsFleetStore({super.prefs}) : super('FleetStore');

  @override
  Future<Map<String, FleetRecord>> load() async {
    final rows = await readStringList(_recordsKey);
    if (rows != null) {
      final map = <String, FleetRecord>{};
      for (final row in rows) {
        // Skip a corrupt row (recorded) rather than losing the whole fleet.
        final rec = guardSync<FleetRecord>(
            'decode fleet record',
            () => FleetRecord.fromJson(jsonDecode(row) as Map<String, dynamic>),
            source: source);
        if (rec != null && rec.serial.isNotEmpty) map[rec.serial] = rec;
      }
      return map;
    }
    // Migrate the legacy serial-set (#27 -> #34): promote each stored serial to
    // a bare record with no last-known summary yet.
    final legacy = await readStringList(_legacySerialsKey);
    if (legacy != null && legacy.isNotEmpty) {
      final map = {for (final s in legacy) s: FleetRecord(serial: s)};
      await save(map); // rewrite in the new shape
      return map;
    }
    // Storage unavailable (recorded by the base) or nothing stored — behave as
    // an empty fleet.
    return <String, FleetRecord>{};
  }

  @override
  Future<void> save(Map<String, FleetRecord> records) async {
    // Best effort: a failed persist must never crash a control action.
    final rows = records.values.map((r) => jsonEncode(r.toJson())).toList();
    await writeStringList(_recordsKey, rows);
    // Keep the legacy serial-set in sync for backward compatibility.
    await writeStringList(_legacySerialsKey, records.keys.toList());
  }
}
