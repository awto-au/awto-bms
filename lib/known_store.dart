/// shared_preferences-backed [KnownBatteryStore] (#110): every battery the
/// app has ever found, starred or not, with its last-known values and the
/// user's "forgotten" flag.
///
/// One preference, `known_batteries_v1`, holds a JSON object:
/// `{"seeded": true, "batteries": [{...FleetRecord..., "forgotten": true,
/// "firstSeenMs": 1695...}, ...]}`. Being a preference, the data export /
/// import (#104) carries it with the other settings. Built on [PrefsStore]:
/// every read / write is best-effort and a failure (or a corrupt entry) is
/// recorded in Diagnostics; one corrupt entry never loses the others.
library;

import 'battery_manager.dart';
import 'diagnostics.dart';
import 'prefs_store.dart';

class SharedPrefsKnownStore extends PrefsStore implements KnownBatteryStore {
  /// The preference key (exported / imported with the other settings).
  static const key = 'known_batteries_v1';

  SharedPrefsKnownStore({super.prefs}) : super('KnownStore');

  @override
  Future<KnownBatteries> load() async {
    final decoded = await readJson(key);
    if (decoded is! Map) return const KnownBatteries();
    final map = <String, KnownBattery>{};
    final rows = decoded['batteries'];
    if (rows is List) {
      for (final row in rows) {
        final k = guardSync<KnownBattery>('decode known battery',
            () => KnownBattery.fromJson(Map<String, dynamic>.from(row as Map)),
            source: source);
        if (k != null && k.serial.isNotEmpty) map[k.serial] = k;
      }
    }
    return KnownBatteries(seeded: decoded['seeded'] == true, batteries: map);
  }

  @override
  Future<void> save(KnownBatteries known) => writeJson(key, {
        'seeded': known.seeded,
        'batteries': [for (final k in known.batteries.values) k.toJson()],
      });
}
