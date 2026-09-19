import 'package:flutter_test/flutter_test.dart';
import 'package:battery_reader/temp_unit.dart';

/// #43: temperature-unit conversion + formatting. Pure functions — no Flutter/DB.
void main() {
  group('celsiusToFahrenheit', () {
    test('key points', () {
      expect(celsiusToFahrenheit(0), 32);
      expect(celsiusToFahrenheit(100), 212);
      expect(celsiusToFahrenheit(25), 77);
      expect(celsiusToFahrenheit(-40), -40); // the crossover point
      expect(celsiusToFahrenheit(37), closeTo(98.6, 1e-9));
    });
  });

  group('fmtTempUnit', () {
    test('celsius renders with a °C suffix', () {
      expect(fmtTempUnit(25, fahrenheit: false), '25 °C');
      expect(fmtTempUnit(-3, fahrenheit: false), '-3 °C');
      expect(fmtTempUnit(0, fahrenheit: false), '0 °C');
    });
    test('fahrenheit converts and rounds to a whole degree', () {
      expect(fmtTempUnit(25, fahrenheit: true), '77 °F');
      expect(fmtTempUnit(0, fahrenheit: true), '32 °F');
      expect(fmtTempUnit(100, fahrenheit: true), '212 °F');
      expect(fmtTempUnit(37, fahrenheit: true), '99 °F'); // 98.6 -> 99
    });
    test('null renders as an em dash in either unit', () {
      expect(fmtTempUnit(null, fahrenheit: false), '—');
      expect(fmtTempUnit(null, fahrenheit: true), '—');
    });
  });

  group('fmtChipTempUnit (not-reported case)', () {
    test('0 renders as "not reported", never a misleading 0°', () {
      expect(fmtChipTempUnit(0, fahrenheit: false), '— (not reported)');
      expect(fmtChipTempUnit(0, fahrenheit: true), '— (not reported)');
    });
    test('null renders as an em dash', () {
      expect(fmtChipTempUnit(null, fahrenheit: false), '—');
      expect(fmtChipTempUnit(null, fahrenheit: true), '—');
    });
    test('a real value converts like any temperature', () {
      expect(fmtChipTempUnit(25, fahrenheit: false), '25 °C');
      expect(fmtChipTempUnit(25, fahrenheit: true), '77 °F');
    });
  });

  group('global-driven wrappers + label', () {
    tearDown(() => gUseFahrenheit = false); // restore the default
    test('fmtTemp / fChipTemp / tempUnitLabel follow the global flag', () {
      gUseFahrenheit = false;
      expect(fmtTemp(25), '25 °C');
      expect(fChipTemp(0), '— (not reported)');
      expect(tempUnitLabel, '°C');

      gUseFahrenheit = true;
      expect(fmtTemp(25), '77 °F');
      expect(fChipTemp(25), '77 °F');
      expect(fChipTemp(0), '— (not reported)');
      expect(tempUnitLabel, '°F');
    });
  });
}
