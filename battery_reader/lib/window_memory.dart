/// #68: remember the desktop window's size / position across launches. The
/// Windows runner (windows/runner/flutter_window.cpp) exposes a tiny method
/// channel: `getBounds` / `setBounds` / `maximize` and a `boundsChanged`
/// callback after every move / resize (WM_EXITSIZEMOVE, maximize / restore).
/// This class restores the persisted [WindowBounds] once at start-up and
/// saves (debounced) whenever the runner reports a change. Desktop only;
/// every channel call is best-effort (a missing runner implementation, as in
/// the widget tests, is recorded once and otherwise ignored).
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'diagnostics.dart';
import 'settings_store.dart';

class WindowMemory {
  static const channel = MethodChannel('battery_reader/window');
  static const _source = 'WindowMemory';

  /// Saves are coalesced: the runner reports every restore / maximize step.
  static const saveDelay = Duration(milliseconds: 500);

  final SettingsStore settings;
  Timer? _debounce;
  WindowBounds? _pending;
  bool _restored = false;

  WindowMemory(this.settings);

  /// Register for the runner's change reports and apply the saved bounds (if
  /// any). Idempotent; safe to call where no runner channel exists.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    channel.setMethodCallHandler(_onCall);
    final saved = await settings.loadWindowBounds();
    if (saved == null) return;
    try {
      await channel.invokeMethod<void>('setBounds', saved.toMap());
      if (saved.maximized) await channel.invokeMethod<void>('maximize');
    } on MissingPluginException {
      // No runner implementation (mobile, tests): nothing to restore.
    } catch (e) {
      AppLog.instance.record(_source, 'restore failed: $e');
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'boundsChanged') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final b = WindowBounds.fromMap(args);
    if (b == null) return null;
    scheduleSave(b);
    return null;
  }

  /// Persist [b] after [saveDelay] (later reports replace it). A maximized
  /// report keeps the last NORMAL bounds and only flips the flag, so restoring
  /// un-maximizes to the size the user had before.
  void scheduleSave(WindowBounds b) {
    _pending = b;
    _debounce?.cancel();
    _debounce = Timer(saveDelay, flush);
  }

  /// Write the pending bounds now (the debounce timer's body).
  Future<void> flush() async {
    _debounce?.cancel();
    _debounce = null;
    final b = _pending;
    if (b == null) return;
    _pending = null;
    var toSave = b;
    if (b.maximized) {
      final prev = await settings.loadWindowBounds();
      if (prev != null) {
        toSave = WindowBounds(
            left: prev.left,
            top: prev.top,
            width: prev.width,
            height: prev.height,
            maximized: true);
      }
    }
    await settings.saveWindowBounds(toSave);
  }

  void dispose() {
    _debounce?.cancel();
    channel.setMethodCallHandler(null);
  }
}
