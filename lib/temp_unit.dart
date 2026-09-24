/// Temperature-unit display helpers (#43). Display-only: stored, logged and BMS
/// values always stay in °C — only the presentation switches to °F when the
/// Settings toggle is on. Kept in this neutral library (no Flutter/DB) so both
/// the main UI and the charts screen share ONE conversion + formatter, and the
/// pure converters stay trivially unit-testable.
library;

/// Whether temperatures are displayed in °F (true) or °C (false, default).
/// Restored from [SettingsStore] at start-up and flipped from the Settings page.
bool gUseFahrenheit = false;

/// °F = °C × 9/5 + 32. Pure.
double celsiusToFahrenheit(double c) => c * 9 / 5 + 32;

/// The unit suffix for the current display choice ("°C" / "°F").
String get tempUnitLabel => gUseFahrenheit ? '°F' : '°C';

/// Pure temperature formatter: [celsius] is always in °C; render it in the
/// requested unit. null -> em dash. °F is rounded to a whole degree.
String fmtTempUnit(int? celsius, {required bool fahrenheit}) {
  if (celsius == null) return '—';
  if (!fahrenheit) return '$celsius °C';
  return '${celsiusToFahrenheit(celsius.toDouble()).round()} °F';
}

/// Pure chip-temperature formatter: 0 is "not reported" (see [fChipTemp]).
String fmtChipTempUnit(int? celsius, {required bool fahrenheit}) =>
    celsius == null
        ? '—'
        : (celsius == 0
            ? '— (not reported)'
            : fmtTempUnit(celsius, fahrenheit: fahrenheit));

/// Temperature readout in the chosen unit (temp0..temp3, probes, etc.).
String fmtTemp(int? v) => fmtTempUnit(v, fahrenheit: gUseFahrenheit);

/// Chip temperature is byte[7] of the Battery-data frame, which THIS firmware
/// never populates — it is 0 in every frame on real hardware. Showing a flat
/// "0 °C" is misleading, so render 0 as "not reported". The real pack temps
/// (temp0..temp3, from the Temperatures frame) are unaffected and use [fmtTemp].
String fChipTemp(int? v) => fmtChipTempUnit(v, fahrenheit: gUseFahrenheit);
