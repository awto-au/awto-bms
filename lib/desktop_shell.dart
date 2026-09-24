/// The DESKTOP two-pane layout (#68, >= [kDesktopMinWidth] logical px):
/// left = the battery rows + the fleet footer (the SAME [SummaryCard] /
/// [FleetTotal] widgets as the phone list, in dense mode); right = the
/// selected battery under three tabs — Detail (the shared section widgets in
/// the grid arrangement), Charts (the charts page embedded, chart grid) and
/// Settings (the settings page embedded; Diagnostics opens in the pane too).
/// Selection and the active tab are owned by [AdaptiveScaffold]; this widget
/// only arranges.
library;

import 'package:flutter/material.dart';

import 'alias_dialog.dart';
import 'alias_store.dart' show displayName;
import 'app_session.dart';
import 'battery_charts.dart';
import 'battery_connection.dart';
import 'battery_detail.dart';
import 'battery_list_page.dart'
    show BatteryListView, EmptyListNotice, SessionMenu;
import 'diagnostics_page.dart';
import 'sections/fleet_total.dart';
import 'settings_page.dart';

/// The right pane's tabs.
enum DesktopTab { detail, charts, settings }

/// Window width from which the two-pane layout is used.
const double kDesktopMinWidth = 900;

/// The left pane's fixed width.
const double kLeftPaneWidth = 340;

class DesktopShell extends StatefulWidget {
  final AppSession session;
  final BatteryConnection? selected;
  final ValueChanged<BatteryConnection> onSelect;
  final DesktopTab tab;
  final ValueChanged<DesktopTab> onTab;
  const DesktopShell({
    super.key,
    required this.session,
    required this.selected,
    required this.onSelect,
    required this.tab,
    required this.onTab,
  });

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  /// Settings tab: Diagnostics open in the pane (a back arrow returns).
  bool _diagnostics = false;

  AppSession get s => widget.session;

  Future<void> _editAlias(String serial) async {
    await editBatteryAlias(context, s.aliases, serial);
    s.touch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: kLeftPaneWidth, child: _leftPane(context)),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: _rightPane(context)),
          ],
        ),
      ),
    );
  }

  // --- left pane -----------------------------------------------------------

  Widget _leftPane(BuildContext context) {
    final manager = s.manager;
    final batteries = manager.batteries;
    final others = manager.detectedOthers;
    const badge = TextStyle(
        fontSize: 12, fontWeight: FontWeight.w700, color: Colors.amber);
    return Column(
      children: [
        // Pane header: title, DEMO / PAUSED badges, Settings, the More menu.
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Text('Batteries',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (s.demoMode)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Text('DEMO', style: badge),
                  ),
                if (s.policy.userStopped && !s.demoMode)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Text('PAUSED', style: badge),
                  ),
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings),
                  onPressed: () => widget.onTab(DesktopTab.settings),
                ),
                SessionMenu(session: s),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: (batteries.isEmpty && others.isEmpty)
              ? EmptyListNotice(session: s)
              : BatteryListView(
                  session: s,
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  dense: true,
                  selected: widget.selected,
                  onOpen: widget.onSelect,
                  onEditAlias: _editAlias,
                ),
        ),
        const Divider(height: 1),
        // The fleet footer: the same panel as the phone's bottom half, dense,
        // capped so the rows above keep room; it scrolls internally.
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height * 0.45)
                  .clamp(160.0, 420.0)),
          child: FleetTotal(manager: manager, dense: true),
        ),
      ],
    );
  }

  // --- right pane ----------------------------------------------------------

  Widget _rightPane(BuildContext context) {
    final sel = widget.selected;
    final serial = sel?.state.serial;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SegmentedButton<DesktopTab>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(
                        value: DesktopTab.detail, label: Text('Detail')),
                    ButtonSegment(
                        value: DesktopTab.charts, label: Text('Charts')),
                    ButtonSegment(
                        value: DesktopTab.settings, label: Text('Settings')),
                  ],
                  selected: {widget.tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => widget.onTab(v.first),
                ),
                const SizedBox(width: 12),
                if (sel != null && widget.tab != DesktopTab.settings)
                  Expanded(
                    child: Text(
                      serial == null
                          ? 'Battery'
                          : displayName(s.aliases.aliasFor(serial), serial),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
                if (sel != null && widget.tab == DesktopTab.detail) ...[
                  // #44: rename (local custom name).
                  if (serial != null)
                    IconButton(
                      tooltip: 'Rename',
                      icon: const Icon(Icons.edit),
                      onPressed: () => _editAlias(serial),
                    ),
                  // Manual fleet membership (issue #10).
                  IconButton(
                    tooltip:
                        sel.inFleet ? 'Remove from fleet' : 'Add to fleet',
                    icon: Icon(
                      sel.inFleet ? Icons.star : Icons.star_border,
                      color: sel.inFleet ? Colors.amber : null,
                    ),
                    onPressed: () => s.toggleFleet(sel),
                  ),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _tabBody(context, sel, serial)),
      ],
    );
  }

  Widget _tabBody(
      BuildContext context, BatteryConnection? sel, String? serial) {
    switch (widget.tab) {
      case DesktopTab.detail:
        if (sel == null) return const _Placeholder('Select a battery');
        return BatteryDetailView(
          conn: sel,
          manager: s.manager,
          aliases: s.aliases,
          keepAwake: s.keepAwake,
          arrangement: DetailArrangement.grid,
          dense: true,
        );
      case DesktopTab.charts:
        if (sel == null) return const _Placeholder('Select a battery');
        if (serial == null || serial.isEmpty) {
          return const _Placeholder('No history yet — serial unknown');
        }
        return BatteryChartsPage(
            key: ValueKey('charts:$serial'), serial: serial, embedded: true);
      case DesktopTab.settings:
        if (_diagnostics) {
          return DiagnosticsPage(
            embedded: true,
            scanError: s.demoMode ? null : s.manager.scanErrorText,
            batteryStatus: s.batteryStatusLines,
            onBack: () => setState(() => _diagnostics = false),
          );
        }
        return SettingsPage.forSession(
          s,
          embedded: true,
          onOpenDiagnostics: () => setState(() => _diagnostics = true),
        );
    }
  }
}

class _Placeholder extends StatelessWidget {
  final String text;
  const _Placeholder(this.text);
  @override
  Widget build(BuildContext context) => Center(
        child: Text(text, style: const TextStyle(color: Colors.white54)),
      );
}
