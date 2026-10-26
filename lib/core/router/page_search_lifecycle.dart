import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Gives pages built outside a GoRoute's page (for example kept-alive shell
/// tabs) an explicit search-session location. Ordinary route pages need no scope.
class PageSearchRouteScope extends InheritedWidget {
  const PageSearchRouteScope({
    super.key,
    required this.location,
    this.pageKey,
    required super.child,
  });

  final String location;
  final LocalKey? pageKey;

  @override
  bool updateShouldNotify(PageSearchRouteScope oldWidget) =>
      location != oldWidget.location || pageKey != oldWidget.pageKey;
}

/// Tracks one search session across actual GoRouter page navigation.
///
/// Attach from State.didChangeDependencies and dispose with the owning State.
/// Initial values, rebuilds, query-string changes, dialogs and drawers keep the
/// current search. Leaving a page cancels pending work through [onLeave]; coming
/// back clears its search through [onReturn], after the current build completes.
/// This also works when the router keeps the original page mounted below a
/// pushed detail page or in an offstage shell tab. No provider scope is needed.
class PageSearchLifecycle {
  PageSearchLifecycle({required this.onLeave, required this.onReturn});

  final VoidCallback onLeave;
  final VoidCallback onReturn;

  GoRouter? _router;
  String? _location;
  LocalKey? _pageKey;
  bool _active = false;
  bool _hasLeft = false;
  bool _disposed = false;
  int _revision = 0;

  void attach(BuildContext context, {bool fallbackToActivePage = false}) {
    if (_disposed) return;
    final router = GoRouter.maybeOf(context);
    if (identical(router, _router)) return;
    _detach();
    if (router == null) return;

    final scope = context
        .dependOnInheritedWidgetOfExactType<PageSearchRouteScope>();
    // A popup or Navigator.push route has no independent GoRouter page. An
    // explicit scope can carry the host identity into a fullscreen presentation
    // so search inputs first mounted there still join the host's session.
    final settings = ModalRoute.of(context)?.settings;
    if (scope == null && settings is! Page && !fallbackToActivePage) return;
    final settingsKey = settings is Page ? settings.key : null;
    final config = router.routerDelegate.currentConfiguration;
    if (config.isEmpty || config.isError) return;

    String? location = scope?.location;
    LocalKey? pageKey = scope?.pageKey;
    if (location == null) {
      // Reading by Page.key finds this page even when a pushed page is already
      // on top. Reading the global router state would capture the pushed page.
      final match = _findPage(config.matches, settingsKey);
      if (match != null) {
        location = match.matchedLocation;
        pageKey = match.pageKey;
      }
      // Shell tabs may be constructed directly by the shell, rather than by a
      // GoRoute. They mount on first visit, so capture that active leaf once.
      location ??= config.last.matchedLocation;
      // Navigation initiated in a dialog/native Navigator page belongs to the
      // active GoRouter page. Keep its key as well as its path: a second push
      // to the same URL is still a different page visit.
      if (fallbackToActivePage && match == null) {
        pageKey ??= config.last.pageKey;
      }
    }
    _router = router;
    _location = location;
    _pageKey = pageKey;
    _active = _isActive();
    // Responsive/conditional content may mount a new input while its page is
    // already covered by a detail page. It still belongs to the old session.
    _hasLeft = !_active;
    router.routerDelegate.addListener(_onNavigated);
  }

  /// Carries the captured host identity into a fullscreen/dialog presentation.
  /// Its controls share this page's search session even if first mounted there.
  Widget wrap(Widget child) {
    final location = _location;
    if (_disposed || location == null) return child;
    return PageSearchRouteScope(
      location: location,
      pageKey: _pageKey,
      child: child,
    );
  }

  bool _isActive() {
    final config = _router!.routerDelegate.currentConfiguration;
    if (config.isEmpty || config.isError) return false;
    final top = config.last;
    return top.matchedLocation == _location &&
        (_pageKey == null || top.pageKey == _pageKey);
  }

  void _onNavigated() {
    if (_disposed) return;
    final pageKey = _pageKey;
    if (pageKey != null) {
      final config = _router!.routerDelegate.currentConfiguration;
      final ownMatch = _findPage(config.matches, pageKey);
      if (ownMatch != null && ownMatch.matchedLocation != _location) {
        // A parameterized GoRoute can keep the same Page/State while its path
        // changes. That is a new page visit even without an intermediate pop.
        _location = ownMatch.matchedLocation;
        _revision++;
        _hasLeft = true;
        if (_active) onLeave();
        _active = false;
      }
    }
    final active = _isActive();
    if (active == _active) return;
    _active = active;
    final revision = ++_revision;
    if (!active) {
      _hasLeft = true;
      onLeave();
      return;
    }
    if (!_hasLeft) return;
    _hasLeft = false;
    // Router listeners can run during navigator build. Page callbacks often
    // update providers or setState, so dispatch only after that build finishes.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !_active || revision != _revision) return;
      onReturn();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _detach() {
    _revision++;
    _router?.routerDelegate.removeListener(_onNavigated);
    _router = null;
    _location = null;
    _pageKey = null;
  }

  void dispose() {
    _disposed = true;
    _detach();
  }
}

RouteMatch? _findPage(List<RouteMatchBase> matches, LocalKey? pageKey) {
  for (final match in matches) {
    if (match is RouteMatch && match.pageKey == pageKey) return match;
    if (match is ShellRouteMatch) {
      final found = _findPage(match.matches, pageKey);
      if (found != null) return found;
    }
  }
  return null;
}
