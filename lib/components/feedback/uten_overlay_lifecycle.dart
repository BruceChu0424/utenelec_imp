import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps a root overlay owned by its source route and render lifecycle.
///
/// Transient overlays close on route cover, owner removal, window blur or Escape.
/// Persistent busy overlays only hide, then become available again on return;
/// their business operation and submission lock remain owned by the caller.
/// Frame observations follow actual UI frames and never request idle frames.
class UtenOverlayLifecycle with WidgetsBindingObserver {
  UtenOverlayLifecycle({
    required this.onUnavailable,
    this.onAvailable,
    this.transient = true,
  });

  final VoidCallback onUnavailable;
  final VoidCallback? onAvailable;
  final bool transient;

  BuildContext? _owner;
  List<ModalRoute<dynamic>> _routes = const [];
  ValueListenable<TickerModeData>? _tickerMode;
  int? _viewId;
  bool _viewFocused = true;
  bool _observing = false;
  bool _disposed = false;
  bool _framePending = false;
  bool? _available;
  int _revision = 0;

  static final Set<UtenOverlayLifecycle> _transients = {};

  bool get isAvailable {
    final app = WidgetsBinding.instance.lifecycleState;
    return !_disposed &&
        (_owner?.mounted ?? false) &&
        _routes.every((route) => route.isCurrent) &&
        (_tickerMode?.value.enabled ?? true) &&
        _viewFocused &&
        (app == null || app == AppLifecycleState.resumed);
  }

  /// Call from the owner's dependency hook or immediately after inserting its
  /// entry. Reattaching after a GlobalKey move updates the route and ticker owner.
  void attach(BuildContext context) {
    if (_disposed || !context.mounted) return;
    _owner = context;
    if (!_observing) _viewFocused = true;
    _refreshOwner();
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
      if (transient) {
        if (_transients.isEmpty) {
          FocusManager.instance.addEarlyKeyEventHandler(_escape);
        }
        _transients.add(this);
      }
    }
    _evaluate();
    _watchFrame();
  }

  void _refreshOwner() {
    final owner = _owner;
    if (owner == null || !owner.mounted) return;
    final routes = <ModalRoute<dynamic>>[];
    var route = ModalRoute.of(owner);
    while (route != null && !routes.contains(route)) {
      routes.add(route);
      // A ShellRoute's child route can remain current while a root Navigator
      // dialog covers the shell. Each owning Navigator lives inside its parent
      // route, so follow that chain without including routes beneath this owner.
      final navigator = route.navigator;
      if (navigator == null || !navigator.mounted) break;
      route = ModalRoute.of(navigator.context);
    }
    _routes = routes;
    _viewId = View.maybeOf(owner)?.viewId;
    final ticker = TickerMode.getValuesNotifier(owner);
    if (!identical(ticker, _tickerMode)) {
      _tickerMode?.removeListener(_evaluate);
      _tickerMode = ticker;
      ticker.addListener(_evaluate);
    }
  }

  void _watchFrame() {
    if (_disposed || !_observing || _framePending) return;
    _framePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _framePending = false;
      if (_disposed || !_observing) return;
      // Navigator updates ModalRoute's current state for opaque pages and
      // transparent dialogs alike. A covered route can remain mounted forever.
      _refreshOwner();
      _evaluate();
      _watchFrame();
    });
  }

  void _evaluate() {
    if (_disposed || !_observing) return;
    final available = isAvailable;
    if (_available == available) return;
    _available = available;
    final revision = ++_revision;
    void notify() {
      if (_disposed || revision != _revision) return;
      if (available) {
        onAvailable?.call();
      } else {
        onUnavailable();
      }
    }

    // Route/ticker notifications can arrive during an ancestor's build. The
    // owner may remove an entry, dispose an input or insert its returning mask.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => notify());
    } else {
      notify();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _evaluate();

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (_viewId != null && event.viewId != _viewId) return;
    _viewFocused = event.state == ViewFocusState.focused;
    _evaluate();
  }

  static KeyEventResult _escape(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        _transients.isEmpty) {
      return KeyEventResult.ignored;
    }
    // Nested menus may have different owners; dismiss every active transient
    // without allowing Escape to reach a business operation underneath them.
    for (final owner in _transients.toList(growable: false).reversed) {
      if (!owner._disposed) owner.onUnavailable();
    }
    return KeyEventResult.handled;
  }

  /// Deactivation hides even a still-mounted owner; activation must attach again.
  void detach() {
    if (_disposed) return;
    _revision++;
    _available = null;
    _stopObserving();
    onUnavailable();
  }

  void _stopObserving() {
    _observing = false;
    WidgetsBinding.instance.removeObserver(this);
    _tickerMode?.removeListener(_evaluate);
    _tickerMode = null;
    _owner = null;
    _routes = const [];
    _transients.remove(this);
    if (_transients.isEmpty) {
      FocusManager.instance.removeEarlyKeyEventHandler(_escape);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    _stopObserving();
  }
}
