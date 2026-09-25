/// BMS family recognition table + matcher (GitHub issue #15).
///
/// DETECT-ONLY. This module lets the BLE scanner *recognise* several common
/// battery-BMS families that appear in range, so the UI can surface them as
/// "detected · not yet supported" entries. It does NOT decode them: every one of
/// these families speaks its own frame protocol, and the app only decodes
/// JoySuny (Sphere / RV, service FCF0). DECODE support for the other families is
/// future work — see the per-family notes below.
///
/// Matching is deliberately TWO-FACTOR to avoid false positives on the countless
/// generic HM-10 / BLE-UART gadgets that expose the same stock services
/// (FF00 / FFE0 / FFF0). A device is recognised as one of these families only
/// when EITHER:
///   * its advertised name carries a known family prefix / substring, OR
///   * it advertises the family's service UUID *and* the family's expected
///     characteristics are present.
/// A bare generic service with no known name and no expected characteristics is
/// NOT a match. The one exception is JoySuny, whose FCF0 service is a proprietary
/// UUID (not a stock HM-10 service), so it is allowed to match on service alone —
/// preserving the app's original discovery behaviour exactly.
///
/// Note on characteristics at scan time: a BLE advertisement carries service
/// UUIDs but generally NOT characteristic UUIDs (those need a GATT connection).
/// Since we deliberately do NOT connect to the unsupported families, in the
/// field they are recognised via their NAME prefix. The service+characteristic
/// branch is exercised by the unit tests and is ready for a future world where
/// characteristics are known without a full connect. This keeps the matcher
/// correct and false-positive-proof in every case.
library;

/// Expand a 16-bit BLE UUID (e.g. "ff00") to its full 128-bit lowercase form.
String u16(String hex4) => '0000$hex4-0000-1000-8000-00805f9b34fb';

/// One recognised BMS family and the rules for matching it in a scan result.
///
/// This is a plain data record so the [families] table below is trivial to
/// extend when a new family is characterised — add a row, add a test.
class BmsFamily {
  /// Human-readable family label shown in the UI, e.g. "JK-BMS".
  final String name;

  /// Advertised-name prefixes that identify this family (case-sensitive, as the
  /// vendors advertise them), e.g. ['JK-', 'JK_'].
  final List<String> namePrefixes;

  /// Optional advertised-name substring that identifies this family, e.g.
  /// "SmartBat" for LiFePO4POWER / Offgridtec (the vendor name varies around it).
  final String? nameContains;

  /// The family's GATT service UUID (128-bit lowercase), or null if none.
  final String? serviceUuid;

  /// Notify (read/subscribe) characteristic UUIDs expected under [serviceUuid].
  final List<String> notifyChars;

  /// Write characteristic UUIDs expected under [serviceUuid]. May overlap with
  /// [notifyChars] for single-characteristic families (JK, ANT use FFE1 both).
  final List<String> writeChars;

  /// True only for the fully-supported family (JoySuny). Everything else is
  /// DETECT-only: recognised, surfaced, but never connected/handshaked/decoded.
  final bool supported;

  /// When true, a name-prefix hit is only trusted if [serviceUuid] is ALSO
  /// advertised. Guards very short/ambiguous prefixes (Stealth's "ST").
  final bool namePrefixNeedsService;

  /// When true, advertising [serviceUuid] is on its own sufficient to match,
  /// with no characteristic check. Reserved for proprietary (non-generic)
  /// service UUIDs — JoySuny's FCF0 only. Generic FF00/FFE0/FFF0 must NEVER set
  /// this, or they would false-match stock HM-10 gadgets.
  final bool serviceAloneMatches;

  const BmsFamily({
    required this.name,
    this.namePrefixes = const [],
    this.nameContains,
    this.serviceUuid,
    this.notifyChars = const [],
    this.writeChars = const [],
    this.supported = false,
    this.namePrefixNeedsService = false,
    this.serviceAloneMatches = false,
  });

  /// The full set of characteristics this family expects under its service.
  Set<String> get expectedChars =>
      {...notifyChars, ...writeChars}.map((c) => c.toLowerCase()).toSet();

  bool _hasService(Set<String> serviceUuids) =>
      serviceUuid != null && serviceUuids.contains(serviceUuid!.toLowerCase());

  bool _nameHit(String name) =>
      namePrefixes.any(name.startsWith) ||
      (nameContains != null && name.contains(nameContains!));

  /// Two-factor match. [name] is the advertised name, [serviceUuids] the
  /// advertised service UUIDs, and [charUuids] any known characteristic UUIDs
  /// (typically empty at scan time — see the library note).
  bool matches({
    required String name,
    required Set<String> serviceUuids,
    required Set<String> charUuids,
  }) {
    final hasService = _hasService(serviceUuids);

    // Factor 1: known name. Short/ambiguous prefixes must be backed by service.
    if (_nameHit(name)) {
      return namePrefixNeedsService ? hasService : true;
    }

    // Proprietary service UUID may stand alone (JoySuny FCF0 only).
    if (serviceAloneMatches && hasService) return true;

    // Factor 2: generic service is trusted only WITH the expected characteristics.
    if (hasService &&
        expectedChars.isNotEmpty &&
        expectedChars.every(charUuids.contains)) {
      return true;
    }

    return false;
  }
}

/// The recognition table. JoySuny FIRST so the supported path always wins, then
/// the DETECT-only families. Easy to extend: append a row and a matcher test.
///
/// Sources: prior BLE research on common LiFePO4 BMS bluetooth stacks.
final List<BmsFamily> families = [
  // ---- Fully supported (connect + decode + log + controls + fleet) ----------
  // JoySuny (Sphere / RV): proprietary FCF0 service, FCF1 write / FCF2 notify.
  // Service alone may match (proprietary UUID), preserving original behaviour.
  const BmsFamily(
    name: 'JoySuny',
    namePrefixes: ['JS', 'RV', 'Sphere_', 'RV_'],
    serviceUuid: '0000fcf0-0000-1000-8000-00805f9b34fb',
    notifyChars: ['0000fcf2-0000-1000-8000-00805f9b34fb'],
    writeChars: ['0000fcf1-0000-1000-8000-00805f9b34fb'],
    supported: true,
    serviceAloneMatches: true,
  ),

  // ---- DETECT-only (recognised, surfaced, never connected/decoded) ----------
  // DECODE per family is FUTURE WORK: each speaks its own frame protocol.

  // JBD / Xiaoxiang / Overkill Solar: classic FF00 stack, FF01 notify / FF02 write.
  BmsFamily(
    name: 'JBD / Xiaoxiang',
    namePrefixes: const ['JBD-'],
    serviceUuid: u16('ff00'),
    notifyChars: [u16('ff01')],
    writeChars: [u16('ff02')],
  ),

  // Stealth (JBD/Xiaoxiang clone): same FF00 stack. "ST" is a very short prefix,
  // so a name hit is trusted ONLY when the FF00 service is also advertised.
  BmsFamily(
    name: 'Stealth BMS',
    namePrefixes: const ['ST'],
    serviceUuid: u16('ff00'),
    notifyChars: [u16('ff01')],
    writeChars: [u16('ff02')],
    namePrefixNeedsService: true,
  ),

  // JK-BMS (Jikong): FFE0 service, single FFE1 characteristic (notify + write).
  BmsFamily(
    name: 'JK-BMS',
    namePrefixes: const ['JK-', 'JK_'],
    serviceUuid: u16('ffe0'),
    notifyChars: [u16('ffe1')],
    writeChars: [u16('ffe1')],
  ),

  // ANT-BMS: also FFE0 / FFE1, distinguished from JK by the "ANT-BLE" name.
  BmsFamily(
    name: 'ANT-BMS',
    namePrefixes: const ['ANT-BLE'],
    serviceUuid: u16('ffe0'),
    notifyChars: [u16('ffe1')],
    writeChars: [u16('ffe1')],
  ),

  // Redodo / LiTime / Power Queen / Starry Sea (#75): FFE0 service, FFE1
  // notify / FFE2 write. Prefixes from aiobmsble's redodo_bms matcher. They are
  // short ("R-", "L-", "S-"), so a name hit is trusted ONLY with FFE0
  // advertised.
  BmsFamily(
    name: 'Redodo / LiTime',
    namePrefixes: const [
      'P-12', 'P-24', 'PQ-12', 'PQ-24', 'R-12', 'R-24', 'RO-12', 'RO-24', //
      'L-12', 'L-24', 'L-51', 'LT-12', 'LT-24', 'LT-51', 'S-', 'SS-',
    ],
    serviceUuid: u16('ffe0'),
    notifyChars: [u16('ffe1')],
    writeChars: [u16('ffe2')],
    namePrefixNeedsService: true,
  ),

  // Daly: FFF0 service, FFF1 notify / FFF2 write.
  BmsFamily(
    name: 'Daly BMS',
    namePrefixes: const ['DL-'],
    serviceUuid: u16('fff0'),
    notifyChars: [u16('fff1')],
    writeChars: [u16('fff2')],
  ),

  // LiFePO4POWER / Offgridtec: FFF0 service, FFF4 notify / FFF6 write; the
  // advertised name CONTAINS "SmartBat" (vendor text varies around it).
  BmsFamily(
    name: 'LiFePO4POWER / Offgridtec',
    nameContains: 'SmartBat',
    serviceUuid: u16('fff0'),
    notifyChars: [u16('fff4')],
    writeChars: [u16('fff6')],
  ),
];

/// Recognise the BMS family of a scan result, or null if none match.
///
/// [name] advertised name (may be empty), [serviceUuids] advertised service
/// UUIDs, [charUuids] any known characteristic UUIDs (usually empty at scan
/// time). All UUIDs are compared case-insensitively in 128-bit form. Returns the
/// FIRST matching family, so JoySuny (the supported path) always wins.
BmsFamily? matchBmsFamily({
  required String name,
  Iterable<String> serviceUuids = const [],
  Iterable<String> charUuids = const [],
}) {
  final services = serviceUuids.map((u) => u.toLowerCase()).toSet();
  final chars = charUuids.map((u) => u.toLowerCase()).toSet();
  for (final f in families) {
    if (f.matches(name: name, serviceUuids: services, charUuids: chars)) {
      return f;
    }
  }
  return null;
}

/// A BMS device recognised in range but NOT of the supported (JoySuny) family.
///
/// DETECT-only marker: it carries just enough to show a muted list entry and an
/// info sheet. It is deliberately NOT a [BatteryConnection] — there is no link,
/// no handshake, no parser, no logging stream. DECODE support is future work.
class DetectedDevice {
  final String deviceId;
  final BmsFamily family;
  final String name;
  int rssi;

  /// L12: the scan generation this device was last sighted in (set by the
  /// manager on every sighting). A device not re-sighted for
  /// `BatteryManager.detectedStaleScans` scan windows is pruned from the list.
  int lastSeenScan;

  DetectedDevice({
    required this.deviceId,
    required this.family,
    required this.name,
    required this.rssi,
    this.lastSeenScan = 0,
  });
}
