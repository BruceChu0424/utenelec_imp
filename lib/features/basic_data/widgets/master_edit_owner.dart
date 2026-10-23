import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/router/page_search_lifecycle.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/session_provider.dart';

/// One full editor owns its opening identity, request intent and popup routes.
/// Opt-in only: ordinary small dialogs retain their existing contract.
class MasterEditOwner extends ChangeNotifier {
  MasterEditOwner(
    this.context,
    this.ref, {
    required Set<String> permissions,
    this.requireWrite = true,
    bool Function()? isCurrent,
  }) : boundary = ref.read(sensitiveReadBoundaryProvider),
       _session = ref.read(sessionProvider.notifier),
       _ownerRoute = ModalRoute.of(context),
       _permissions = Set.unmodifiable(permissions),
       _extraIsCurrent = isCurrent {
    _intent = _session.requestIntentEpoch;
    _boundarySubscription = ref.listenManual(sensitiveReadBoundaryProvider, (
      _,
      next,
    ) {
      if (next != boundary) invalidate();
    });
    _sessionSubscription = ref.listenManual(sessionProvider, (_, _) {
      if (!this.isCurrent) invalidate();
    });
    _pageLifecycle = PageSearchLifecycle(onLeave: invalidate, onReturn: () {});
    _pageLifecycle.attach(context);
    _ownerRoute?.secondaryAnimation?.addListener(_routeChanged);
    _ownerRoute?.animation?.addListener(_routeChanged);
    _ownerRoute?.popped.then((_) => invalidate());
  }

  final BuildContext context;
  final WidgetRef ref;
  final SensitiveReadBoundary boundary;
  final SessionNotifier _session;
  final ModalRoute<dynamic>? _ownerRoute;
  final Set<String> _permissions;
  final bool requireWrite;
  final bool Function()? _extraIsCurrent;
  final Set<ModalRoute<dynamic>> _routes = {};
  late final int _intent;
  late final ProviderSubscription<SensitiveReadBoundary> _boundarySubscription;
  late final ProviderSubscription<SessionState> _sessionSubscription;
  late final PageSearchLifecycle _pageLifecycle;
  AuthenticatedRequestScope? _requests;
  bool _invalidated = false;
  bool _disposed = false;
  bool _routeCheckQueued = false;

  bool get isCurrent =>
      !_disposed &&
      !_invalidated &&
      context.mounted &&
      boundary.identity != null &&
      (!requireWrite || !boundary.identity!.readOnly) &&
      (_extraIsCurrent?.call() ?? true) &&
      (boundary.superAdmin || boundary.permissions.containsAll(_permissions)) &&
      identical(ref.read(sessionProvider.notifier), _session) &&
      _session.requestIntentEpoch == _intent &&
      ref.read(sensitiveReadBoundaryProvider) == boundary &&
      (_ownerRoute?.isActive ?? true) &&
      (!requireWrite || _writeRouteIsCurrent);

  bool get _writeRouteIsCurrent {
    // A ShellRoute leaf remains current in its nested Navigator while a root
    // popup is covered. Once this operation owns an active popup, only its
    // popup stack can authorize a write; the leaf's status is insufficient.
    final active = _routes.where((route) => route.isActive);
    return active.isEmpty
        ? (_ownerRoute?.isCurrent ?? true)
        : active.any((route) => route.isCurrent);
  }

  Future<bool> bindRequests() async {
    if (!isCurrent) return false;
    try {
      _requests = await boundary.api.captureRequestScope(
        isCurrent: () => isCurrent,
      );
      return isCurrent;
    } catch (_) {
      invalidate();
      return false;
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    final requests = _requests;
    if (!isCurrent || requests == null) {
      throw AuthenticatedRequestScope.changed();
    }
    final result = await requests.run(() {
      if (!isCurrent) throw AuthenticatedRequestScope.changed();
      return action();
    });
    await requests.verify();
    return result;
  }

  void trackRoute(ModalRoute<dynamic>? route) {
    if (route == null || _disposed || !_routes.add(route)) return;
    route.secondaryAnimation?.addListener(_routeChanged);
    route.animation?.addListener(_routeChanged);
    route.popped.then((_) => _forgetRoute(route));
    if (_invalidated) _queueCleanup();
  }

  void closeRoute(ModalRoute<dynamic>? route) {
    if (route == null) return;
    _forgetRoute(route);
    if (route.isActive && route.navigator?.mounted == true) {
      route.navigator?.removeRoute(route);
    }
  }

  void _forgetRoute(ModalRoute<dynamic> route) {
    if (!_routes.remove(route)) return;
    route.secondaryAnimation?.removeListener(_routeChanged);
    route.animation?.removeListener(_routeChanged);
  }

  Widget ownDialog(BuildContext popupContext, Widget child) {
    if (_disposed) return const SizedBox.shrink();
    trackRoute(ModalRoute.of(popupContext));
    return Consumer(
      builder: (dialogContext, watchRef, _) {
        if (_disposed) return const SizedBox.shrink();
        watchRef.watch(sensitiveReadBoundaryProvider);
        watchRef.watch(sessionProvider);
        // PopupRoute does not necessarily transition with a page pushed above
        // it. Subscribe inside its subtree so route-status changes are observed
        // even when neither animation runs. A nested owned picker may register
        // later in this frame, so evaluate the complete route set afterwards.
        ModalRoute.isCurrentOf(dialogContext);
        _routeChanged();
        return ListenableBuilder(
          listenable: this,
          builder: (_, _) => isCurrent ? child : const SizedBox.shrink(),
        );
      },
    );
  }

  void invalidate() {
    if (_disposed || _invalidated) return;
    _invalidated = true;
    _queueCleanup();
  }

  void _routeChanged() {
    if (_disposed || _invalidated || _routeCheckQueued) return;
    _routeCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeCheckQueued = false;
      if (!_disposed && !isCurrent) invalidate();
    });
  }

  void _queueCleanup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      for (final route in _routes.toList()) {
        closeRoute(route);
      }
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _boundarySubscription.close();
    _sessionSubscription.close();
    _pageLifecycle.dispose();
    _ownerRoute?.secondaryAnimation?.removeListener(_routeChanged);
    _ownerRoute?.animation?.removeListener(_routeChanged);
    final routes = _routes.toList();
    for (final route in routes) {
      _forgetRoute(route);
    }
    if (routes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final route in routes) {
          if (route.isActive && route.navigator?.mounted == true) {
            route.navigator?.removeRoute(route);
          }
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }
    super.dispose();
  }
}
