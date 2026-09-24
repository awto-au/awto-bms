/// #100 UI size matrix: the app's main screens in DEMO mode (DEMO-1..4) at
/// phone and desktop window sizes, at the text scales each size really runs
/// at, with real fonts (Roboto; Segoe UI for the Windows runs when this
/// machine has it), so an overflow reported here is a real one.
///
///  * Phone sizes (360x640, 400x800, 412x915): text scale 1.0 (Android). The
///    Windows window cannot be narrower than 900x600, so the desktop 0.75
///    scaler never meets these sizes.
///  * Desktop sizes (900x600, 1280x800, 1920x1080): 1.0 (an Android tablet)
///    AND 0.75 with the Windows platform (the desktop build).
///
/// Each combination walks the list + fleet, the battery detail (scrolled
/// through page by page), the charts and the settings, and fails on ANY
/// framework error (RenderFlex overflow, layout exception), listing every one
/// it saw with the size and screen.
///
/// PNGs: run with `--dart-define=UI_MATRIX_PNG=true` (the runner
/// `scripts/ui_matrix.py` does) and every screen / scroll page is written to
/// `build/ui_matrix/` (git-ignored). Without the define the test only checks.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:battery_reader/battery_charts.dart' show BatteryChartsPage;
import 'package:battery_reader/battery_list_page.dart' show BatteryListView;
import 'package:battery_reader/main.dart';
import 'package:battery_reader/nav.dart' show gRouteTracker;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'real_fonts.dart';

/// Write PNGs (set by `scripts/ui_matrix.py`).
const bool kWritePngs = bool.fromEnvironment('UI_MATRIX_PNG');

/// Where the PNGs land, relative to the project directory (git-ignored).
const String kOutDir = 'build/ui_matrix';

/// One window size and the text scales it runs at.
class MatrixSize {
  final double w;
  final double h;
  const MatrixSize(this.w, this.h);
  bool get wide => w >= kDesktopMinWidth;
  String get label => '${w.toInt()}x${h.toInt()}';

  /// Phone sizes: 1.0 only. Desktop sizes: 1.0 and the desktop 0.75.
  List<double> get scales =>
      wide ? const [1.0, kDesktopTextScale] : const [1.0];
}

const List<MatrixSize> kMatrixSizes = [
  MatrixSize(360, 640),
  MatrixSize(400, 800),
  MatrixSize(412, 915),
  MatrixSize(900, 600),
  MatrixSize(1280, 800),
  MatrixSize(1920, 1080),
];

/// Most scroll pages captured per screen (the detail page is the longest).
const int kMaxPages = 12;

// --- app ---------------------------------------------------------------------

final GlobalKey _shotKey = GlobalKey();

/// [BatteryReaderApp] as it ships (its theme, navigator key, route tracker and
/// home), with the text scale FORCED to [scale] rather than taken from the
/// test host, inside a boundary the PNGs are taken from.
Widget matrixApp(double scale) {
  final real = const BatteryReaderApp().build(_NoContext()) as MaterialApp;
  return RepaintBoundary(
    key: _shotKey,
    child: MaterialApp(
      title: real.title,
      navigatorKey: gNavKey,
      navigatorObservers: [gRouteTracker],
      debugShowCheckedModeBanner: false,
      theme: real.theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: real.home,
    ),
  );
}

/// Pump [total] in 100 ms steps (the demo fleet ticks every second, so the
/// tree never settles).
Future<void> pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  var left = total;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

/// The screen's main vertical scrollable: the tallest one scrolling down
/// under [within] (charts / selectors scroll sideways; small ones are nested).
ScrollableState? mainScrollable(WidgetTester tester, Finder within) {
  final all = tester
      .stateList<ScrollableState>(
          find.descendant(of: within, matching: find.byType(Scrollable)))
      .where((s) => s.axisDirection == AxisDirection.down)
      .toList();
  if (all.isEmpty) return null;
  double h(ScrollableState s) =>
      (s.context.findRenderObject() as RenderBox).size.height;
  all.sort((a, b) => h(b).compareTo(h(a)));
  return all.first;
}

class MatrixRun {
  final WidgetTester tester;
  final String combo;
  final List<String> errors = [];
  final List<String> written = [];
  String screen = '';
  MatrixRun(this.tester, this.combo);

  Future<void> shot(String name) async {
    screen = name;
    await tester.pump();
    if (!kWritePngs) return;
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
    final file = File('$kOutDir/${combo}_$name.png');
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
    });
    written.add(file.path);
  }

  /// Capture [name] page by page down the main scrollable under [within].
  Future<void> pages(String name, Finder within) async {
    final s = mainScrollable(tester, within);
    if (s == null) {
      await shot(name);
      return;
    }
    s.position.jumpTo(0);
    for (var i = 1; i <= kMaxPages; i++) {
      await tester.pump();
      await shot('${name}_${i.toString().padLeft(2, '0')}');
      final p = s.position;
      if (p.pixels >= p.maxScrollExtent) break;
      p.jumpTo(
          (p.pixels + p.viewportDimension * 0.9).clamp(0.0, p.maxScrollExtent));
      await pumpFor(tester, const Duration(milliseconds: 200));
    }
    s.position.jumpTo(0);
    await tester.pump();
  }
}

Future<void> runPhone(MatrixRun r) async {
  final t = r.tester;
  // List + fleet.
  await r.shot('list');
  // Detail: the first demo pack.
  r.screen = 'detail';
  await t.tap(find.textContaining('DEMO 1').first);
  await pumpFor(t, const Duration(seconds: 2));
  expect(find.byType(BatteryDetailPage), findsOneWidget, reason: r.combo);
  await r.pages('detail', find.byType(BatteryDetailPage));
  // Charts (from the detail app bar).
  r.screen = 'charts';
  await t.tap(find.byTooltip('Charts / history'));
  await pumpFor(t, const Duration(seconds: 4));
  await r.pages('charts', find.byType(BatteryChartsPage));
  gNavKey.currentState!.pop();
  await pumpFor(t, const Duration(seconds: 1));
  gNavKey.currentState!.pop();
  await pumpFor(t, const Duration(seconds: 1));
  // Settings (from the list app bar).
  r.screen = 'settings';
  await t.tap(find.byTooltip('Settings'));
  await pumpFor(t, const Duration(seconds: 1));
  expect(find.byType(SettingsPage), findsOneWidget, reason: r.combo);
  await r.pages('settings', find.byType(SettingsPage));
  gNavKey.currentState!.pop();
  await pumpFor(t, const Duration(seconds: 1));
}

Future<void> runDesktop(MatrixRun r) async {
  final t = r.tester;
  expect(find.byType(DesktopShell), findsOneWidget, reason: r.combo);
  // Detail tab (DEMO-1 selected by default): the left pane is in every shot.
  await r.pages('detail', find.byType(BatteryDetailView));
  r.screen = 'charts';
  await t.tap(find.text('Charts'));
  await pumpFor(t, const Duration(seconds: 4));
  await r.pages('charts', find.byType(BatteryChartsPage));
  r.screen = 'settings';
  await t.tap(find.text('Settings').first);
  await pumpFor(t, const Duration(seconds: 1));
  expect(find.byType(SettingsPage), findsOneWidget, reason: r.combo);
  await r.pages('settings', find.byType(SettingsPage));
  // The left pane scrolled to its end (the offline / other rows).
  r.screen = 'list';
  await t.tap(find.text('Detail'));
  await pumpFor(t, const Duration(seconds: 1));
  await r.pages('list', find.byType(BatteryListView));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadRealFonts();
    if (kWritePngs) {
      final out = Directory(kOutDir);
      if (out.existsSync()) out.deleteSync(recursive: true);
    }
  });

  setUp(() {
    // Demo mode with DEMO-1..3 starred, so the fleet panel has members and
    // the list shows both groups (fleet, then DEMO-4 outside it).
    SharedPreferences.setMockInitialValues({
      'demo_mode_v1': true,
      'fleet_serials_v1': ['DEMO-1', 'DEMO-2', 'DEMO-3'],
    });
  });

  for (final size in kMatrixSizes) {
    for (final scale in size.scales) {
      final desktop = scale != 1.0;
      final combo = '${size.label}_${desktop ? 'win075' : 'android100'}';
      testWidgets('#100 $combo: every main screen renders without an error',
          (tester) async {
        tester.view.physicalSize = Size(size.w, size.h);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final r = MatrixRun(tester, combo);
        final previous = FlutterError.onError;
        FlutterError.onError = (d) {
          final first = d.exceptionAsString().split('\n').first;
          r.errors.add('$combo ${r.screen}: $first');
        };
        if (desktop) {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        }
        try {
          await tester.pumpWidget(matrixApp(scale));
          await pumpFor(tester, const Duration(seconds: 3));
          expect(find.textContaining('DEMO 1'), findsWidgets, reason: combo);
          if (size.wide) {
            await runDesktop(r);
          } else {
            await runPhone(r);
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        } finally {
          debugDefaultTargetPlatformOverride = null;
          FlutterError.onError = previous;
        }
        if (kWritePngs) {
          // ignore: avoid_print
          print('#100 $combo: ${r.written.length} PNGs in $kOutDir'
              '${desktop && !gRealSegoe ? ' (Roboto standing in for Segoe UI)' : ''}');
        }
        expect(r.errors, isEmpty, reason: r.errors.join('\n'));
      });
    }
  }
}

/// [BatteryReaderApp.build] reads nothing from its context.
class _NoContext extends Fake implements BuildContext {}
