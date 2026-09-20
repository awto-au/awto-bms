/// GitHub #65: ONE status line per card / detail header, with liveness
/// folded in — and never a stale "Idle · no load" (or any charge state,
/// current, voltage) when there is no data behind it.
///
///  * [statusTextFor] — the pure text rules: streaming / stale / no-data
///    variants / offline placeholder / background sampling;
///  * a card for a silent connection has exactly ONE status line, reads
///    "No data · …", its figures are "—" and no "Idle" / "no load" / charge
///    state / voltage / current appears anywhere on it;
///  * a streaming card shows the state text and its dot flashes on
///    BAL_STATUS (#64 kept);
///  * the detail header follows the same rule;
///  * the fleet panel's Status is "No data" when nothing streams, and net
///    current / power exclude silent packs.
library;

import 'package:battery_reader/battery_connection.dart';
import 'package:battery_reader/battery_manager.dart';
import 'package:battery_reader/battery_protocol.dart';
import 'package:battery_reader/health_palette.dart';
import 'package:battery_reader/live_indicator.dart';
import 'package:battery_reader/main.dart';
import 'package:battery_reader/alias_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_57_test.dart' show pumpFor;
import 'fakes.dart';

const bal = [0xA8, 0xAC, 0x01, 1, 1, 0, 1, 0, 0, 0xB9, 0x21];

/// The status line's two figures (V and A) reading "—" — the 14 px texts;
/// the SOC "—" (22 px) and the RSSI chip's (12 px) are not the figures.
int dashFigures(WidgetTester tester) => tester
    .widgetList<Text>(find.text('—'))
    .where((t) => t.style?.fontSize == 14)
    .length;

/// Every piece of text on screen (plain and rich), for "never anywhere"
/// assertions.
List<String> allText(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        t.data ?? t.textSpan?.toPlainText() ?? '',
      for (final r in tester.widgetList<RichText>(find.byType(RichText)))
        r.text.toPlainText(),
    ];

void main() {
  const live = LiveStatus(LiveLevel.live, 'updated 0.4 s ago', hasData: true);
  const stale = LiveStatus(LiveLevel.stale, 'updated 5.2 s ago', hasData: true);

  group('statusTextFor — the pure text rules', () {
    test('streaming: the charge state alone, green dot, no "live" word', () {
      final s = statusTextFor(live, ChargeStateStyle.idle);
      expect(s.text, 'Idle · no load');
      expect(s.state, 'Idle · no load');
      expect(s.detail, isNull);
      expect(s.hasData, isTrue);
      expect(s.color, HealthPalette.healthy);
      expect(s.stateColor, HealthPalette.idle);
      expect(statusTextFor(live, ChargeStateStyle.charging).text, 'Charging');
      expect(statusTextFor(live, ChargeStateStyle.discharging).text,
          'Discharging');
      expect(s.text, isNot(contains('live')));
    });

    test('stale (3–10 s): the state + " · updated N s ago", amber dot', () {
      final s = statusTextFor(stale, ChargeStateStyle.charging);
      expect(s.text, 'Charging · updated 5.2 s ago');
      expect(s.state, 'Charging');
      expect(s.detail, 'updated 5.2 s ago');
      expect(s.hasData, isTrue);
      expect(s.color, Colors.amber);
      expect(s.stateColor, HealthPalette.healthy);
    });

    test('NO data: "No data · <reason>", never a charge state, red / amber',
        () {
      LiveStatus silent(StreamClass cls) => liveStatusFor(
          conn: ConnState.connected,
          silenceMs: 15000,
          nowMs: 0,
          streamClass: cls);
      for (final dir in [
        ChargeStateStyle.idle,
        ChargeStateStyle.charging,
        ChargeStateStyle.discharging,
      ]) {
        final dormant = statusTextFor(silent(StreamClass.dormant), dir);
        expect(dormant.text, 'No data · not streaming — BMS not running');
        expect(dormant.state, isNull);
        expect(dormant.hasData, isFalse);
        expect(dormant.color, HealthPalette.faultRed);
        expect(dormant.weight, FontWeight.w700);
        expect(dormant.text, isNot(contains(dir.label)));
        // #63: no reply reads exactly like dormant.
        expect(statusTextFor(silent(StreamClass.noResponse), dir), dormant);
      }
      expect(
          statusTextFor(silent(StreamClass.awakeNotStreaming),
                  ChargeStateStyle.idle)
              .text,
          'No data · BMS awake, not streaming');
      expect(
          statusTextFor(silent(StreamClass.unknown), ChargeStateStyle.idle)
              .text,
          'No data · not streaming — 15 s silent');
      // Connected, no telemetry yet on this link.
      final waiting = statusTextFor(
          liveStatusFor(
              conn: ConnState.connected,
              silenceMs: 800,
              nowMs: 0,
              hasFrameOnLink: false),
          ChargeStateStyle.idle);
      expect(waiting.text, 'No data · waiting for the first frame');
      expect(waiting.hasData, isFalse);
      expect(waiting.color, Colors.amber);
      // Connecting / not connected.
      expect(
          statusTextFor(
                  liveStatusFor(
                      conn: ConnState.connecting, silenceMs: null, nowMs: 0),
                  ChargeStateStyle.charging)
              .text,
          'No data · connecting…');
      expect(
          statusTextFor(
                  liveStatusFor(
                      conn: ConnState.disconnected, silenceMs: null, nowMs: 0),
                  ChargeStateStyle.charging)
              .text,
          'No data · not connected');
    });

    test('offline favourite placeholder: the existing "Offline · last seen"',
        () {
      const now = 10000000;
      final s = statusTextFor(
        liveStatusFor(conn: ConnState.disconnected, silenceMs: null, nowMs: now),
        ChargeStateStyle.idle,
        offline: true,
        lastSeenMs: now - 5 * 60 * 1000,
        nowMs: now,
      );
      expect(s.text, 'Offline · last seen 5 min ago');
      expect(s.state, isNull);
      expect(s.hasData, isFalse);
      expect(s.color, Colors.white38);
      expect(s.level, LiveLevel.offline);
    });

    test('background sampling: the last captured state + sample ages; '
        '"No data" only until the first sample', () {
      const now = 10000000;
      final sampled = liveStatusFor(
        conn: ConnState.disconnected,
        silenceMs: null,
        nowMs: now,
        sampling: true,
        lastFrameEverMs: now - 120000,
        nextDueMs: now + 180000,
      );
      final s = statusTextFor(sampled, ChargeStateStyle.idle);
      expect(s.text, 'Idle · no load · sampled 2 min ago · next in 3 min');
      expect(s.hasData, isTrue);
      expect(s.color, Colors.lightBlueAccent);
      final never = liveStatusFor(
        conn: ConnState.connecting,
        silenceMs: null,
        nowMs: now,
        sampling: true,
        lastFrameEverMs: null,
        nextDueMs: null,
      );
      expect(statusTextFor(never, ChargeStateStyle.idle).text,
          'No data · not sampled yet · sampling now');
      // Mid-sample, link up, first frame not yet in: still the last sample —
      // no "No data" blip on every sample.
      final midSample = liveStatusFor(
        conn: ConnState.connected,
        silenceMs: 700,
        nowMs: now,
        sampling: true,
        lastFrameEverMs: now - 120000,
        nextDueMs: now + 180000,
        hasFrameOnLink: false,
      );
      expect(midSample.level, LiveLevel.sampled);
      expect(midSample.hasData, isTrue);
      expect(statusTextFor(midSample, ChargeStateStyle.charging).text,
          'Charging · sampled 2 min ago · next in 3 min');
      // … and once the frame lands, the normal live rules.
      expect(
          liveStatusFor(
            conn: ConnState.connected,
            silenceMs: 100,
            nowMs: now,
            sampling: true,
          ).level,
          LiveLevel.live);
    });
  });

  group('the card and the detail header — one status line', () {
    var clock = DateTime.utc(2026, 9, 21, 12);

    BatteryManager manager() =>
        BatteryManager(transport: NoopTransport(), fleetStore: FakeFleetStore());

    /// A connected pack that streamed one cycle with a full "charging" state.
    Future<BatteryConnection> streamed(WidgetTester tester) async {
      clock = DateTime.utc(2026, 9, 21, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await tester.runAsync(() => c.connectTo('dev-1', name: 'dev-1'));
      c.parser.addBytes(bal);
      c.state
        ..serial = 'JS-TEST01'
        ..packVoltage = 53.21
        ..packCurrent = 12.3
        ..chargeState = ChargeState.charging
        ..socPercent = 80
        ..remainingAh = 80
        ..fullAh = 100;
      return c;
    }

    Widget app(Widget home) => MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          home: Scaffold(body: home),
        );

    Future<void> pumpCard(
            WidgetTester tester, BatteryConnection c, BatteryManager m) =>
        tester.pumpWidget(app(SummaryCard(
          conn: c,
          manager: m,
          onTap: () {},
          onToggleFleet: () {},
        )));

    void expectNoStaleState(WidgetTester tester) {
      for (final t in allText(tester)) {
        for (final stale in const [
          'Idle',
          'no load',
          'Charging',
          'Discharging',
          '53.21',
          '12.3 A',
        ]) {
          expect(t, isNot(contains(stale)), reason: 'stale "$stale" in "$t"');
        }
      }
    }

    testWidgets('silent pack: exactly ONE status line, "No data · …", '
        'figures "—", no charge state / V / A anywhere', (tester) async {
      final c = await streamed(tester);
      final m = manager();
      // The pack goes silent: 15 s without a frame, probe says dormant.
      clock = clock.add(const Duration(seconds: 15));
      c.streamClass = StreamClass.dormant;
      await pumpCard(tester, c, m);

      expect(find.byType(LiveStatusLine), findsOneWidget);
      expect(find.byType(LiveDot), findsOneWidget, reason: 'one dot');
      expect(find.text('No data · not streaming — BMS not running'),
          findsOneWidget);
      expect(dashFigures(tester), 2, reason: 'V and A read "—"');
      expect(find.text('80%'), findsOneWidget, reason: 'last SOC kept, dimmed');
      expectNoStaleState(tester);
      final line = tester.widget<LiveDot>(find.byType(LiveDot));
      expect(line.color, HealthPalette.faultRed);

      // #63: the same line without the 0x30; awake reads its verdict.
      c.streamClass = StreamClass.noResponse;
      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(find.text('No data · not streaming — BMS not running'),
          findsOneWidget);
      c.streamClass = StreamClass.awakeNotStreaming;
      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(find.text('No data · BMS awake, not streaming'), findsOneWidget);
      expectNoStaleState(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.dispose);
    });

    testWidgets('connected, no frame yet on this link: "No data · waiting"',
        (tester) async {
      clock = DateTime.utc(2026, 9, 21, 12);
      final c = BatteryConnection(transport: FakeTransport(), now: () => clock);
      await tester.runAsync(() => c.connectTo('dev-1', name: 'dev-1'));
      c.state.serial = 'JS-TEST01';
      clock = clock.add(const Duration(seconds: 1));
      await pumpCard(tester, c, manager());
      expect(find.byType(LiveStatusLine), findsOneWidget);
      expect(find.text('No data · waiting for the first frame'), findsOneWidget);
      expect(dashFigures(tester), 2);
      expectNoStaleState(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.dispose);
    });

    testWidgets('streaming pack: the charge state with its values, one line, '
        'the dot flashes once per BAL_STATUS (#64)', (tester) async {
      final c = await streamed(tester);
      await pumpCard(tester, c, manager());
      expect(find.byType(LiveStatusLine), findsOneWidget);
      expect(find.text('Charging'), findsOneWidget);
      expect(find.text('53.21 V'), findsOneWidget);
      expect(find.text('+12.3 A in'), findsWidgets);
      expect(dashFigures(tester), 0);
      expect(find.textContaining('No data'), findsNothing);
      expect(find.textContaining('live'), findsNothing,
          reason: 'the blinking dot is the signal, no "live" word');
      LiveDot dot() => tester.widget<LiveDot>(find.byType(LiveDot));
      expect(dot().color, HealthPalette.healthy);
      expect(dot().pulse.isAnimating, isFalse);
      c.parser.addBytes(bal);
      await tester.pump();
      expect(dot().pulse.isAnimating, isTrue, reason: 'one flash per cycle');
      await tester.pump();
      await tester.pump(pulseDuration + const Duration(milliseconds: 1));
      expect(dot().pulse.isAnimating, isFalse);

      // Going stale: the age trails the state, dot amber; values stay.
      clock = clock.add(const Duration(seconds: 5));
      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(find.text('Charging · updated 5.0 s ago'), findsOneWidget);
      expect(dot().color, Colors.amber);
      expect(find.text('53.21 V'), findsOneWidget);

      // Then silent: the status line flips by itself …
      clock = clock.add(const Duration(seconds: 6));
      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(find.text('No data · not streaming — 11 s silent'), findsOneWidget);
      expect(find.byType(LiveStatusLine), findsOneWidget);
      // … and the list page's 300 ms signature tick (hasData is in the
      // signature) rebuilds the card, which blanks the SOC-bar current too.
      await pumpCard(tester, c, manager());
      expect(find.byType(LiveStatusLine), findsOneWidget);
      expectNoStaleState(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(c.dispose);
    });

    testWidgets('offline favourite placeholder: "Offline · last seen …" as '
        'the one line, figures "—"', (tester) async {
      final m = manager();
      final c = BatteryConnection(profile: DeviceProfile.sphere);
      c.state
        ..serial = 'JS-OFF'
        ..socPercent = 70
        ..fullAh = 100
        ..remainingAh = 70
        ..packVoltage = 52.0
        ..chargeState = ChargeState.idle;
      c.isRemembered = true;
      c.lastSeenMs = DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000;
      expect(c.isOffline, isTrue);
      await pumpCard(tester, c, m);
      expect(find.byType(LiveStatusLine), findsOneWidget);
      expect(find.text('Offline · last seen 5 min ago'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsNothing,
          reason: 'the separate offline row is gone');
      expect(dashFigures(tester), 2);
      expect(find.text('70%'), findsOneWidget);
      expectNoStaleState(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('detail header: the same single line; Current "—" when silent',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = await streamed(tester);
      final m = manager();
      m.batteries.add(c);
      final aliases = AliasStore(prefs: SharedPreferences.getInstance);
      clock = clock.add(const Duration(seconds: 15));
      c.streamClass = StreamClass.dormant;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: gNavKey,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: BatteryDetailPage(conn: c, manager: m, aliases: aliases),
      ));
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.byType(LiveStatusLine), findsOneWidget);
      expect(find.text('No data · not streaming — BMS not running'),
          findsOneWidget);
      expect(find.text('—  ·  —'), findsOneWidget, reason: 'V · W');
      expect(find.text('—'), findsWidgets, reason: 'the big Current figure');
      expect(find.text('+12.3 A in'), findsNothing);
      expect(find.text('Charging'), findsNothing);
      expect(find.text('53.21 V'), findsNothing);
      // The #62 recovery card stays.
      expect(find.textContaining('BMS not running'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      m.disposeAll();
    });
  });

  group('fleet panel Status — streaming members only', () {
    BatteryConnection member(String serial,
        {bool streaming = true, double current = 0, ChargeState cs = ChargeState.idle}) {
      final c = BatteryConnection(profile: DeviceProfile.sphere);
      c.state
        ..serial = serial
        ..fullAh = 100
        ..remainingAh = 50
        ..packVoltage = 52
        ..packCurrent = current
        ..power = current * 52
        ..chargeState = cs;
      c.connState = ConnState.connected;
      if (streaming) c.lastTelemetryMs = DateTime.now().millisecondsSinceEpoch;
      return c;
    }

    test('net current / power and the status exclude silent packs', () {
      final m = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      final silent =
          member('JS-SILENT', streaming: false, current: 20, cs: ChargeState.charging);
      final live = member('JS-LIVE', current: 5, cs: ChargeState.discharging);
      m.batteries.addAll([silent, live]);
      m.setInFleet(silent, true);
      m.setInFleet(live, true);
      expect(silent.isStreaming, isFalse);
      expect(live.isStreaming, isTrue);
      expect(m.connectedFleetMembers.length, 2);
      expect(m.streamingFleetMembers, [live]);
      expect(m.netCurrentA, -5, reason: 'the silent pack\'s 20 A is stale');
      expect(m.netPowerW, -5 * 52);
      expect(m.fleetStreamingState, ChargeState.discharging);
      // Nothing streams: no status at all.
      live.lastTelemetryMs = null;
      expect(m.streamingFleetMembers, isEmpty);
      expect(m.fleetStreamingState, isNull);
      expect(m.netCurrentA, 0);
      m.disposeAll();
    });

    testWidgets('Status row reads "No data" when nothing streams, the state '
        'when something does', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final m = BatteryManager(
          transport: NoopTransport(), fleetStore: FakeFleetStore());
      final c = member('JS-SILENT', streaming: false, current: 20,
          cs: ChargeState.charging);
      m.batteries.add(c);
      m.setInFleet(c, true);
      Widget panel() => MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: Scaffold(body: FleetTotal(manager: m)),
          );
      await tester.pumpWidget(panel());
      expect(find.text('Status'), findsOneWidget);
      expect(find.text('No data'), findsOneWidget);
      expect(find.text('Charging'), findsNothing);
      expect(find.text('Idle · no load'), findsNothing);
      // The pack starts streaming: its state shows.
      c.lastTelemetryMs = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(panel());
      expect(find.text('No data'), findsNothing);
      expect(find.text('Charging'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      m.disposeAll();
    });
  });
}
