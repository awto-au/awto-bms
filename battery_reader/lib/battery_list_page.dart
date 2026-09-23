/// The PHONE list screen: top half = per-battery rows, bottom half = fleet
/// total; tapping a row pushes the detail route, the gear pushes Settings.
/// Since #68 the app state lives in [AppSession]; this page either receives
/// the shell's session or (pumped on its own, as the widget tests do) creates
/// and owns one. Its rows and footer are the SAME [SummaryCard] / [FleetTotal]
/// widgets the desktop left pane arranges (lib/sections/).
library;

import 'package:flutter/material.dart';

import 'alias_dialog.dart';
import 'app_session.dart';
import 'app_theme.dart';
import 'battery_connection.dart';
import 'battery_detail.dart';
import 'sections/detected_card.dart';
import 'sections/fleet_total.dart';
import 'sections/summary_card.dart';
import 'settings_page.dart';
import 'widgets.dart';

class BatteryListPage extends StatefulWidget {
  /// The shell's session (#68); null = this page creates and owns one.
  final AppSession? session;

  /// #68: how a tapped row opens (the shell's named detail route, so the
  /// keyboard handler can swap / pop it); null = push the detail route here.
  final void Function(BatteryConnection conn)? onOpenDetail;
  const BatteryListPage({super.key, this.session, this.onOpenDetail});
  @override
  State<BatteryListPage> createState() => _BatteryListPageState();
}

class _BatteryListPageState extends State<BatteryListPage> {
  late final AppSession _session = widget.session ?? AppSession();
  bool get _owns => widget.session == null;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    if (_owns) {
      _session.contextProvider = () => mounted ? context : null;
      _session.start();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    if (_owns) _session.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage.forSession(_session)),
    );
  }

  /// #44: edit (or clear) a pack's local custom name. Opens a text-field dialog
  /// pre-filled with the current alias; an empty result reverts to the serial.
  Future<void> _editAlias(String serial) async {
    await editBatteryAlias(context, _session.aliases, serial);
    if (mounted) setState(() {});
  }

  void _openDetail(BatteryConnection conn) {
    final hook = widget.onOpenDetail;
    if (hook != null) {
      hook(conn);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BatteryDetailPage(
            conn: conn,
            manager: _session.manager,
            aliases: _session.aliases,
            keepAwake: _session.keepAwake),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final manager = s.manager;
    final batteries = manager.batteries;
    final others = manager.detectedOthers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batteries'),
        actions: [
          // #35: demo mode and raw logging live in Settings now — no Live/Demo
          // control on the main screen.
          if (s.demoMode)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Center(
                child: Text('DEMO',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.amber)),
              ),
            ),
          // #52: monitoring paused by the user (batteries released).
          if (s.policy.userStopped && !s.demoMode)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Center(
                child: Text('PAUSED',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.amber)),
              ),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
          // #52: quick pause / resume without touching the alert settings.
          SessionMenu(session: s),
          const SizedBox(width: 4),
        ],
      ),
      // Issue #30(a): SafeArea keeps the body (and the fleet panel at the bottom)
      // clear of the Android system navigation bar.
      body: PageShell(
        child: Column(
          children: [
            // Top half: the list of batteries.
            Expanded(
              child: (batteries.isEmpty && others.isEmpty)
                  // M13: a failed scan (adapter off / permission denied)
                  // is shown here instead of "Scanning…" forever.
                  ? EmptyListNotice(session: s)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      children: [
                        for (final b in batteries)
                          SummaryCard(
                            conn: b,
                            manager: manager,
                            alias: s.aliases.aliasFor(b.state.serial),
                            onTap: () => _openDetail(b),
                            onToggleFleet: () => s.toggleFleet(b),
                            onEditAlias: b.state.serial == null
                                ? null
                                : () => _editAlias(b.state.serial!),
                          ),
                        // DETECT-only (issue #15): other-family BMS devices,
                        // recognised but not decoded. Muted, non-fleet, tap for
                        // an info sheet — never connected.
                        for (final d in others)
                          DetectedCard(
                            device: d,
                            onTap: () => DetectedInfoSheet.show(context, d),
                          ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            // Bottom half: combined total across favourited batteries.
            Expanded(child: FleetTotal(manager: manager)),
          ],
        ),
      ),
    );
  }
}

/// The "no batteries yet" body: "Scanning…", a failed scan (adapter off /
/// permission denied, M13) in red, or "No batteries" in demo mode. Shared by
/// both layouts.
class EmptyListNotice extends StatelessWidget {
  final AppSession session;
  const EmptyListNotice({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    final scanError = s.manager.scanErrorText;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          s.demoMode
              ? 'No batteries'
              : (scanError ?? 'Scanning for batteries…'),
          textAlign: TextAlign.center,
          style: scanError != null && !s.demoMode
              ? const TextStyle(color: kRed)
              : null,
        ),
      ),
    );
  }
}

/// The "More" overflow menu (#52 pause / resume, #54 exit) — the same items
/// on the phone app bar and the desktop left-pane header.
class SessionMenu extends StatelessWidget {
  final AppSession session;
  const SessionMenu({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (v) {
        if (v == 'pause') s.setMonitoringPaused(true);
        if (v == 'resume') s.setMonitoringPaused(false);
        if (v == 'exit') s.exitApp();
      },
      itemBuilder: (_) => [
        if (s.policy.userStopped)
          const PopupMenuItem(
            value: 'resume',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.play_arrow),
              title: Text('Resume monitoring'),
            ),
          )
        else
          PopupMenuItem(
            value: 'pause',
            enabled: !s.demoMode,
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.pause),
              title: Text('Pause monitoring'),
              subtitle: Text('Release the batteries for another client'),
            ),
          ),
        // #54: full shutdown (release batteries, flush logs, close).
        const PopupMenuItem(
          value: 'exit',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.power_settings_new),
            title: Text('Exit'),
            subtitle: Text('Stop monitoring and close the app'),
          ),
        ),
      ],
    );
  }
}
