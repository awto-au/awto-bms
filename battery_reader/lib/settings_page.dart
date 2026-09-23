/// Settings page (#35): demo mode, verbose raw logging + send-to-developer and
/// the temperature unit. Reached via the app-bar gear on the phone; on desktop
/// (#68) it is the right pane's Settings tab ([embedded] = no Scaffold / app
/// bar, Diagnostics opens in the pane through [onOpenDiagnostics]). (#37
/// removed the lifetime-totals toggle — those totals are now always
/// maintained cheaply.)
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';

import 'app_session.dart';
import 'app_theme.dart';
import 'battery_log.dart';
import 'diagnostics.dart';
import 'diagnostics_page.dart';
import 'intervals.dart' show YAxisMode, gYAxisMode;
import 'monitoring_policy.dart';
import 'raw_log.dart';
import 'settings_store.dart';
import 'temp_unit.dart' show gUseFahrenheit;
import 'widgets.dart';
import 'write_actions.dart' show showToast;

class SettingsPage extends StatefulWidget {
  final SettingsStore settings;
  final bool demoMode;
  final ValueChanged<bool> onDemoModeChanged;
  /// #43: temperature-unit toggle (°F when true, else °C).
  final bool useFahrenheit;
  final ValueChanged<bool> onTempUnitChanged;
  /// #70: default chart Y-axis mode (full range / fit to data).
  final YAxisMode yAxisMode;
  final ValueChanged<YAxisMode> onYAxisModeChanged;
  /// #45: system alert notifications toggle (persisted, default ON).
  final bool alertNotifications;
  final ValueChanged<bool> onAlertNotificationsChanged;
  /// #52: background monitoring toggle (persisted, default ON).
  final bool backgroundMonitoring;
  final ValueChanged<bool> onBackgroundMonitoringChanged;
  /// #53: background sample interval (persisted, default 5 min).
  final BackgroundSampleInterval sampleInterval;
  final ValueChanged<BackgroundSampleInterval> onSampleIntervalChanged;
  /// #52: monitoring paused by the user (batteries released) + pause/resume.
  final bool monitoringPaused;
  final ValueChanged<bool> onMonitoringPausedChanged;
  /// #54: full shutdown (stop service + BLE, flush logs, close the app).
  final VoidCallback onExit;
  /// M13: the manager's current scan error (for the Diagnostics page).
  final String? scanError;
  /// #55: live per-battery control-availability lines for Diagnostics
  /// ([BatteryConnection.gateStatusSummary]), evaluated on each refresh.
  final List<String> Function()? batteryStatus;

  /// #68: rendered inside the desktop pane — no Scaffold / app bar.
  final bool embedded;

  /// #68: where Diagnostics opens (the desktop pane); null = push a route.
  final VoidCallback? onOpenDiagnostics;
  const SettingsPage({
    super.key,
    required this.settings,
    required this.demoMode,
    required this.onDemoModeChanged,
    required this.useFahrenheit,
    required this.onTempUnitChanged,
    this.yAxisMode = YAxisMode.full,
    this.onYAxisModeChanged = _ignoreYAxis,
    required this.alertNotifications,
    required this.onAlertNotificationsChanged,
    required this.backgroundMonitoring,
    required this.onBackgroundMonitoringChanged,
    required this.sampleInterval,
    required this.onSampleIntervalChanged,
    required this.monitoringPaused,
    required this.onMonitoringPausedChanged,
    required this.onExit,
    this.scanError,
    this.batteryStatus,
    this.embedded = false,
    this.onOpenDiagnostics,
  });

  static void _ignoreYAxis(YAxisMode _) {}

  /// #68: the page wired to the shared [AppSession] — the ONE place the
  /// settings callbacks are bound, used by the phone route and the desktop
  /// Settings tab alike.
  static SettingsPage forSession(
    AppSession s, {
    bool embedded = false,
    VoidCallback? onOpenDiagnostics,
  }) =>
      SettingsPage(
        settings: s.settings,
        demoMode: s.demoMode,
        onDemoModeChanged: s.setDemoMode,
        useFahrenheit: gUseFahrenheit,
        onTempUnitChanged: s.setTempUnit,
        yAxisMode: gYAxisMode, // #70
        onYAxisModeChanged: s.setYAxisMode,
        alertNotifications: s.alertNotifications,
        onAlertNotificationsChanged: s.setAlertNotifications,
        backgroundMonitoring: s.policy.backgroundMonitoring,
        onBackgroundMonitoringChanged: s.setBackgroundMonitoring,
        sampleInterval: s.policy.sampleInterval, // #53
        onSampleIntervalChanged: s.setSampleInterval,
        monitoringPaused: s.policy.userStopped,
        onMonitoringPausedChanged: s.setMonitoringPaused,
        onExit: s.exitApp,
        scanError: s.demoMode ? null : s.manager.scanErrorText,
        // #55: control availability per battery, live at each refresh.
        batteryStatus: s.batteryStatusLines,
        embedded: embedded,
        onOpenDiagnostics: onOpenDiagnostics,
      );

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late bool _demo = widget.demoMode;
  late bool _fahrenheit = widget.useFahrenheit;
  late YAxisMode _yAxis = widget.yAxisMode; // #70
  late bool _alerts = widget.alertNotifications; // #45
  late bool _background = widget.backgroundMonitoring; // #52
  late BackgroundSampleInterval _interval = widget.sampleInterval; // #53
  late bool _paused = widget.monitoringPaused; // #52
  bool _sharing = false;

  Future<void> _sendToDeveloper() async {
    final path = RawLogger.instance.path;
    if (path == null) return;
    setState(() => _sharing = true);
    try {
      await RawLogger.instance.flush(); // buffered lines to disk first
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          text: 'Battery Reader raw log',
        ),
      );
    } catch (e) {
      if (mounted) showToast(context, 'Could not share: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _copyPath() async {
    final path = RawLogger.instance.path;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) showToast(context, 'Path copied to clipboard');
  }

  void _openDiagnostics() {
    final inPane = widget.onOpenDiagnostics;
    if (inPane != null) {
      inPane();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiagnosticsPage(
            scanError: widget.scanError, batteryStatus: widget.batteryStatus),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logger = RawLogger.instance;
    final path = logger.path;
    final store = BatteryLogger.instance;
    final appLog = AppLog.instance;
    final diagSummary = diagnosticsSummary(
      dbDegraded: store.dbDegraded,
      lastDbError: store.lastDbError,
      entryCount: appLog.length,
      totalRecorded: appLog.totalRecorded,
    );
    final list = ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // #46: everyday settings first; the Demo-mode section is LAST.
            _sectionHeader(context, 'Raw logging'),
            SwitchListTile(
              secondary: Icon(Icons.description_outlined,
                  color: logger.enabled ? null : Colors.amber),
              title: const Text('Verbose raw logging'),
              // Plain status first — a log switched OFF used to stop silently
              // for a day; now the page says so and when it last wrote.
              subtitle: Text(
                '${RawLogger.statusLine(
                  enabled: logger.enabled,
                  sizeBytes: logger.sizeBytes,
                  maxBytes: logger.maxBytes,
                  lastWrittenAt: logger.lastWrittenAt,
                )}\n'
                'Captures every raw BLE notification, decoded frame, sent '
                'command and dropped byte. Turn off if the file grows large.',
                style: logger.enabled
                    ? null
                    : const TextStyle(color: Colors.amber),
              ),
              value: logger.enabled,
              onChanged: (v) {
                setState(() => logger.enabled = v);
                widget.settings.saveVerbose(v);
              },
            ),
            ListTile(
              leading: _sharing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.share),
              title: const Text('Send to developer'),
              subtitle: const Text('Share the raw-log file'),
              enabled: path != null && !_sharing,
              onTap: (path == null || _sharing) ? null : _sendToDeveloper,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // M9: current size + the rotation cap, so the user can
                  // see how big the file is before sharing it.
                  Text(
                      'Log file · ${RawLogger.fmtSize(logger.sizeBytes)}'
                      ' (rotates at ${RawLogger.fmtSize(logger.maxBytes)}'
                      ' to ${RawLogger.rotatedFileName})',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          path ?? '(not available on this platform)',
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ),
                      if (path != null)
                        IconButton(
                          tooltip: 'Copy path',
                          icon: const Icon(Icons.copy, size: 16),
                          onPressed: _copyPath,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(),
            // Pass C1: Diagnostics — the recorded best-effort failures,
            // the interval-store health (M7) and the raw-log size (M9).
            _sectionHeader(context, 'Diagnostics'),
            if (store.dbDegraded)
              ListTile(
                leading: const Icon(Icons.error_outline, color: kRed),
                title: const Text('Logging is failing',
                    style: TextStyle(color: kRed)),
                subtitle: Text(
                    '${store.lastDbError ?? 'unknown error'} — the '
                    'history store is retrying automatically; live '
                    'values and the last hour of charts still work.'),
                onTap: _openDiagnostics,
              ),
            ListTile(
              leading: Icon(
                store.dbDegraded
                    ? Icons.report_problem_outlined
                    : Icons.bug_report_outlined,
                color: store.dbDegraded ? kRed : null,
              ),
              title: const Text('Diagnostics'),
              subtitle: Text(diagSummary),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openDiagnostics,
            ),
            const Divider(),
            // #45: system alert notifications (Faults + Alerts channels).
            _sectionHeader(context, 'Notifications'),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Alert notifications'),
              subtitle: const Text(
                  'Show faults and alerts as system notifications, including '
                  'when the app is in the background. Off keeps the in-app '
                  'beep and red banner only.'),
              value: _alerts,
              onChanged: (v) {
                setState(() => _alerts = v);
                widget.onAlertNotificationsChanged(v);
              },
            ),
            // #52: background monitoring (the foreground service). OFF: the
            // app monitors only while in the foreground and releases every
            // battery when backgrounded / swiped away.
            SwitchListTile(
              secondary: const Icon(Icons.bluetooth_searching),
              title: const Text('Background monitoring'),
              subtitle: const Text(
                  'Keep reading the batteries (and alerting) while the app is '
                  'in the background, with a persistent notification. Off: '
                  'monitor only while the app is open and release the '
                  'batteries when it is backgrounded or closed.'),
              value: _background,
              onChanged: (v) {
                setState(() {
                  _background = v;
                  if (v) _paused = false; // ON also clears a user stop
                });
                widget.onBackgroundMonitoringChanged(v);
              },
            ),
            // #53: background sample interval — periodic connect / one
            // cycle / disconnect instead of held links, with the
            // alert-latency trade-off spelled out.
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Background sample interval'),
              enabled: _background,
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<BackgroundSampleInterval>(
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        segments: [
                          for (final v in BackgroundSampleInterval.values)
                            ButtonSegment(value: v, label: Text(v.label)),
                        ],
                        selected: {_interval},
                        showSelectedIcon: false,
                        onSelectionChanged: !_background
                            ? null
                            : (sel) {
                                setState(() => _interval = sel.first);
                                widget.onSampleIntervalChanged(sel.first);
                              },
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_interval.latencyNote}\n'
                      'While the app is in the background the batteries are '
                      'released and reconnected once per interval for one '
                      'reading (about 2–3 s each); the foreground is always '
                      'continuous.',
                    ),
                  ],
                ),
              ),
            ),
            // #52: quick pause / resume (same as the app-bar menu and the
            // notification's "Stop monitoring" action).
            ListTile(
              leading: Icon(_paused ? Icons.play_arrow : Icons.pause),
              title: Text(_paused ? 'Resume monitoring' : 'Pause monitoring'),
              subtitle: Text(_paused
                  ? 'Monitoring is paused — the batteries are released. Tap '
                      'to scan and reconnect.'
                  : 'Release the batteries so another BLE client (e.g. the '
                      'PC tools) can use them. Alerts stay enabled for when '
                      'you resume.'),
              enabled: !widget.demoMode,
              onTap: widget.demoMode
                  ? null
                  : () {
                      final next = !_paused;
                      setState(() => _paused = next);
                      widget.onMonitoringPausedChanged(next);
                    },
            ),
            const Divider(),
            // #70: default chart Y-axis mode. Display-only; each chart card
            // can override it for the session with its own toggle.
            _sectionHeader(context, 'Charts'),
            ListTile(
              leading: const Icon(Icons.show_chart),
              title: const Text('Chart Y axis'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<YAxisMode>(
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: YAxisMode.full,
                          icon: Icon(Icons.unfold_more),
                          label: Text('Full range'),
                        ),
                        ButtonSegment(
                          value: YAxisMode.fit,
                          icon: Icon(Icons.unfold_less),
                          label: Text('Fit to data'),
                        ),
                      ],
                      selected: {_yAxis},
                      showSelectedIcon: false,
                      onSelectionChanged: (sel) {
                        setState(() => _yAxis = sel.first);
                        widget.onYAxisModeChanged(sel.first);
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(_yAxis == YAxisMode.fit
                        ? 'Fit to data: each axis is tight to the values seen '
                            'in the window (e.g. cells 3.0–3.3 V). The '
                            'Full / Fit button on each chart overrides this '
                            'for that chart.'
                        : 'Full range: every axis includes 0 (signed values '
                            'are symmetric about 0). The Full / Fit button '
                            'on each chart overrides this for that chart.'),
                  ],
                ),
              ),
            ),
            const Divider(),
            // #43: temperature display unit (°C / °F). Display-only.
            _sectionHeader(context, 'Temperature'),
            SwitchListTile(
              secondary: const Icon(Icons.thermostat),
              title: const Text('Show temperatures in °F'),
              subtitle: const Text(
                  'Off = °C (default). Display-only — stored values stay in '
                  '°C and nothing is sent to the BMS.'),
              value: _fahrenheit,
              onChanged: (v) {
                setState(() => _fahrenheit = v);
                widget.onTempUnitChanged(v);
              },
            ),
            const Divider(),
            // #46: Demo mode is the LAST section on the page.
            _sectionHeader(context, 'Mode'),
            SwitchListTile(
              secondary: const Icon(Icons.science_outlined),
              title: const Text('Demo mode'),
              subtitle: const Text(
                  'Synthetic fleet with no hardware. Off = Live (scan BLE).'),
              value: _demo,
              onChanged: (v) {
                setState(() => _demo = v);
                widget.onDemoModeChanged(v);
              },
            ),
            const Divider(),
            // #54: Exit at the very bottom — a full shutdown, unlike Pause.
            ListTile(
              leading: const Icon(Icons.power_settings_new),
              title: const Text('Exit Battery Reader'),
              subtitle: const Text(
                  'Stop monitoring, release the batteries, save the logs and '
                  'close the app. It will not restart on its own.'),
              onTap: widget.onExit,
            ),
          ],
        );
    // #68: inside the desktop pane the tab strip is the chrome.
    if (widget.embedded) return list;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: PageShell(child: list),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700)),
      );
}
