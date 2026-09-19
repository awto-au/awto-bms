/// Shared base for the shared_preferences-backed stores (review pass C1).
///
/// [SettingsStore], [SharedPrefsFleetStore] and [AliasStore] each used to
/// hand-roll `SharedPreferences.getInstance()` + `try/catch` around every read
/// and write. [PrefsStore] centralises that: every accessor is best-effort
/// (a missing plugin or a corrupt value falls back to the default) and every
/// failure is recorded through [guard] so it is visible in Diagnostics instead
/// of vanishing. Keys are owned by the subclasses and are UNCHANGED, so data
/// persisted by earlier builds still loads.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics.dart';

class PrefsStore {
  /// Label used as the [AppLog] source for this store's failures.
  final String source;

  /// The preferences provider. Injectable so tests can simulate an unavailable
  /// plugin (a provider that throws); defaults to the real instance.
  final Future<SharedPreferences> Function() _prefs;

  PrefsStore(this.source, {Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  Future<bool> readBool(String key, {required bool fallback}) async =>
      await guard<bool>('read $key', () async {
        final p = await _prefs();
        return p.getBool(key) ?? fallback;
      }, fallback: fallback, source: source) ??
      fallback;

  Future<void> writeBool(String key, bool value) => guard<void>(
      'write $key', () async => (await _prefs()).setBool(key, value),
      source: source);

  Future<String?> readString(String key) => guard<String?>(
      'read $key', () async => (await _prefs()).getString(key),
      source: source);

  Future<void> writeString(String key, String value) => guard<void>(
      'write $key', () async => (await _prefs()).setString(key, value),
      source: source);

  Future<List<String>?> readStringList(String key) => guard<List<String>?>(
      'read $key', () async => (await _prefs()).getStringList(key),
      source: source);

  Future<void> writeStringList(String key, List<String> value) =>
      guard<void>('write $key',
          () async => (await _prefs()).setStringList(key, value),
          source: source);

  /// The JSON-decoded value stored under [key] (a Map / List / scalar), or null
  /// when absent, empty, unreadable or not valid JSON.
  Future<Object?> readJson(String key) async {
    final raw = await readString(key);
    if (raw == null || raw.isEmpty) return null;
    return guardSync<Object?>('decode $key', () => jsonDecode(raw),
        source: source);
  }

  Future<void> writeJson(String key, Object value) =>
      writeString(key, jsonEncode(value));
}
