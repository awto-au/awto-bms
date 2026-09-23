/// The ONE responsive shell (#68). Owns the [AppSession] (or takes one), the
/// selected battery and the desktop tab, and picks the ARRANGEMENT by width:
///
///  * `< kDesktopMinWidth` (900 logical px): the phone navigation, unchanged —
///    [BatteryListPage] pushes the detail route, which pushes the charts page.
///  * `>= kDesktopMinWidth`: [DesktopShell] — battery rows + fleet footer on
///    the left, the selected battery's Detail / Charts / Settings tabs on the
///    right, no page navigation.
///
/// Both arrangements render the same shared widgets (lib/sections/) from the
/// same session. Keyboard: Up / Down move the selection (on a narrow window
/// they swap the open detail page), Esc returns to the list on a narrow
/// window. On a desktop host the window's size / position is remembered
/// through [WindowMemory].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_session.dart';
import 'battery_connection.dart';
import 'battery_detail.dart';
import 'battery_list_page.dart';
import 'desktop_scale.dart';
import 'desktop_shell.dart';
import 'nav.dart';
import 'window_memory.dart';

class AdaptiveScaffold extends StatefulWidget {
  /// An injected session (tests); null = this shell creates, starts and owns
  /// one for the app's lifetime.
  final AppSession? session;

  /// Whether to remember the window bounds; null = desktop hosts only.
  final bool? rememberWindow;
  const AdaptiveScaffold({super.key, this.session, this.rememberWindow});

  @override
  State<AdaptiveScaffold> createState() => AdaptiveScaffoldState();
}

class AdaptiveScaffoldState extends State<AdaptiveScaffold> {
  late final AppSession _session = widget.session ?? AppSession();
  bool get _owns => widget.session == null;

  /// The selection — ONE place for both arrangements. On the desktop it is
  /// the battery in the right pane; on the phone the battery whose detail
  /// route is open (kept so Up / Down can move from it).
  BatteryConnection? _selected;
  DesktopTab _tab = DesktopTab.detail;

  /// The arrangement last built (null before the first layout).
  bool? _wide;
  WindowMemory? _windowMemory;

  BatteryConnection? get selected => _selected;
  DesktopTab get tab => _tab;
  bool get isWide => _wide ?? false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _session.contextProvider = () => mounted ? context : null;
    _session.openBattery = openBattery;
    if (_owns) _session.start();
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.rememberWindow ?? isDesktopHost) {
      _windowMemory = WindowMemory(_session.settings)..restore();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _windowMemory?.dispose();
    _session.removeListener(_changed);
    if (identical(_session.openBattery, openBattery)) {
      _session.openBattery = null;
    }
    if (_owns) _session.dispose();
    super.dispose();
  }

  /// Open [conn] the way the current arrangement does: select it in the pane
  /// (desktop) or push its detail route on the root navigator (phone). Also
  /// the #45 notification deep-link target.
  void openBattery(BatteryConnection conn) {
    if (!mounted) return;
    if (isWide) {
      select(conn);
      return;
    }
    final nav = gNavKey.currentState ?? Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    _selected = conn;
    nav.push(detailRoute(conn));
  }

  /// The phone detail route for [conn] (named so the keyboard handler can
  /// recognise and swap it).
  MaterialPageRoute<void> detailRoute(BatteryConnection conn) =>
      MaterialPageRoute<void>(
        settings: RouteSettings(name: kDetailRouteName, arguments: conn),
        builder: (_) => BatteryDetailPage(
            conn: conn,
            manager: _session.manager,
            aliases: _session.aliases,
            keepAwake: _session.keepAwake),
      );

  /// Select [conn] in the desktop pane (the Settings tab yields to Detail).
  void select(BatteryConnection conn) {
    setState(() {
      _selected = conn;
      if (_tab == DesktopTab.settings) _tab = DesktopTab.detail;
    });
  }

  void setTab(DesktopTab t) => setState(() => _tab = t);

  /// Move the selection by [delta] rows (Up = -1, Down = +1). Returns true
  /// when a battery was selected / opened.
  bool moveSelection(int delta) {
    final batteries = _session.manager.batteries;
    if (batteries.isEmpty) return false;
    final current = isWide
        ? _selected
        : (gRouteTracker.detailIsTop
            ? gRouteTracker.top!.settings.arguments as BatteryConnection?
            : _selected);
    var idx = current == null ? -1 : batteries.indexOf(current);
    idx = idx < 0 ? 0 : (idx + delta).clamp(0, batteries.length - 1);
    final next = batteries[idx];
    if (isWide) {
      if (identical(next, _selected)) return true;
      select(next);
      return true;
    }
    // Narrow: only meaningful while a detail page is open — swap it.
    if (!gRouteTracker.detailIsTop) return false;
    if (identical(next, current)) return true;
    final nav = gNavKey.currentState;
    if (nav == null) return false;
    _selected = next;
    nav.pushReplacement(detailRoute(next));
    return true;
  }

  bool _textFieldFocused() {
    final f = FocusManager.instance.primaryFocus;
    final ctx = f?.context;
    if (ctx == null) return false;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    if (!mounted) return false;
    final key = e.logicalKey;
    final isArrow =
        key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown;
    final isEsc = key == LogicalKeyboardKey.escape;
    if (!isArrow && !isEsc) return false;
    if (_textFieldFocused()) return false;
    if (isWide) {
      // A dialog / sheet above the shell owns the keyboard.
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return false;
      if (isEsc) return false;
      return moveSelection(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
    }
    if (isEsc) {
      // Esc returns to the list: pop a pushed PAGE, never a dialog.
      if (!gRouteTracker.pageIsPushed) return false;
      gNavKey.currentState?.maybePop();
      return true;
    }
    return moveSelection(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
  }

  void _arrangementChanged(bool wide) {
    _wide = wide;
    if (!wide) return;
    // Going wide with a phone route open: the pane shows it now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = gNavKey.currentState;
      if (nav != null && gRouteTracker.pageIsPushed) {
        nav.popUntil((r) => r.isFirst);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= kDesktopMinWidth;
        if (wide != _wide) _arrangementChanged(wide);
        if (!wide) {
          return BatteryListPage(session: _session, onOpenDetail: openBattery);
        }
        // Keep the selection valid: a dropped pack falls back to the first.
        final batteries = _session.manager.batteries;
        final sel = _selected;
        if (sel == null || !batteries.contains(sel)) {
          _selected = batteries.isEmpty ? null : batteries.first;
        }
        return DesktopShell(
          session: _session,
          selected: _selected,
          onSelect: select,
          tab: _tab,
          onTab: setTab,
        );
      },
    );
  }
}
