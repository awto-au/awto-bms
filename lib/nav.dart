/// Root navigator key (#45): lets a tapped system notification deep-link into a
/// battery from outside a widget's own context (e.g. on resume/cold-start),
/// and gives the app session a context for toasts / confirm dialogs (#68).
library;

import 'package:flutter/widgets.dart';

final GlobalKey<NavigatorState> gNavKey = GlobalKey<NavigatorState>();

/// Route name the phone layout gives a pushed battery-detail route, so the
/// keyboard handler (#68) can tell it from a dialog or the charts page.
const String kDetailRouteName = 'battery-detail';

/// #68: which route is on top of the root navigator — a [NavigatorObserver]
/// registered by the app so the shell's keyboard handler can pop a pushed
/// PAGE (Esc on a narrow window) without touching dialogs.
class RouteTracker extends NavigatorObserver {
  Route<dynamic>? top;

  /// True while a full page (not a dialog / sheet) sits above the first route.
  bool get pageIsPushed => top is PageRoute && !(top!.isFirst);

  /// True while the top route is the phone detail page.
  bool get detailIsTop =>
      pageIsPushed && top!.settings.name == kDetailRouteName;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      top = route;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      top = previousRoute;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      top = previousRoute;
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      top = newRoute;
}

final RouteTracker gRouteTracker = RouteTracker();
