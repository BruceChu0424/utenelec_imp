import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final clientUpdateNavigationProvider = Provider(
  (ref) => ClientUpdateNavigation(),
);

/// A business detail page is still a valid login destination. Only a modal
/// dialog or the update page itself delays an automatic update announcement.
class ClientUpdateNavigation extends NavigatorObserver {
  Route<dynamic>? _top;
  bool get blocked =>
      _top is PopupRoute || _top?.settings.name == '/settings/software-update';
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _top = route;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _top = previousRoute;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(_top, route)) _top = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(_top, oldRoute)) _top = newRoute;
  }
}
