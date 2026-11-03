import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final desktopWindowModalRegistryProvider = Provider((ref) {
  final registry = DesktopWindowModalRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

/// Mirrors only route barriers into the native-sized title strip. The routed
/// Navigator keeps its existing bounds, zoom, focus and editor lifetime.
class DesktopWindowModalRegistry extends ChangeNotifier {
  final _observers = <DesktopWindowModalObserver>[];
  bool _scheduled = false;
  bool _disposed = false;

  List<PopupRoute<dynamic>> get barriers => [
    // Shell barriers sit below root authentication/confirmation dialogs.
    for (final observer in [
      ..._observers,
    ]..sort((a, b) => a.layer.compareTo(b.layer)))
      if (_navigatorVisible(observer.navigator)) ...observer._visibleBarriers,
  ];

  bool _navigatorVisible(NavigatorState? navigator) {
    if (navigator == null || !navigator.mounted) return false;
    final parent = ModalRoute.of(navigator.context);
    if (parent == null) return true;
    for (final observer in _observers) {
      final index = observer._routes.indexOf(parent);
      if (index < 0) continue;
      if (observer._routes
          .skip(index + 1)
          .any((route) => route is TransitionRoute && route.opaque)) {
        return false;
      }
    }
    return _navigatorVisible(parent.navigator);
  }

  void _changed() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    // Navigator observers also run during declarative route reconciliation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _observers.clear();
    super.dispose();
  }
}

class DesktopWindowModalObserver extends NavigatorObserver {
  DesktopWindowModalObserver(this.registry, {this.layer = 0}) {
    registry._observers.add(this);
  }

  final DesktopWindowModalRegistry registry;
  final int layer;
  final _routes = <Route<dynamic>>[];
  bool _disposed = false;

  Iterable<PopupRoute<dynamic>> get _visibleBarriers {
    final lastOpaque = _routes.lastIndexWhere(
      (route) => route is TransitionRoute && route.opaque,
    );
    return _routes.skip(lastOpaque + 1).whereType<PopupRoute<dynamic>>();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    registry._changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      // The content barrier remains visible throughout the reverse transition.
      route.completed.whenComplete(() => _remove(route));
    } else {
      _remove(route);
    }
    registry._changed();
  }

  void _remove(Route<dynamic> route) {
    if (_disposed) return;
    _routes.remove(route);
    registry._changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      _routes.removeAt(index);
      if (newRoute != null) _routes.insert(index, newRoute);
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    registry._changed();
  }

  void dispose() {
    _disposed = true;
    _routes.clear();
    registry._observers.remove(this);
    registry._changed();
  }
}

/// Lives in the window overlay, above extended navigation header surfaces and
/// native controls. Busy overlays already use this overlay and need no copy.
class DesktopWindowModalBarrierHost extends StatefulWidget {
  const DesktopWindowModalBarrierHost({
    super.key,
    required this.registry,
    required this.height,
    required this.child,
    this.contentCoversStrip = false,
  });

  final DesktopWindowModalRegistry registry;
  final double height;
  final Widget child;
  final bool contentCoversStrip;

  @override
  State<DesktopWindowModalBarrierHost> createState() =>
      _DesktopWindowModalBarrierHostState();
}

class _DesktopWindowModalBarrierHostState
    extends State<DesktopWindowModalBarrierHost> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    widget.registry.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void didUpdateWidget(DesktopWindowModalBarrierHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) {
      oldWidget.registry.removeListener(_sync);
      widget.registry.addListener(_sync);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  void _sync() {
    if (widget.registry.barriers.isEmpty) {
      _remove();
    } else if (_entry == null) {
      _entry = OverlayEntry(builder: _buildBarriers);
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    } else {
      _entry!.markNeedsBuild();
    }
  }

  Widget _buildBarriers(BuildContext context) => Positioned(
    key: const Key('desktop-window-modal-barrier'),
    top: 0,
    left: 0,
    right: 0,
    height: widget.height,
    child: ExcludeSemantics(
      // The actual route already owns modal focus and dismissal semantics.
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final route in widget.registry.barriers)
            if (route.animation case final animation?)
              AnimatedBuilder(
                key: ObjectKey(route),
                animation: animation,
                builder: (context, _) => IgnorePointer(
                  ignoring: !animation.isForwardOrCompleted,
                  child: ModalBarrier(
                    color: widget.contentCoversStrip || route.offstage
                        ? null
                        : Color.lerp(
                            route.barrierColor?.withValues(alpha: 0),
                            route.barrierColor,
                            route.barrierCurve.transform(animation.value),
                          ),
                    dismissible: route.barrierDismissible,
                    onDismiss: () {
                      if (route.isCurrent && route.barrierDismissible) {
                        route.navigator?.maybePop();
                      }
                    },
                  ),
                ),
              ),
        ],
      ),
    ),
  );

  void _remove() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  @override
  void dispose() {
    widget.registry.removeListener(_sync);
    _remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Full-bleed login already has a route barrier behind the native controls.
/// Tint only painted control pixels, so transparent drag space is not dimmed
/// a second time. The mirrored transparent barrier still blocks/dismisses taps.
class DesktopWindowModalControlTint extends StatelessWidget {
  const DesktopWindowModalControlTint({
    super.key,
    required this.registry,
    required this.enabled,
    required this.child,
  });

  final DesktopWindowModalRegistry registry;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry,
    child: child,
    builder: (context, child) {
      final routes = registry.barriers;
      return AnimatedBuilder(
        animation: Listenable.merge([
          for (final route in routes) route.animation,
        ]),
        child: child,
        builder: (context, child) {
          var tint = Colors.transparent;
          if (enabled) {
            for (final route in routes) {
              if (route.offstage) continue;
              final color = Color.lerp(
                route.barrierColor?.withValues(alpha: 0),
                route.barrierColor,
                route.barrierCurve.transform(route.animation?.value ?? 0),
              );
              if (color != null) tint = Color.alphaBlend(color, tint);
            }
          }
          return ExcludeSemantics(
            excluding: routes.isNotEmpty,
            child: ExcludeFocus(
              excluding: routes.isNotEmpty,
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(tint, BlendMode.srcATop),
                child: child,
              ),
            ),
          );
        },
      );
    },
  );
}
