import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web_update_safety.dart';

final rootUpdateSafetyNavigationProvider = Provider((ref) {
  final observer = UpdateSafetyNavigation();
  ref.onDispose(observer.dispose);
  return observer;
});

final shellUpdateSafetyNavigationProvider = Provider((ref) {
  final observer = UpdateSafetyNavigation();
  ref.onDispose(observer.dispose);
  return observer;
});

/// Both navigators participate: a shell-owned editor dialog must protect work
/// just as a root authentication dialog does. Removing a covered route does not
/// erase a still-open underlying dialog from the safety snapshot.
class UpdateSafetyNavigation extends NavigatorObserver {
  UpdateSafetyNavigation({WebUpdateSafetyRegistry? registry})
    : _registry = registry ?? webUpdateSafety {
    _registry.register(this, _probe);
  }

  final WebUpdateSafetyRegistry _registry;
  final _routes = <Route<dynamic>>[];
  bool _disposed = false;

  bool get blocked => _routes.any(
    (route) =>
        route is PopupRoute ||
        (route.settings is! Page &&
            route.settings.name != '/settings/software-update'),
  );

  WebUpdateSafetyState _probe() => WebUpdateSafetyState(blocked: blocked);

  void _changed() {
    if (!_disposed) _registry.changed();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _changed();
  }

  void dispose() {
    _disposed = true;
    _registry.unregister(this);
    _routes.clear();
  }
}
