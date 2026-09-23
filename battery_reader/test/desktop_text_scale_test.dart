/// Desktop type scale: on a Windows / Linux / macOS host the app renders its
/// text at [kDesktopTextScale] (−25 %) through the MaterialApp builder; mobile
/// is untouched. The layout tests pump the list page and the detail page under
/// a desktop-sized MediaQuery WITH the scaler and require a clean frame (an
/// overflow is reported through FlutterError and fails the test).
library;

import 'package:battery_reader/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pump [total] in [step]s (the demo fleet emits every second, so the tree
/// never settles; pumpAndSettle would time out).
Future<void> pumpFor(WidgetTester tester, Duration total,
    {Duration step = const Duration(milliseconds: 100)}) async {
  var left = total;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

/// A desktop-sized window: 1280x800 logical at 1x.
Future<void> desktopView(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The app shell with the desktop scaler FORCED on (host-independent), so the
/// layout checks below exercise 0.75 whether or not the test host is desktop.
Widget forcedDesktopApp(Widget home) => MaterialApp(
      navigatorKey: gNavKey,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: desktopTextScaler(TextScaler.noScaling)),
        child: child!,
      ),
      home: home,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'demo_mode_v1': true});
  });

  group('desktop text scaler', () {
    test('is a single 0.75 factor', () {
      expect(kDesktopTextScale, 0.75);
      expect(desktopTextScaler(TextScaler.noScaling),
          const TextScaler.linear(kDesktopTextScale));
    });

    test('composes with the platform scaler by multiplying', () {
      // Windows "Text size" at 200 % x the desktop factor = 1.5.
      final s = desktopTextScaler(const TextScaler.linear(2.0));
      expect(s.scale(10), closeTo(15, 1e-9));
      expect(s, const TextScaler.linear(1.5));
      // Unchanged platform scaling: exactly linear(0.75).
      expect(desktopTextScaler(TextScaler.noScaling).scale(16),
          closeTo(12, 1e-9));
    });

    testWidgets('the app builder applies it on desktop only', (tester) async {
      TextScaler? seen;
      await tester.pumpWidget(MaterialApp(
        builder: desktopTextScaleBuilder,
        home: Builder(builder: (ctx) {
          seen = MediaQuery.textScalerOf(ctx);
          return const SizedBox();
        }),
      ));
      // On a desktop test host (this laptop) the scaler is the desktop one;
      // on a mobile-style host (web / CI phone target) the tree is untouched.
      expect(
          seen,
          isDesktopHost
              ? const TextScaler.linear(kDesktopTextScale)
              : TextScaler.noScaling);
    });

    testWidgets('BatteryReaderApp wires the builder', (tester) async {
      final app = const BatteryReaderApp().build(_FakeContext());
      expect(app, isA<MaterialApp>());
      expect((app as MaterialApp).builder, same(desktopTextScaleBuilder));
    });
  });

  group('desktop layout at 0.75 renders without overflow', () {
    testWidgets('list page (demo fleet) at 1280x800', (tester) async {
      await desktopView(tester);
      await tester.pumpWidget(forcedDesktopApp(const BatteryListPage()));
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.text('Batteries'), findsOneWidget);
      expect(find.textContaining('JS-2C14AA'), findsWidgets);
      expect(tester.takeException(), isNull);
      // The scaler really is in force below the navigator.
      final ctx = tester.element(find.text('Batteries'));
      expect(MediaQuery.textScalerOf(ctx),
          const TextScaler.linear(kDesktopTextScale));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('detail page (demo fleet) at 1280x800', (tester) async {
      await desktopView(tester);
      await tester.pumpWidget(forcedDesktopApp(const BatteryListPage()));
      await pumpFor(tester, const Duration(seconds: 3));
      await tester.tap(find.textContaining('JS-2C14AA').first);
      await pumpFor(tester, const Duration(seconds: 3));
      expect(find.byType(BatteryDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      final ctx = tester.element(find.byType(BatteryDetailPage));
      expect(MediaQuery.textScalerOf(ctx),
          const TextScaler.linear(kDesktopTextScale));
      // Walk the whole lazily-built page: every section laid out cleanly.
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 12; i++) {
        await tester.drag(scrollable, const Offset(0, -400));
        await pumpFor(tester, const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
      await tester.pageBack();
      await pumpFor(tester, const Duration(seconds: 2));
      expect(find.text('Batteries'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

/// [BatteryReaderApp.build] reads nothing from its context.
class _FakeContext extends Fake implements BuildContext {}
