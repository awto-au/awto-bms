import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/bms_families.dart';

/// Pass 4 (issue #15): the BMS-family recognition matcher.
///
/// Verifies the DETECT-only two-factor matching: name-prefix recognition for
/// each family, the "generic service + expected characteristics" rule, that a
/// bare generic service (FF00/FFE0/FFF0) with no known name and no expected
/// characteristics does NOT match, and that JoySuny stays the supported path.
void main() {
  // 16-bit -> 128-bit stock UUID (mirrors bms_families.u16).
  String s(String hex4) => '0000$hex4-0000-1000-8000-00805f9b34fb';
  final fcf0 = s('fcf0');
  final fcf1 = s('fcf1');
  final fcf2 = s('fcf2');

  group('JoySuny stays the fully-supported path', () {
    test('JS / RV / Sphere_ / RV_ name prefixes match JoySuny (supported)', () {
      for (final n in ['JS-2C14AA', 'RV-1180E2', 'Sphere_01', 'RV_9000']) {
        final f = matchBmsFamily(name: n);
        expect(f, isNotNull, reason: n);
        expect(f!.name, 'JoySuny');
        expect(f.supported, isTrue);
      }
    });

    test('the proprietary FCF0 service matches on service ALONE (no name)', () {
      final f = matchBmsFamily(name: '', serviceUuids: [fcf0]);
      expect(f, isNotNull);
      expect(f!.name, 'JoySuny');
      expect(f.supported, isTrue);
    });

    test('FCF0 + FCF1/FCF2 characteristics also match JoySuny', () {
      final f = matchBmsFamily(
        name: '',
        serviceUuids: [fcf0],
        charUuids: [fcf1, fcf2],
      );
      expect(f?.name, 'JoySuny');
    });
  });

  group('other families are DETECT-only (recognised, not supported)', () {
    test('JBD- name prefix -> JBD / Xiaoxiang, unsupported', () {
      final f = matchBmsFamily(name: 'JBD-AABBCC');
      expect(f?.name, 'JBD / Xiaoxiang');
      expect(f!.supported, isFalse);
    });

    test('JK- and JK_ name prefixes -> JK-BMS, unsupported', () {
      for (final n in ['JK-B2A8S', 'JK_B1A24S']) {
        final f = matchBmsFamily(name: n);
        expect(f?.name, 'JK-BMS', reason: n);
        expect(f!.supported, isFalse);
      }
    });

    test('DL- name prefix -> Daly BMS, unsupported', () {
      final f = matchBmsFamily(name: 'DL-40D63C');
      expect(f?.name, 'Daly BMS');
      expect(f!.supported, isFalse);
    });

    test('ANT-BLE name prefix -> ANT-BMS, unsupported', () {
      final f = matchBmsFamily(name: 'ANT-BLE24DXXX');
      expect(f?.name, 'ANT-BMS');
      expect(f!.supported, isFalse);
    });

    test('name CONTAINING "SmartBat" -> LiFePO4POWER / Offgridtec', () {
      final f = matchBmsFamily(name: 'Offgridtec-SmartBat-12V');
      expect(f?.name, 'LiFePO4POWER / Offgridtec');
      expect(f!.supported, isFalse);
    });
  });

  group('two-factor: generic service + expected characteristics', () {
    test('FF00 + FF01/FF02 chars matches a JBD-family device (no name)', () {
      final f = matchBmsFamily(
        name: '',
        serviceUuids: [s('ff00')],
        charUuids: [s('ff01'), s('ff02')],
      );
      expect(f, isNotNull);
      expect(f!.supported, isFalse);
      // Both JBD and Stealth are FF00/FF01/FF02 clones; the first table row wins.
      expect(f.serviceUuid, s('ff00'));
    });

    test('FFE0 + FFE1 char matches an FFE0-family device (JK/ANT)', () {
      final f = matchBmsFamily(
        name: '',
        serviceUuids: [s('ffe0')],
        charUuids: [s('ffe1')],
      );
      expect(f, isNotNull);
      expect(f!.serviceUuid, s('ffe0'));
      expect(f.supported, isFalse);
    });

    test('FFF0 + FFF1/FFF2 chars matches a Daly device', () {
      final f = matchBmsFamily(
        name: '',
        serviceUuids: [s('fff0')],
        charUuids: [s('fff1'), s('fff2')],
      );
      expect(f?.name, 'Daly BMS');
    });

    test('UUID case is ignored', () {
      final f = matchBmsFamily(
        name: '',
        serviceUuids: ['0000FFE0-0000-1000-8000-00805F9B34FB'],
        charUuids: ['0000FFE1-0000-1000-8000-00805F9B34FB'],
      );
      expect(f, isNotNull);
      expect(f!.serviceUuid, s('ffe0'));
    });
  });

  group('bare generic services must NOT false-match', () {
    test('FF00 alone (no name, no chars) does NOT match', () {
      expect(matchBmsFamily(name: '', serviceUuids: [s('ff00')]), isNull);
    });
    test('FFE0 alone (no name, no chars) does NOT match', () {
      expect(matchBmsFamily(name: '', serviceUuids: [s('ffe0')]), isNull);
    });
    test('FFF0 alone (no name, no chars) does NOT match', () {
      expect(matchBmsFamily(name: '', serviceUuids: [s('fff0')]), isNull);
    });
    test('a generic service with WRONG chars does NOT match', () {
      final f = matchBmsFamily(
        name: '',
        serviceUuids: [s('ff00')],
        charUuids: [s('dead'), s('beef')],
      );
      expect(f, isNull);
    });
    test('a totally unknown gadget (name + service) does NOT match', () {
      final f = matchBmsFamily(
        name: 'HMSoft',
        serviceUuids: [s('ffe0')],
      );
      expect(f, isNull);
    });
  });

  group('short "ST" prefix is gated behind the FF00 service', () {
    test('ST name WITHOUT the FF00 service does NOT match (false-positive guard)',
        () {
      expect(matchBmsFamily(name: 'ST-Link-Dongle'), isNull);
    });
    test('ST name WITH the FF00 service matches Stealth BMS', () {
      final f = matchBmsFamily(name: 'ST-4S100A', serviceUuids: [s('ff00')]);
      expect(f?.name, 'Stealth BMS');
      expect(f!.supported, isFalse);
    });
  });

  test('empty scan (no name, no service) matches nothing', () {
    expect(matchBmsFamily(name: ''), isNull);
  });
}
