/// App entry point: the guarded zone, the desktop SQLite factory, the two
/// loggers and the [MaterialApp]. Since #68 every screen, section and row
/// widget lives in its own file — the phone list page, the detail view, the
/// desktop two-pane shell and the shared sections (lib/sections/) — and the
/// app-level state is [AppSession]. This file keeps re-exporting the public
/// symbols the widget tests import from it.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'adaptive_scaffold.dart';
import 'battery_log.dart';
import 'desktop_scale.dart';
import 'fmt.dart' show logLine;
import 'nav.dart';
import 'raw_log.dart';

export 'adaptive_scaffold.dart' show AdaptiveScaffold, AdaptiveScaffoldState;
export 'alias_dialog.dart' show editBatteryAlias;
export 'app_session.dart' show AppSession, listPageSignature;
export 'app_theme.dart'; // kGreen / kRed / kIdle / kTrack, effState, alertBeep
export 'battery_detail.dart'
    show BatteryDetailPage, BatteryDetailView, DetailArrangement;
export 'battery_list_page.dart' show BatteryListPage;
export 'desktop_scale.dart'; // kDesktopTextScale, isDesktopHost, the scaler
export 'desktop_shell.dart' show DesktopShell, DesktopTab, kDesktopMinWidth;
export 'fmt.dart'; // shared formatters (fSignedA, pluralBatteries, …)
export 'nav.dart' show gNavKey;
export 'sections/fleet_total.dart' show FleetTotal;
export 'sections/signal_chip.dart' show SignalChip, rssiIcon, rssiColor;
export 'sections/summary_card.dart' show SummaryCard;
export 'sections/trends_section.dart' show LoggingLine, TrendsSection;
export 'settings_page.dart' show SettingsPage;
export 'temp_unit.dart'; // #43: fmtTemp/fChipTemp/etc importable via main.dart
export 'write_actions.dart' show writeFailureReason, runWrite, BusyWrites;

Future<void> main() async {
  // Defensive hygiene (issue #49): run the whole app inside a guarded zone with
  // a FlutterError handler, so a stray BLE/transport/async error is logged and
  // SWALLOWED rather than tearing down the Flutter engine or closing the desktop
  // window. The reconnect loop keeps running through any transient BLE failure.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Framework errors (build/layout/async caught by Flutter) — log, don't crash.
    FlutterError.onError = (details) {
      FlutterError.dumpErrorToConsole(details);
    };
    // Async errors that reach the engine outside a Flutter callback — mark handled
    // so the process stays alive (return true = we dealt with it).
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      // ignore: avoid_print
      logLine('UNCAUGHT', '$error');
      return true;
    };
    // sqflite ships no desktop implementation, so on Windows/Linux/macOS swap in
    // the FFI factory (WinRT-safe, uses the bundled SQLite) before the interval
    // store opens. Mobile keeps the default sqflite factory untouched. The DB
    // filename and schema are identical either way (see battery_log.dart).
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    // Open the on-device time-series store up front (idempotent; disables itself
    // silently if SQLite is unavailable).
    await BatteryLogger.instance.init();
    // Open the verbose single-file raw log (issue #19). Append-only; resolves a
    // per-platform path and disables itself silently if none is writable.
    await RawLogger.instance.init();
    runApp(const BatteryReaderApp());
  }, (error, stack) {
    // Last resort: anything that escapes to the zone is logged and swallowed.
    // ignore: avoid_print
    logLine('ZONE-UNCAUGHT', '$error');
  });
}

class BatteryReaderApp extends StatelessWidget {
  const BatteryReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Battery Reader',
      navigatorKey: gNavKey,
      // #68: lets the shell's keyboard handler see which page is on top.
      navigatorObservers: [gRouteTracker],
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        // Issue #30(b): pin an explicit, opaque scaffold background so no
        // default/placeholder window background (the "zebra" striping) can show
        // through — the app is a solid theme colour edge to edge.
        scaffoldBackgroundColor: scheme.surface,
        useMaterial3: true,
      ),
      // Desktop: −25 % type via the composed text scaler (mobile untouched).
      builder: desktopTextScaleBuilder,
      // #68: ONE responsive shell — the phone navigation below 900 px, the
      // two-pane desktop layout from 900 px, the same widgets in both.
      home: const AdaptiveScaffold(),
    );
  }
}
