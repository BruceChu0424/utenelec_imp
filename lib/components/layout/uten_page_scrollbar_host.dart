import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'uten_content_scrollbar.dart';
import 'uten_scroll_signal_scope.dart';
import 'uten_scrollbar_rail_delegate.dart';
import 'uten_page_layout.dart';

/// Explicit page viewports outrank automatic decorators. Embedded tables and
/// hierarchy panes opt out rather than competing with the main page viewport.
abstract final class UtenPageScrollbarPriority {
  static const int automatic = 0;
  static const int page = 100;
  static const int table = 200;
}

/// Paints the active page's primary vertical rail at the shell's outer edge.
/// Content retains its existing margin, viewport, controllers and widget tree.
class UtenPageScrollbarHost extends StatefulWidget {
  const UtenPageScrollbarHost({super.key, required this.child});

  static const railKey = ValueKey('uten-page-scrollbar-rail');
  static const double rightInset = UtenPageChromeMetrics.railRightWindow;
  static const double railWidth = UtenPageChromeMetrics.railWidthWindow;
  static const double maximumSourceRightInset = 64;

  /// Imperative surface callbacks invalidate once; they do not start polling.
  static void invalidate(BuildContext context) {
    if (!context.mounted) return;
    context
        .getInheritedWidgetOfExactType<_PageScrollbarScope>()
        ?.host
        ?._railChanged();
  }

  final Widget child;

  @override
  State<UtenPageScrollbarHost> createState() => _UtenPageScrollbarHostState();
}

class _UtenPageScrollbarHostState extends State<UtenPageScrollbarHost> {
  final _hostKey = GlobalKey();
  _PageScrollbarRailGateRender? _railRender;
  final _sources = <_UtenPageScrollbarSourceState, int>{};
  final _modalBlocks = <Object>{};
  final _layoutRevision = ValueNotifier<int>(0);
  final _layoutOwners = <Object, _UtenPageScrollbarSourceState>{};
  Set<_UtenPageScrollbarSourceState> _layoutSources = {};
  Set<Object> _layoutTokens = {};
  _PageScrollbarSelection? _selection;
  bool _scheduled = false;
  bool _routeCurrent = true;
  bool _tickerEnabled = true;
  int _nextOrder = 0;
  Size? _lastHostSize;
  bool _elementActive = true;
  UtenScrollbarRailDelegate? _delegateUpdates;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant UtenPageScrollbarHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  void _register(_UtenPageScrollbarSourceState source) {
    _sources.putIfAbsent(source, () => _nextOrder++);
    _scheduleMeasure();
  }

  void _unregister(_UtenPageScrollbarSourceState source) {
    if (_sources.remove(source) != null) _railChanged();
  }

  void _setModalBlock(Object token, bool blocked) {
    final changed = blocked
        ? _modalBlocks.add(token)
        : _modalBlocks.remove(token);
    if (changed) _railChanged();
  }

  void _railChanged() {
    if (!mounted || !_elementActive) return;
    final rail = _railRender;
    if (rail != null && rail.attached) {
      rail.markNeedsPaint();
      rail.markNeedsSemanticsUpdate();
    }
    _scheduleMeasure();
  }

  void _rememberRailRender(_PageScrollbarRailGateRender render) =>
      _railRender = render;

  void _forgetRailRender(_PageScrollbarRailGateRender render) {
    if (identical(_railRender, render)) _railRender = null;
  }

  bool _canPaintRail() {
    final host = _hostBox;
    final selected = _selection;
    return _modalBlocks.isEmpty &&
        _routeCurrent &&
        _tickerEnabled &&
        host != null &&
        selected != null &&
        _candidate(selected.source, host) != null;
  }

  void _scheduleMeasure() {
    if (!mounted || !_elementActive || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && _elementActive) _measure();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  RenderBox? get _hostBox {
    if (!_elementActive) return null;
    final box = _hostKey.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  void _hostGeometryChanged() {
    final host = _hostBox;
    if (host == null) return;
    if (_lastHostSize != host.size) {
      _lastHostSize = host.size;
      _scheduleMeasure();
    }
    // A retained Offstage/repaint-boundary subtree need not paint its source
    // again when an ancestor hides or translates it. Validate only the current
    // selection during paints that the application already requested.
    final selected = _selection;
    if (selected != null &&
        !selected.sameGeometry(_candidate(selected.source, host))) {
      _scheduleMeasure();
    }
  }

  Rect? _rawBounds(_UtenPageScrollbarSourceState source) {
    final host = _hostBox;
    final box = source._viewportBox;
    if (host == null || box == null) return null;
    try {
      return MatrixUtils.transformRect(
        box.getTransformTo(host),
        Offset.zero & box.size,
      );
    } on FlutterError {
      return null;
    }
  }

  bool _hiddenIndexedBranch(RenderObject viewport, RenderObject host) {
    RenderObject child = viewport;
    for (
      RenderObject? parent = child.parent;
      parent != null && parent != host;
      parent = parent.parent
    ) {
      if (parent is RenderIndexedStack) {
        RenderObject? selected = parent.firstChild;
        final index = parent.index;
        if (index == null) return true;
        for (var i = 0; i < index && selected != null; i++) {
          selected = parent.childAfter(selected as RenderBox);
        }
        if (!identical(selected, child)) return true;
      }
      child = parent;
    }
    return false;
  }

  _PageScrollbarSelection? _candidate(
    _UtenPageScrollbarSourceState source,
    RenderBox host,
  ) {
    if (!source.mounted ||
        !source._elementActive ||
        !identical(source._host, this) ||
        !_sources.containsKey(source) ||
        !_layoutSources.contains(source) ||
        !source._contextEligible ||
        !source.widget.enabled ||
        source._scaffold?.isDrawerOpen == true ||
        source._scaffold?.isEndDrawerOpen == true) {
      return null;
    }
    final controller = source.widget.controller;
    if (controller.positions.length != 1) return null;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        !position.hasViewportDimension ||
        position.axis != Axis.vertical ||
        !position.maxScrollExtent.isFinite ||
        !position.minScrollExtent.isFinite) {
      return null;
    }
    final railDelegate = source._scrollSignals?.railDelegateFor(controller);
    final metrics = railDelegate?.metrics ?? position;
    if (!metrics.hasPixels ||
        !metrics.hasContentDimensions ||
        !metrics.hasViewportDimension ||
        !metrics.maxScrollExtent.isFinite ||
        !metrics.minScrollExtent.isFinite ||
        metrics.maxScrollExtent <= metrics.minScrollExtent) {
      return null;
    }
    if (railDelegate?.viewportKey case final key?) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox ||
          !box.attached ||
          !box.hasSize ||
          box.size.isEmpty) {
        return null;
      }
    }
    final viewport = source._viewportBox;
    final raw = _rawBounds(source);
    if (viewport == null || raw == null || !raw.isFinite) return null;
    if (_hiddenIndexedBranch(viewport, host)) return null;
    // A partially translated page can have its reserved local lane outside
    // the host. Wait until that trailing edge is visible before taking it over.
    if (raw.right > host.size.width + .1) return null;
    var visible = raw.intersect(Offset.zero & host.size);
    for (RenderObject? parent = viewport; parent != null && parent != host;) {
      if ((parent is RenderOffstage && parent.offstage) ||
          (parent is RenderOpacity && parent.opacity == 0)) {
        source._lastBounds = null;
        return null;
      }
      if (parent is RenderBox &&
          parent.hasSize &&
          (parent is RenderAbstractViewport ||
              parent is RenderClipRect ||
              parent is RenderClipRRect)) {
        visible = visible.intersect(
          MatrixUtils.transformRect(
            parent.getTransformTo(host),
            Offset.zero & parent.size,
          ),
        );
      }
      parent = parent.parent;
    }
    final roleMinimum =
        source.widget.priority >= UtenPageScrollbarPriority.table
        ? 96.0
        : source.widget.priority >= UtenPageScrollbarPriority.page
        ? 48.0
        : 48.0;
    final minimumHeight = math.min(roleMinimum, host.size.height * .25);
    final rightDistance = host.size.width - visible.right;
    if (visible.isEmpty ||
        visible.height < minimumHeight ||
        rightDistance < -1 ||
        rightDistance > UtenPageScrollbarHost.maximumSourceRightInset) {
      return null;
    }
    // Automatic decorators must span a substantial part of the page. A small
    // right-aligned editor or side panel is not the primary page viewport.
    if (source.widget.priority == UtenPageScrollbarPriority.automatic &&
        visible.width < math.min(320.0, host.size.width * .5)) {
      return null;
    }
    final clippedBottom = math.max(0.0, raw.bottom - visible.bottom);
    return _PageScrollbarSelection(
      source: source,
      controller: controller,
      bounds: visible,
      bottomInset: math.max(0, source.widget.bottomInset - clippedBottom),
      priority: source.widget.priority,
      rightDistance: rightDistance,
      railWidth: UtenPageScrollbarHost.railWidth,
      order: _sources[source]!,
      scrollSignals: source._scrollSignals,
      railDelegate: railDelegate,
      metricsSnapshot: (
        position,
        railDelegate?.metricsIdentity,
        metrics.minScrollExtent,
        metrics.maxScrollExtent,
        metrics.viewportDimension,
        metrics.axisDirection,
      ),
    );
  }

  void _measure() {
    final host = _hostBox;
    final layoutChanged = host != null && _updateLayoutOwners(host);
    final candidates = <_PageScrollbarSelection>[];
    if (host != null &&
        host.size.width.isFinite &&
        host.size.height.isFinite &&
        _routeCurrent &&
        _tickerEnabled &&
        _modalBlocks.isEmpty) {
      for (final source in _sources.keys.toList(growable: false)) {
        final candidate = _candidate(source, host);
        if (candidate != null) candidates.add(candidate);
      }
    }
    candidates.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      final right = a.rightDistance.compareTo(b.rightDistance);
      if (right != 0) return right;
      final height = b.bounds.height.compareTo(a.bounds.height);
      if (height != 0) return height;
      final width = b.bounds.width.compareTo(a.bounds.width);
      return width != 0 ? width : a.order.compareTo(b.order);
    });
    var next = candidates.firstOrNull;
    // A shared compact adapter may have inspected several source controllers.
    // Rebind it to the final chosen source before publishing its metrics.
    if (next != null && host != null && next.railDelegate != null) {
      next = _candidate(next.source, host);
    }
    if (!identical(_delegateUpdates, next?.railDelegate)) {
      _delegateUpdates?.removeListener(_scheduleMeasure);
      _delegateUpdates = next?.railDelegate;
      _delegateUpdates?.addListener(_scheduleMeasure);
    }
    final geometryChanged = !(_selection?.sameGeometry(next) ?? next == null);
    if (!geometryChanged && !layoutChanged) return;
    if (geometryChanged) {
      setState(() => _selection = next);
    } else {
      _selection = next;
    }
    if (layoutChanged) _layoutRevision.value++;
  }

  bool _updateLayoutOwners(RenderBox host) {
    final grouped = <Object, List<_UtenPageScrollbarSourceState>>{};
    for (final source in _sources.keys) {
      if (!source.mounted ||
          !source._elementActive ||
          !source._layoutContextEligible ||
          source._layoutDomain == null) {
        continue;
      }
      grouped.putIfAbsent(source._layoutDomain!, () => []).add(source);
    }
    _layoutOwners.removeWhere((domain, _) => !grouped.containsKey(domain));
    final owned = <_UtenPageScrollbarSourceState>{};
    for (final entry in grouped.entries) {
      final eligible =
          entry.value.where((source) {
            if (!source._layoutForeground) return false;
            final bounds = _rawBounds(source);
            if (bounds == null ||
                bounds.isEmpty ||
                !bounds.isFinite ||
                bounds.right > host.size.width + .1 ||
                host.size.width - bounds.right >
                    UtenPageScrollbarHost.maximumSourceRightInset) {
              return false;
            }
            if (source.widget.priority == UtenPageScrollbarPriority.automatic &&
                bounds.width < math.min(320, host.size.width * .5)) {
              return false;
            }
            if (source.widget.priority == UtenPageScrollbarPriority.automatic &&
                !identical(source, _layoutOwners[entry.key]) &&
                bounds.height < math.min(240, host.size.height * .25)) {
              return false;
            }
            final box = source._viewportBox;
            if (box != null && _hiddenIndexedBranch(box, host)) return false;
            for (
              RenderObject? parent = box;
              parent != null && parent != host;
              parent = parent.parent
            ) {
              if ((parent is RenderOffstage && parent.offstage) ||
                  (parent is RenderOpacity && parent.opacity == 0)) {
                return false;
              }
            }
            return true;
          }).toList()..sort((a, b) {
            final priority = b.widget.priority.compareTo(a.widget.priority);
            if (priority != 0) return priority;
            final ra = _rawBounds(a)!;
            final rb = _rawBounds(b)!;
            final right = rb.right.compareTo(ra.right);
            if (right != 0) return right;
            final height = rb.height.compareTo(ra.height);
            return height != 0 ? height : _sources[a]!.compareTo(_sources[b]!);
          });
      var owner = eligible.firstOrNull;
      final retained = _layoutOwners[entry.key];
      if (retained != null &&
          eligible.contains(retained) &&
          owner != null &&
          retained.widget.priority >= owner.widget.priority &&
          (_rawBounds(retained)!.right - _rawBounds(owner)!.right).abs() < 1) {
        // Height can change as text reflows after the old lane is removed.
        // Keep a same-role/same-edge lease rather than oscillating ownership
        // between two independent stacked viewports on every content change.
        owner = retained;
      }
      // A retained background domain keeps its own lease while Offstage or a
      // popup covers it. Other PageRoute/tab domains never compete with it.
      owner ??= entry.value.contains(_layoutOwners[entry.key])
          ? _layoutOwners[entry.key]
          : null;
      if (owner == null) continue;
      _layoutOwners[entry.key] = owner;
      owned.add(owner);
      final delegate = owner._scrollSignals?.railDelegateFor(
        owner.widget.controller,
      );
      for (final source in entry.value) {
        if (identical(source, owner)) continue;
        final samePosition =
            source.widget.controller.positions.length == 1 &&
            owner.widget.controller.positions.length == 1 &&
            identical(
              source.widget.controller.position,
              owner.widget.controller.position,
            );
        var ancestor = false;
        if (!samePosition &&
            source.widget.priority == UtenPageScrollbarPriority.automatic) {
          owner.context.visitAncestorElements((element) {
            if (identical(element, source.context)) {
              ancestor = true;
              return false;
            }
            return element.widget is! _PageScrollbarScope;
          });
        }
        if (samePosition || ancestor) owned.add(source);
      }
      delegate?.bindSource(owner.widget.controller);
    }
    final tokens = {for (final source in owned) source._layoutToken};
    final changed =
        owned.length != _layoutSources.length ||
        !owned.containsAll(_layoutSources) ||
        tokens.length != _layoutTokens.length ||
        !tokens.containsAll(_layoutTokens);
    _layoutSources = owned;
    _layoutTokens = tokens;
    return changed;
  }

  @override
  void deactivate() {
    _elementActive = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _elementActive = true;
    _scheduleMeasure();
  }

  @override
  void dispose() {
    _railRender = null;
    _delegateUpdates?.removeListener(_scheduleMeasure);
    _sources.clear();
    _modalBlocks.clear();
    _layoutSources.clear();
    _layoutTokens.clear();
    _layoutOwners.clear();
    _layoutRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (_) {
      _scheduleMeasure();
      return false;
    },
    child: ScrollNotificationObserver(
      child: _PageScrollbarGeometryObserver(
        onGeometry: _hostGeometryChanged,
        child: Stack(
          key: _hostKey,
          fit: StackFit.expand,
          children: [
            _PageScrollbarScope(host: this, child: widget.child),
            if (_selection case final selection?)
              Positioned(
                top: MediaQuery.paddingOf(context).top,
                bottom: math.max(
                  MediaQuery.paddingOf(context).bottom,
                  MediaQuery.viewInsetsOf(context).bottom,
                ),
                right:
                    MediaQuery.paddingOf(context).right +
                    UtenPageChromeMetrics.canvas(
                      context,
                      UtenPageScrollbarHost.rightInset,
                    ),
                width: UtenPageChromeMetrics.canvas(
                  context,
                  selection.railWidth,
                ),
                // No decorator within the host's own rail may register again.
                child: _PageScrollbarScope(
                  host: null,
                  child: _PageScrollbarRailGate(
                    canPaint: _canPaintRail,
                    onAttached: _rememberRailRender,
                    onDetached: _forgetRailRender,
                    child: UtenContentScrollbar(
                      key: UtenPageScrollbarHost.railKey,
                      controller: selection.controller,
                      width: UtenPageChromeMetrics.canvas(
                        context,
                        selection.railWidth,
                      ),
                      windowSizedChrome: true,
                      onPointerSignal: selection.scrollSignals?.dispatch,
                      railDelegate: selection.railDelegate,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _PageScrollbarSelection {
  const _PageScrollbarSelection({
    required this.source,
    required this.controller,
    required this.bounds,
    required this.bottomInset,
    required this.priority,
    required this.rightDistance,
    required this.railWidth,
    required this.order,
    required this.metricsSnapshot,
    required this.scrollSignals,
    required this.railDelegate,
  });
  final _UtenPageScrollbarSourceState source;
  final ScrollController controller;
  final Rect bounds;
  final double bottomInset;
  final int priority;
  final double rightDistance;
  final double railWidth;
  final int order;
  final Object metricsSnapshot;
  final UtenScrollSignalController? scrollSignals;
  final UtenScrollbarRailDelegate? railDelegate;

  bool sameGeometry(_PageScrollbarSelection? other) =>
      other != null &&
      identical(source, other.source) &&
      identical(controller, other.controller) &&
      metricsSnapshot == other.metricsSnapshot &&
      identical(scrollSignals, other.scrollSignals) &&
      identical(railDelegate, other.railDelegate) &&
      (railWidth - other.railWidth).abs() < .1 &&
      (bounds.left - other.bounds.left).abs() < .1 &&
      (bounds.top - other.bounds.top).abs() < .1 &&
      (bounds.right - other.bounds.right).abs() < .1 &&
      (bounds.bottom - other.bounds.bottom).abs() < .1 &&
      (bottomInset - other.bottomInset).abs() < .1;
}

/// A source keeps the same local scrollbar and business subtree mounted. The
/// builder only changes the local bar's visibility after the host takes over.
class UtenPageScrollbarSource extends StatefulWidget {
  const UtenPageScrollbarSource({
    super.key,
    required this.controller,
    required this.builder,
    this.priority = UtenPageScrollbarPriority.automatic,
    this.enabled = true,
    this.bottomInset = 0,
    this.debugLabel,
    this.layoutToken,
  });

  final ScrollController controller;
  final Widget Function(BuildContext context, bool localVisible) builder;
  final int priority;
  final bool enabled;
  final double bottomInset;
  final String? debugLabel;
  final Object? layoutToken;

  @override
  State<UtenPageScrollbarSource> createState() =>
      _UtenPageScrollbarSourceState();
}

/// A whole table uses one unique token so header/body/hbar share its lane.
/// Shared PrimaryScrollControllers cannot accidentally merge sibling panes.
class UtenPageScrollbarLayoutBuilder extends StatelessWidget {
  const UtenPageScrollbarLayoutBuilder({
    super.key,
    required this.token,
    required this.builder,
  });
  final Object token;
  final Widget Function(BuildContext context, double localLaneWidth) builder;
  @override
  Widget build(BuildContext context) {
    final host = _PageScrollbarScope.maybeHostOf(context);
    if (host == null) return builder(context, 16);
    return ValueListenableBuilder<int>(
      valueListenable: host._layoutRevision,
      builder: (context, _, _) => builder(
        context,
        UtenPageScrollRoleScope.isPageOf(context) &&
                host._layoutTokens.contains(token)
            ? 0
            : 16,
      ),
    );
  }
}

class _UtenPageScrollbarSourceState extends State<UtenPageScrollbarSource> {
  final _noSelection = ValueNotifier<int>(0);
  _UtenPageScrollbarHostState? _host;
  ScrollController? _listenedController;
  bool _contextEligible = false;
  bool _layoutContextEligible = false;
  bool _layoutForeground = true;
  Object? _layoutDomain;
  Object get _layoutToken => widget.layoutToken ?? this;
  bool get _ownsPageLane =>
      widget.enabled &&
      _layoutContextEligible &&
      (_host?._layoutSources.contains(this) ?? false);
  bool _elementActive = true;
  ScaffoldState? _scaffold;
  UtenScrollSignalController? _scrollSignals;
  Rect? _lastBounds;

  RenderBox? get _viewportBox {
    final box = context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  bool get _insideTransientSurface {
    var transient = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is _PageScrollbarScope) return false;
      if (widget is Dialog ||
          widget is AlertDialog ||
          widget is Drawer ||
          widget is BottomSheet ||
          widget is EditableText) {
        transient = true;
        return false;
      }
      return true;
    });
    return transient;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _PageScrollbarScope.maybeHostOf(context);
    if (!identical(_host, next)) {
      _host?._unregister(this);
      _host = next;
      _lastBounds = null;
    }
    _contextEligible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        ModalRoute.of(context) is! PopupRoute &&
        !_insideTransientSurface;
    _scaffold = Scaffold.maybeOf(context);
    final domain = UtenPageLayoutDomainScope.maybeOf(context);
    Object? tabBranch;
    Element? keyedBranch;
    Element? directBranch;
    context.visitAncestorElements((element) {
      if (element.widget is TabBarView) {
        tabBranch = (element, keyedBranch);
        return false;
      }
      if (element is RenderObjectElement &&
          element.renderObject is RenderIndexedStack) {
        tabBranch = (element, directBranch);
        return false;
      }
      if (element.widget is KeyedSubtree) keyedBranch = element;
      directBranch = element;
      return true;
    });
    _layoutDomain = (
      domain?.domain ?? ModalRoute.of(context),
      _scaffold,
      tabBranch,
    );
    _layoutForeground =
        TickerMode.valuesOf(context).enabled && (domain?.active ?? true);
    _layoutContextEligible =
        ModalRoute.of(context) is! PopupRoute &&
        !_insideTransientSurface &&
        UtenPageScrollRoleScope.isPageOf(context);
    _contextEligible =
        _contextEligible && _layoutContextEligible && (domain?.active ?? true);
    _scrollSignals = UtenScrollSignalScope.maybeOf(context);
    _syncRegistration();
  }

  @override
  void didUpdateWidget(covariant UtenPageScrollbarSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRegistration();
  }

  void _syncRegistration() {
    final active =
        _elementActive &&
        _host != null &&
        _layoutContextEligible &&
        widget.enabled;
    final controller = active ? widget.controller : null;
    if (!identical(controller, _listenedController)) {
      _listenedController?.removeListener(_controllerChanged);
      _listenedController = controller;
      _listenedController?.addListener(_controllerChanged);
    }
    if (active) {
      _host!._register(this);
    } else {
      _host?._unregister(this);
    }
  }

  void _controllerChanged() => _host?._scheduleMeasure();

  void _geometryChanged() {
    final host = _host;
    if (!mounted ||
        !_elementActive ||
        host == null ||
        !widget.enabled ||
        !_layoutContextEligible) {
      return;
    }
    final bounds = host._rawBounds(this);
    if (_lastBounds == bounds) return;
    _lastBounds = bounds;
    host._scheduleMeasure();
  }

  @override
  void deactivate() {
    _elementActive = false;
    _host?._unregister(this);
    _listenedController?.removeListener(_controllerChanged);
    _listenedController = null;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _elementActive = true;
    _syncRegistration();
  }

  @override
  void dispose() {
    _host?._unregister(this);
    _listenedController?.removeListener(_controllerChanged);
    _noSelection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _host?._scheduleMeasure();
          return false;
        },
        child: _PageScrollbarGeometryObserver(
          onGeometry: _geometryChanged,
          child: ValueListenableBuilder<int>(
            valueListenable: _host?._layoutRevision ?? _noSelection,
            builder: (context, _, _) => UtenPageScrollLaneScope(
              pageOwned: _ownsPageLane,
              child: Builder(
                builder: (inner) => widget.builder(inner, !_ownsPageLane),
              ),
            ),
          ),
        ),
      );
}

/// Wrap a modal surface whose framework content mounts only while its scrim is
/// visible (for example Scaffold.drawer). Blocking follows that real lifecycle,
/// including partial drags and the whole close animation, without a timer.
class UtenPageScrollbarModalBlocker extends StatefulWidget {
  const UtenPageScrollbarModalBlocker({super.key, required this.child});
  final Widget child;

  @override
  State<UtenPageScrollbarModalBlocker> createState() =>
      _PageScrollbarModalBlockerState();
}

class _PageScrollbarModalBlockerState
    extends State<UtenPageScrollbarModalBlocker> {
  _UtenPageScrollbarHostState? _host;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _PageScrollbarScope.maybeHostOf(context);
    if (!identical(next, _host)) {
      _host?._setModalBlock(this, false);
      _host = next;
    }
    _host?._setModalBlock(this, true);
  }

  @override
  void deactivate() {
    _host?._setModalBlock(this, false);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _host?._setModalBlock(this, true);
  }

  @override
  void dispose() {
    _host?._setModalBlock(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The gate reads the current modal block during paint/hit testing, so a newly
/// mounted Drawer cannot leave one stale rail frame above its scrim while the
/// deferred selection update is pending.
class _PageScrollbarRailGate extends SingleChildRenderObjectWidget {
  const _PageScrollbarRailGate({
    required this.canPaint,
    required this.onAttached,
    required this.onDetached,
    required super.child,
  });
  final bool Function() canPaint;
  final ValueChanged<_PageScrollbarRailGateRender> onAttached;
  final ValueChanged<_PageScrollbarRailGateRender> onDetached;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PageScrollbarRailGateRender(canPaint, onAttached, onDetached);

  @override
  void updateRenderObject(
    BuildContext context,
    _PageScrollbarRailGateRender renderObject,
  ) {
    renderObject.canPaint = canPaint;
    renderObject.onAttached = onAttached;
    renderObject.onDetached = onDetached;
    if (renderObject.attached) onAttached(renderObject);
    renderObject.markNeedsPaint();
    renderObject.markNeedsSemanticsUpdate();
  }
}

class _PageScrollbarRailGateRender extends RenderProxyBox {
  _PageScrollbarRailGateRender(this.canPaint, this.onAttached, this.onDetached);
  bool Function() canPaint;
  ValueChanged<_PageScrollbarRailGateRender> onAttached;
  ValueChanged<_PageScrollbarRailGateRender> onDetached;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    onAttached(this);
  }

  @override
  void detach() {
    onDetached(this);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (canPaint()) super.paint(context, offset);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      canPaint() && super.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (canPaint()) super.visitChildrenForSemantics(visitor);
  }
}

class _PageScrollbarScope extends InheritedWidget {
  const _PageScrollbarScope({required this.host, required super.child});
  final _UtenPageScrollbarHostState? host;

  static _UtenPageScrollbarHostState? maybeHostOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PageScrollbarScope>()?.host;

  @override
  bool updateShouldNotify(_PageScrollbarScope oldWidget) =>
      !identical(host, oldWidget.host);
}

/// Observes layouts and already-requested paints; it never requests another
/// frame merely to poll. The owner schedules only when measured geometry moved.
class _PageScrollbarGeometryObserver extends SingleChildRenderObjectWidget {
  const _PageScrollbarGeometryObserver({
    required this.onGeometry,
    required super.child,
  });
  final VoidCallback onGeometry;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PageScrollbarGeometryRender(onGeometry);

  @override
  void updateRenderObject(
    BuildContext context,
    _PageScrollbarGeometryRender renderObject,
  ) => renderObject.onGeometry = onGeometry;
}

class _PageScrollbarGeometryRender extends RenderProxyBox {
  _PageScrollbarGeometryRender(this.onGeometry);
  VoidCallback onGeometry;
  Size? _lastSize;
  bool _layoutNotificationScheduled = false;

  @override
  void performLayout() {
    super.performLayout();
    if (_lastSize != size) {
      _lastSize = size;
      // Geometry callbacks inspect the host and other viewport render boxes.
      // They cannot run during this render object's layout: Flutter permits
      // reading only its own size and direct children laid out with size use.
      // Parent offsets and retained/offstage descendants are also not final
      // until layout completes. Coalesce one attached-only post-frame read.
      if (!_layoutNotificationScheduled) {
        _layoutNotificationScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _layoutNotificationScheduled = false;
          if (attached) onGeometry();
        });
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    onGeometry();
    super.paint(context, offset);
  }
}
