/// The single-battery detail view (#68): ONE stateful widget owning the
/// history / alarm loading, the event-driven repaint and the write busy
/// flags, rendering the shared section widgets (lib/sections/) in one of two
/// ARRANGEMENTS — [DetailArrangement.stacked] (the phone page: one scrolling
/// column) or [DetailArrangement.grid] (the desktop pane: a two-column grid of
/// the small sections with the wide ones full-width, dense). No field, label,
/// formatter or value path lives here: every section is defined once under
/// lib/sections/ and both arrangements place the SAME widgets.
///
/// [BatteryDetailPage] is the phone route: an app bar plus the stacked view.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'alarm_events.dart';
import 'alarm_events_view.dart';
import 'alias_dialog.dart';
import 'alias_store.dart';
import 'app_theme.dart';
import 'battery_charts.dart';
import 'battery_connection.dart';
import 'battery_log.dart';
import 'battery_manager.dart';
import 'battery_protocol.dart' show BatteryEvent;
import 'diagnostics.dart';
import 'intervals.dart' show GapPolicy, LookbackWindow, computeRange;
import 'metrics.dart';
import 'sections/advanced_section.dart';
import 'sections/alarm_banner.dart';
import 'sections/battery_header_line.dart';
import 'sections/capacity_section.dart';
import 'sections/cells_section.dart';
import 'sections/controls_section.dart';
import 'sections/gates_status_section.dart';
import 'sections/latched_over_temp_card.dart';
import 'sections/pack_section.dart';
import 'sections/recovery_ladder_card.dart';
import 'sections/temperatures_section.dart';
import 'sections/trends_section.dart';
import 'sections/warnings_section.dart';
import 'stale.dart';
import 'widgets.dart';
import 'write_actions.dart' show BusyWrites;

/// How the shared sections are laid out.
enum DetailArrangement {
  /// The phone page: every section in one scrolling column.
  stacked,

  /// The desktop pane: the small sections two-up, the wide ones full-width.
  grid,
}

/// Pane width from which the grid arrangement uses two columns.
const double kDetailGridTwoColumnMin = 700;

class BatteryDetailView extends StatefulWidget {
  final BatteryConnection conn;
  final BatteryManager manager;

  /// #44: shared per-battery custom names (the header shows the alias).
  final AliasStore aliases;

  /// #41: is the Android foreground service (wake lock) running? Feeds the
  /// firmware-update "device will stay awake" gate. Defaults to false.
  final bool Function() keepAwake;
  final DetailArrangement arrangement;

  /// Desktop density: halved card padding, status + values on one line.
  final bool dense;
  const BatteryDetailView({
    super.key,
    required this.conn,
    required this.manager,
    required this.aliases,
    this.keepAwake = neverAwake,
    this.arrangement = DetailArrangement.stacked,
    this.dense = false,
  });

  static bool neverAwake() => false;

  @override
  State<BatteryDetailView> createState() => _BatteryDetailViewState();
}

class _BatteryDetailViewState extends State<BatteryDetailView> {
  StreamSubscription<BatteryEvent>? _sub;

  /// L16: telemetry arrives ~8 events/s; rebuilds are coalesced to at most one
  /// per [rebuildEvery] (~4 Hz). The alert beep is never delayed.
  static const rebuildEvery = Duration(milliseconds: 250);
  Timer? _rebuild;

  // --- inline sparklines (issue #14) ---------------------------------------
  // The metrics summarised as per-row sparklines come from the metric
  // catalogue ([sparkMetrics]). One shared window selector drives them all.

  LookbackWindow _sparkWindow = LookbackWindow.h24; // default = last 24 hours
  Map<String, List<ReadingInterval>> _spark = const {};
  int _sparkFrom = 0;
  int _sparkTo = 0;
  Timer? _sparkTimer;

  /// #53: the sample-interval gap policy for the loaded window.
  GapPolicy _sparkPolicy = GapPolicy.continuous;

  /// #69: durable rows logged for this pack in the sparkline window — the
  /// "Logging" line under the Trends selector.
  int _rowsInWindow = 0;

  /// #61 / #62: a silent link produces no events, so a 1 s watch repaints
  /// the page when the streaming state (silent / probe verdict / connection)
  /// changes — that is what shows or hides the recovery ladder.
  Timer? _watch;
  (bool, StreamClass, ConnState)? _watched;

  /// M6: why the last sparkline load failed (DB error), or null. Shown as a
  /// small note in the Trends card instead of a silently blank set of rows.
  String? _sparkError;

  /// M6: a sparkline load in flight — the 3 s timer never overlaps a slow one.
  bool _sparkLoading = false;

  /// #67: the pack's alarm events (newest first), the stored total and
  /// whether the user asked for all of them. Loaded with the sparklines.
  List<AlarmEvent> _alarms = const [];
  int _alarmTotal = 0;
  bool _alarmsAll = false;
  String? _alarmError;

  /// M4: in-flight write flags shared by the Controls section and the latched
  /// over-temp card (both can send Restart BMS).
  final _busy = BusyWrites();

  @override
  void initState() {
    super.initState();
    _listen();
    _loadSpark();
    // Keep the sparkline tails moving without a heavy DB re-scan every event.
    _sparkTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _loadSpark());
    _watch = Timer.periodic(const Duration(seconds: 1), (_) {
      final c = widget.conn;
      final now = (c.notStreaming, c.streamClass, c.connState);
      if (now == _watched) return;
      _watched = now;
      if (mounted) setState(() {});
    });
  }

  void _listen() {
    _sub = widget.conn.events.listen((_) {
      if (widget.conn.consumeBeep()) alertBeep();
      _scheduleRebuild();
    });
  }

  /// #68: the desktop pane keeps ONE view alive and swaps the selected
  /// battery into it — re-subscribe and reload for the new pack.
  @override
  void didUpdateWidget(BatteryDetailView old) {
    super.didUpdateWidget(old);
    if (!identical(old.conn, widget.conn)) {
      _sub?.cancel();
      _listen();
      _spark = const {};
      _alarms = const [];
      _alarmTotal = 0;
      _alarmsAll = false;
      _sparkError = null;
      _alarmError = null;
      _rowsInWindow = 0;
      _watched = null;
      _loadSpark();
    }
  }

  /// L16: coalesce per-event repaints into one every [rebuildEvery].
  void _scheduleRebuild() {
    if (_rebuild != null) return;
    _rebuild = Timer(rebuildEvery, () {
      _rebuild = null;
      if (mounted) setState(() {});
    });
  }

  /// Load the sparkline series. M6: a DB error is caught and shown, never
  /// left as an unhandled async error from the periodic timer; the in-flight
  /// flag is always reset in `finally`.
  Future<void> _loadSpark() async {
    final serial = widget.conn.state.serial;
    if (serial == null || serial.isEmpty) return;
    if (_sparkLoading) return;
    _sparkLoading = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final span = _sparkWindow.spanMs;
      final since = span == null ? 0 : now - span;
      final log = BatteryLogger.instance;
      final series =
          await log.multiSeries(serial, sparkMetricKeys, sinceMs: since);
      // #53: the sample-interval rows decide which gaps are expected.
      final modeRows = await log.sampleIntervalRows(serial, sinceMs: since);
      final rows = await log.readingCount(serial, sinceMs: since); // #69
      if (!mounted) return;
      final range = computeRange(series.values, span, now);
      setState(() {
        _spark = series;
        _sparkPolicy = GapPolicy(modeRows);
        _sparkFrom = range.fromMs;
        _sparkTo = range.toMs;
        _sparkError = null;
        _rowsInWindow = rows;
      });
      await _loadAlarms(serial);
    } catch (e) {
      AppLog.instance
          .record('Sparklines', 'history load for $serial failed: $e');
      if (mounted) setState(() => _sparkError = '$e');
    } finally {
      _sparkLoading = false;
    }
  }

  /// #67: the alarm-event rows (last [AlarmEventsSection.pageSize], or all).
  Future<void> _loadAlarms(String serial) async {
    try {
      final log = BatteryLogger.instance;
      final rows = await log.alarmEvents(serial,
          limit: _alarmsAll ? 0 : AlarmEventsSection.pageSize);
      final total = await log.alarmEventCount(serial);
      if (!mounted) return;
      setState(() {
        _alarms = rows;
        _alarmTotal = total;
        _alarmError = null;
      });
    } catch (e) {
      AppLog.instance
          .record('Alarm events', 'load for $serial failed: $e');
      if (mounted) setState(() => _alarmError = '$e');
    }
  }

  void _setSparkWindow(LookbackWindow w) {
    setState(() => _sparkWindow = w);
    _loadSpark();
  }

  @override
  void dispose() {
    _sub?.cancel(); // note: does not dispose the connection (owned by manager)
    _sparkTimer?.cancel();
    _watch?.cancel();
    _rebuild?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // --- the shared sections, built ONCE per frame ---------------------------

  Widget? _banner() {
    if (!widget.conn.alarmActive) return null;
    return AlarmBanner(
      reasons: widget.conn.alarmReasons,
      onAcknowledge: () => setState(widget.conn.acknowledgeAlarms),
    );
  }

  Widget? _latched() {
    if (!widget.conn.state.overTempLatched) return null;
    // #50: latched over-temperature protection warning, with the restart
    // control (same confirmation) right there to clear it.
    return LatchedOverTempCard(
      conn: widget.conn,
      busy: _busy,
      onChanged: _changed,
    );
  }

  Widget _header(String? alias) => BatteryHeaderLine(
        conn: widget.conn,
        manager: widget.manager,
        alias: alias,
        socSeries: _spark[Metric.soc] ?? const [],
        fromMs: _sparkFrom,
        toMs: _sparkTo,
        policy: _sparkPolicy,
        dense: widget.dense,
      );

  Widget? _recovery() {
    // #62: connected but silent — the classification and the
    // user-initiated recovery ladder.
    if (!(widget.conn.connState == ConnState.connected &&
        widget.conn.notStreaming)) {
      return null;
    }
    return RecoveryLadderCard(
      conn: widget.conn,
      manager: widget.manager,
      busy: _busy,
      onChanged: _changed,
    );
  }

  /// #71: the pack's staleness (null while live), computed ONCE per build
  /// and handed to every section so they all flip together.
  Staleness? _stale() => stalenessOf(widget.conn,
      sampling: widget.manager.isSampling,
      nextDueMs: widget.manager.nextSampleDueMs);

  Widget _trends(Staleness? stale) => TrendsSection(
        window: _sparkWindow,
        onWindow: _setSparkWindow,
        series: _spark,
        fromMs: _sparkFrom,
        toMs: _sparkTo,
        conn: widget.conn,
        error: _sparkError,
        policy: _sparkPolicy,
        // #69: the logging status line (moved off the Charts page).
        logging: loggingStatusLine(
          enabled: BatteryLogger.instance.enabled,
          degraded: BatteryLogger.instance.dbDegraded,
          lastError: BatteryLogger.instance.lastDbError,
          sampleIntervalMs: BatteryLogger.instance.sampleIntervalMs,
          rowsInWindow: _rowsInWindow,
          windowLabel: _sparkWindow.label,
        ),
        dense: widget.dense,
        stale: stale,
      );

  /// The catalogue-driven sections, in [DetailSection] order — the one list
  /// both arrangements draw from (the drift-guard test walks it).
  List<Widget> _metricSections(Staleness? stale) {
    final c = widget.conn;
    final d = widget.dense;
    return [
      for (final s in DetailSection.values)
        switch (s) {
          DetailSection.pack => PackSection(conn: c, dense: d, stale: stale),
          DetailSection.capacity =>
            CapacitySection(conn: c, dense: d, stale: stale),
          DetailSection.cells => CellsSection(conn: c, dense: d, stale: stale),
          DetailSection.temperature =>
            TemperaturesSection(conn: c, dense: d, stale: stale),
          DetailSection.gates =>
            GatesStatusSection(conn: c, dense: d, stale: stale),
        },
    ];
  }

  List<Widget> _warnings() {
    final s = widget.conn.state;
    final d = widget.dense;
    return [
      WarningsSection('Current alarms', s.currentWarnings, dense: d),
      WarningsSection('Voltage alarms', s.voltageWarnings, dense: d),
      WarningsSection('Temperature alarms', s.temperatureWarnings, dense: d),
    ];
  }

  Widget _alarmEvents() {
    final s = widget.conn.state;
    // #67: every alarm-byte transition with its snapshot.
    return AlarmEventsSection(
      serial: s.serial ?? '',
      events: _alarms,
      total: _alarmTotal,
      showingAll: _alarmsAll,
      error: _alarmError,
      dense: widget.dense,
      onShowAll: () {
        setState(() => _alarmsAll = true);
        final serial = s.serial;
        if (serial != null && serial.isNotEmpty) _loadAlarms(serial);
      },
    );
  }

  Widget _controls() => ControlsSection(
        conn: widget.conn,
        busy: _busy,
        onChanged: _changed,
        fleetSize: widget.manager.fleetMembers.length, // #62 bank note
        dense: widget.dense,
      );

  Widget _advanced() => AdvancedSection(
        conn: widget.conn,
        busy: _busy,
        keepAwake: widget.keepAwake,
        onChanged: _changed,
        dense: widget.dense,
      );

  @override
  Widget build(BuildContext context) {
    final alias = widget.aliases.aliasFor(widget.conn.state.serial);
    final banner = _banner();
    final latched = _latched();
    final recovery = _recovery();
    final stale = _stale(); // #71
    return switch (widget.arrangement) {
      DetailArrangement.stacked => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (banner != null) banner,
            if (latched != null) latched,
            _header(alias),
            if (recovery != null) recovery,
            const SizedBox(height: 12),
            _trends(stale),
            ..._metricSections(stale),
            ..._warnings(),
            _alarmEvents(),
            _controls(),
            // #41: Advanced — the firmware update lives here, never on the
            // main list.
            _advanced(),
            const SizedBox(height: 40),
          ],
        ),
      DetailArrangement.grid => LayoutBuilder(
          builder: (context, box) {
            final twoUp = box.maxWidth >= kDetailGridTwoColumnMin;
            // The small sections two-up (in catalogue order, Controls last),
            // then the wide ones full-width. Wrapping preserves the order.
            final small = [..._metricSections(stale), _controls()];
            return ListView(
              padding: const EdgeInsets.all(8),
              children: [
                if (banner != null) banner,
                if (latched != null) latched,
                _header(alias),
                if (recovery != null) recovery,
                if (twoUp)
                  for (var i = 0; i < small.length; i += 2)
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: small[i]),
                          Expanded(
                              child: i + 1 < small.length
                                  ? small[i + 1]
                                  : const SizedBox.shrink()),
                        ],
                      ),
                    )
                else
                  ...small,
                ..._warnings(),
                _alarmEvents(),
                _trends(stale),
                _advanced(),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
    };
  }
}

// ===========================================================================
// Detail screen (phone route): app bar + the stacked view.
// ===========================================================================

class BatteryDetailPage extends StatefulWidget {
  final BatteryConnection conn;
  final BatteryManager manager;
  /// #44: shared per-battery custom names, read for the app-bar title and
  /// written by the rename dialog.
  final AliasStore aliases;

  /// #41: is the Android foreground service (wake lock) running? Feeds the
  /// firmware-update "device will stay awake" gate. Defaults to false.
  final bool Function() keepAwake;
  const BatteryDetailPage({
    super.key,
    required this.conn,
    required this.manager,
    required this.aliases,
    this.keepAwake = BatteryDetailView.neverAwake,
  });

  @override
  State<BatteryDetailPage> createState() => _BatteryDetailPageState();
}

class _BatteryDetailPageState extends State<BatteryDetailPage> {
  /// #44: rename this pack from the detail page (pencil in the app bar).
  Future<void> _editAlias() async {
    final serial = widget.conn.state.serial;
    if (serial == null || serial.isEmpty) return;
    await editBatteryAlias(context, widget.aliases, serial);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.conn.state;
    final alarm = widget.conn.alarmActive;
    final alias = widget.aliases.aliasFor(s.serial);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: alarm ? kRed : null,
        foregroundColor: alarm ? Colors.white : null,
        title: Text(
          s.serial == null ? 'Battery' : displayName(alias, s.serial),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // #44: rename (local custom name) from the detail page.
          if (s.serial != null)
            IconButton(
              tooltip: 'Rename',
              icon: const Icon(Icons.edit),
              onPressed: _editAlias,
            ),
          // Manual fleet membership (issue #10): toggle from the detail page too.
          IconButton(
            tooltip: widget.conn.inFleet ? 'Remove from fleet' : 'Add to fleet',
            icon: Icon(
              widget.conn.inFleet ? Icons.star : Icons.star_border,
              color: widget.conn.inFleet ? Colors.amber : null,
            ),
            onPressed: () => setState(() => widget.manager
                .setInFleet(widget.conn, !widget.conn.inFleet)),
          ),
          if (s.serial != null)
            IconButton(
              tooltip: 'Charts / history',
              icon: const Icon(Icons.show_chart),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BatteryChartsPage(serial: s.serial!),
                ),
              ),
            ),
        ],
      ),
      // Issue #30(a): keep the scrolling detail clear of the system nav bar.
      body: PageShell(
        child: BatteryDetailView(
          conn: widget.conn,
          manager: widget.manager,
          aliases: widget.aliases,
          keepAwake: widget.keepAwake,
        ),
      ),
    );
  }
}
