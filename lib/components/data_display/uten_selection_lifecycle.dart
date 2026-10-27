import 'dart:async';
import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// A local selection region whose registrations follow render attachment.
///
/// Flutter's SelectionContainer unregisters on State.dispose, which is later
/// than render detach for retained/reparented content. Its deferred screen-order
/// sort must never receive a container whose RenderObject no longer has an owner.
/// Nested regions also restore the mouse-selection winner's own keyboard focus.
class UtenSelectionArea extends StatefulWidget {
  const UtenSelectionArea({
    super.key,
    this.selectionKey,
    this.focusNode,
    this.onSelectionChanged,
    this.contextMenuBuilder = _defaultContextMenuBuilder,
    required this.child,
  });

  final GlobalKey<SelectionAreaState>? selectionKey;
  final FocusNode? focusNode;
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final SelectableRegionContextMenuBuilder? contextMenuBuilder;
  final Widget child;

  static Widget _defaultContextMenuBuilder(
    BuildContext context,
    SelectableRegionState region,
  ) => AdaptiveTextSelectionToolbar.selectableRegion(
    selectableRegionState: region,
  );

  @override
  State<UtenSelectionArea> createState() => _SelectionAreaState();
}

class _SelectionAreaState extends State<UtenSelectionArea> {
  FocusNode? _ownedFocus;
  FocusNode get _focus =>
      widget.focusNode ??
      (_ownedFocus ??= FocusNode(debugLabel: 'Uten text selection'));
  int _gestureEpoch = 0;
  int? _mousePointer;
  bool _finishingGesture = false;
  bool _producedSelection = false;
  bool _hasSelectedText = false;
  bool _nativeInputHit = false;

  void _pointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryButton) {
      return;
    }
    _gestureEpoch++;
    _mousePointer = event.pointer;
    _finishingGesture = false;
    _producedSelection = false;
    _nativeInputHit = _hitsNativeInput(event);
  }

  void _selectionChanged(SelectedContent? content) {
    _hasSelectedText = content?.plainText.isNotEmpty ?? false;
    if ((_mousePointer != null || _finishingGesture) && _hasSelectedText) {
      _producedSelection = true;
    }
    widget.onSelectionChanged?.call(content);
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _mousePointer) return;
    final epoch = _gestureEpoch;
    _mousePointer = null;
    _finishingGesture = true;
    // Ancestor and descendant regions both receive tap-down after the press
    // deadline. The loser may take focus, then cancel while the inner region
    // wins the drag. Wait for arena cancellation/final selection before giving
    // the actual nonempty winner its own keyboard focus again.
    scheduleMicrotask(() {
      if (!mounted || epoch != _gestureEpoch) return;
      _finishingGesture = false;
      // An explicit focus request made by another pointer-up listener must be
      // applied first. Restore only after that same event's focus queue drains.
      scheduleMicrotask(() => _restoreSelectionFocus(epoch));
    });
  }

  void _restoreSelectionFocus(int epoch) {
    if (!mounted || epoch != _gestureEpoch) return;
    if (!_producedSelection || !_hasSelectedText || _nativeInputHit) return;
    final current = FocusManager.instance.primaryFocus;
    if (current != null && !identical(current, _focus)) {
      var isAncestorFocus = false;
      context.visitAncestorElements((element) {
        if (identical(element, current.context)) {
          isAncestorFocus = true;
          return false;
        }
        return true;
      });
      // A new native input, menu or another table owns its new focus. Only
      // the selection ancestor that lost this same gesture may be replaced.
      if (!isAncestorFocus) return;
    }
    if (_focus.canRequestFocus && !_focus.hasPrimaryFocus) {
      _focus.requestFocus();
    }
  }

  void _cancelGesture() {
    _gestureEpoch++;
    _mousePointer = null;
    _finishingGesture = false;
    _producedSelection = false;
  }

  @override
  void didUpdateWidget(UtenSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode) ||
        !identical(oldWidget.selectionKey, widget.selectionKey)) {
      _cancelGesture();
    }
  }

  @override
  void deactivate() {
    _cancelGesture();
    super.deactivate();
  }

  @override
  void dispose() {
    _cancelGesture();
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _pointerDown,
    onPointerUp: _pointerUp,
    onPointerCancel: (event) {
      if (event.pointer == _mousePointer) _cancelGesture();
    },
    child: SelectionArea(
      key: widget.selectionKey,
      focusNode: _focus,
      onSelectionChanged: _selectionChanged,
      contextMenuBuilder: widget.contextMenuBuilder,
      child: ScrollConfiguration(
        behavior: _SelectionScrollBehavior.wrap(
          ScrollConfiguration.of(context),
        ),
        child: UtenSelectionLifecycleScope(child: widget.child),
      ),
    ),
  );
}

final _nativeInputHits = Expando<bool>();

bool _hitsNativeInput(PointerDownEvent event) {
  final original = event.original ?? event;
  final cached = _nativeInputHits[original];
  if (cached != null) return cached;
  final hit = HitTestResult();
  RendererBinding.instance.hitTestInView(hit, event.position, event.viewId);
  final value = hit.path.any((entry) => entry.target is RenderEditable);
  _nativeInputHits[original] = value;
  return value;
}

/// Keeps child registrations locally while detached, then restores them once
/// layout has completed. Removed text becomes unavailable immediately; an SDK
/// registration is retired after an in-flight selection event returns. This
/// does not retain removed text, swallow geometry errors or disable copying.
class UtenSelectionLifecycleScope extends StatefulWidget {
  const UtenSelectionLifecycleScope({
    super.key,
    this.onHasSelectionChanged,
    required this.child,
  });
  final Widget child;

  /// Optional bridge for content-height windows that do not use the SDK's
  /// private sliver selection keep-alive. Business checkbox selection is separate.
  final ValueChanged<bool>? onHasSelectionChanged;

  @override
  State<UtenSelectionLifecycleScope> createState() => _LifecycleState();
}

class _LifecycleState extends State<UtenSelectionLifecycleScope>
    implements SelectionRegistrar {
  final _members = LinkedHashSet<Selectable>.identity();
  final _registered = LinkedHashSet<Selectable>.identity();
  final _forwarded = HashMap<Selectable, _SelectionForwarder>.identity();
  final _selectionListeners = HashMap<Selectable, VoidCallback>.identity();
  final _selectedMembers = HashSet<Selectable>.identity();
  final _paintOwners = HashMap<Selectable, RenderObject>.identity();
  bool _hasSelection = false;
  SelectionRegistrar? _parent;
  bool _attached = false;
  bool _active = true;
  bool _visible = true;
  bool _flushScheduled = false;
  bool _awaitingLayout = false;

  bool get _registrationReady {
    if (!_attached || !_active || !_visible || _parent == null) return false;
    final render = context.findRenderObject();
    if (render is! _AttachmentRenderBox || !render.hasSize) return false;
    if (render.hasKeptAliveAncestor) {
      // A sliver may rebuild retained rows without laying them out. Their new
      // paragraphs must wait for an actual row layout before the parent can
      // sort their geometry. Existing selected members stay registered.
      _awaitingLayout = true;
      return false;
    }
    return !_awaitingLayout;
  }

  void _notifySelection() {
    final next = _selectedMembers.isNotEmpty;
    if (next == _hasSelection) return;
    _hasSelection = next;
    widget.onHasSelectionChanged?.call(next);
  }

  void _watchSelection(Selectable selectable) {
    if (widget.onHasSelectionChanged == null) return;
    void changed() {
      if (selectable.value.hasSelection) {
        _selectedMembers.add(selectable);
      } else {
        _selectedMembers.remove(selectable);
      }
      _notifySelection();
    }

    _selectionListeners[selectable] = changed;
    selectable.addListener(changed);
    changed();
  }

  @override
  void didUpdateWidget(UtenSelectionLifecycleScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onHasSelectionChanged == widget.onHasSelectionChanged) return;
    if (_hasSelection) oldWidget.onHasSelectionChanged?.call(false);
    if (widget.onHasSelectionChanged == null) {
      for (final entry in _selectionListeners.entries) {
        entry.key.removeListener(entry.value);
      }
      _selectionListeners.clear();
      _selectedMembers.clear();
      _hasSelection = false;
    } else if (oldWidget.onHasSelectionChanged == null) {
      for (final member in _members) {
        _watchSelection(member);
      }
    } else if (_hasSelection) {
      widget.onHasSelectionChanged!(true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = SelectionContainer.maybeOf(context);
    final visible = TickerMode.valuesOf(context).enabled;
    if (!identical(parent, _parent) || visible != _visible) _unregister();
    _parent = parent;
    _visible = visible;
    _SelectionFrameFence.update(
      this,
      _active && _visible && parent != null && parent is! _LifecycleState,
    );
    _scheduleFlush();
  }

  @override
  void add(Selectable selectable) {
    assert(!_members.contains(selectable), 'Duplicate selection registration');
    _members.add(selectable);
    _watchSelection(selectable);
    // Queue our attachment sweep before the SDK queues a screen-order merge.
    _scheduleFlush();
    if (_registrationReady && _selectableReady(selectable)) {
      // The SDK already batches ordinary additions until post-frame layout.
      // An extra deferred layer would leave empty native scroll containers
      // registered when table selection is cleared at the end of that frame.
      _registered.add(selectable);
      _rememberPaintOwner(selectable);
      _addToParent(selectable);
    } else {
      _scheduleFlush();
    }
  }

  bool _selectableReady(Selectable selectable) {
    selectable = _selectionSource(selectable);
    final RenderObject? render;
    if (selectable is State) {
      final state = selectable as State;
      if (!state.mounted) return false;
      // Element.renderObject is valid for an inactive retained element too;
      // BuildContext.findRenderObject requires an active element.
      final memberContext = state.context;
      render = memberContext is Element ? memberContext.renderObject : null;
    } else if (selectable is RenderObject) {
      render = selectable as RenderObject;
    } else {
      // Raw fragment registrations remain bounded by their explicit observer.
      return true;
    }
    if (render == null || !render.attached) return false;
    return render is! RenderBox || render.hasSize;
  }

  void _rememberPaintOwner(Selectable selectable) {
    final source = _selectionSource(selectable);
    RenderObject? render;
    if (source is State) {
      final state = source as State;
      if (!state.mounted) return;
      final memberContext = state.context;
      if (memberContext is Element) render = memberContext.renderObject;
    } else if (source is RenderObject) {
      render = source as RenderObject;
    }
    while (render != null && !render.isRepaintBoundary) {
      render = render.parent;
    }
    if (render != null) _paintOwners[selectable] = render;
  }

  void _retireDetachedMembers() {
    for (final selectable in _registered.toList(growable: false)) {
      if (_selectableReady(selectable)) continue;
      _registered.remove(selectable);
      _removeFromParent(selectable);
      final source = _selectionSource(selectable);
      if (source is State && (source as State).mounted) {
        // RenderParagraph ignores handle updates after detach. Retire the
        // detached leaf's own text geometry, while its State is still alive,
        // so reattachment cannot paint the former parent's stale links.
        selectable.dispatchSelectionEvent(const ClearSelectionEvent());
      }
      selectable.pushHandleLayers(null, null);
      final paintOwner = _paintOwners.remove(selectable);
      if (paintOwner?.attached == true) {
        // A retained sliver boundary can still cache the detached paragraph's
        // old handle LeaderLayer. Repaint its former owner before reattachment
        // creates a new leader for the same edge link.
        paintOwner!.markNeedsPaint();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WidgetsBinding.instance.ensureVisualUpdate();
        });
      }
    }
  }

  void _afterFrameLayout() {
    if (!mounted || !_attached || !_active || !_visible || _parent == null) {
      return;
    }
    _retireDetachedMembers();
    if (_members.length != _registered.length && _registrationReady) {
      _scheduleFlush();
    }
  }

  @override
  void remove(Selectable selectable) {
    _paintOwners.remove(selectable);
    _members.remove(selectable);
    final listener = _selectionListeners.remove(selectable);
    if (listener != null) selectable.removeListener(listener);
    _selectedMembers.remove(selectable);
    _notifySelection();
    if (_registered.remove(selectable)) _removeFromParent(selectable);
  }

  void _addToParent(Selectable selectable) {
    final forwarded = _SelectionForwarder(selectable, _parent!);
    _forwarded[selectable] = forwarded;
    _parent!.add(forwarded);
  }

  void _removeFromParent(Selectable selectable) {
    final forwarded = _forwarded.remove(selectable)!;
    forwarded.retire();
    _SelectionDispatchFence.remove(forwarded);
  }

  void _unregister() {
    final previous = _registered.toList(growable: false);
    _registered.clear();
    _paintOwners.clear();
    for (final selectable in previous) {
      // Retained paragraphs also retain their handle LeaderLayers. Release the
      // old parent's links before detach so reattachment cannot paint two
      // leaders for one selection edge. The text selection itself is retained.
      selectable.pushHandleLayers(null, null);
      _removeFromParent(selectable);
    }
  }

  void _scheduleFlush() {
    if (!_attached ||
        !_active ||
        !_visible ||
        _parent == null ||
        _flushScheduled) {
      return;
    }
    _flushScheduled = true;
    void flush([Duration? _]) {
      _flushScheduled = false;
      if (!mounted || !_attached || !_active || !_visible || _parent == null) {
        return;
      }
      _retireDetachedMembers();
      if (!_registrationReady) return;
      // One pass per frame, including additions from nested selection delegates.
      // Native delegates subsequently merge/sort only the attached additions.
      for (final selectable in _members.toList(growable: false)) {
        if (!_selectableReady(selectable)) continue;
        if (_registered.add(selectable)) {
          _rememberPaintOwner(selectable);
          _addToParent(selectable);
        }
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.postFrameCallbacks) {
      scheduleMicrotask(flush);
    } else {
      WidgetsBinding.instance.addPostFrameCallback(flush);
      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
        WidgetsBinding.instance.scheduleFrame();
      }
    }
  }

  void _didAttach() {
    _attached = true;
    _scheduleFlush();
  }

  void _didGeometryReady() {
    _awaitingLayout = false;
    if (_members.length != _registered.length) _scheduleFlush();
  }

  void _willDetach() {
    // Called before RenderProxyBox.detach, while all geometry is still valid.
    _attached = false;
    _unregister();
  }

  @override
  void deactivate() {
    _active = false;
    _SelectionFrameFence.update(this, false);
    _unregister();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _SelectionFrameFence.update(
      this,
      _visible && _parent != null && _parent is! _LifecycleState,
    );
    _scheduleFlush();
  }

  @override
  void dispose() {
    _SelectionFrameFence.update(this, false);
    _unregister();
    for (final entry in _selectionListeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _selectionListeners.clear();
    _selectedMembers.clear();
    if (_hasSelection) widget.onHasSelectionChanged?.call(false);
    _members.clear();
    _parent = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AttachmentObserver(
    onAttach: _didAttach,
    onDetach: _willDetach,
    onGeometryReady: _didGeometryReady,
    child: _parent == null
        ? widget.child
        : SelectionRegistrarScope(registrar: this, child: widget.child),
  );
}

Selectable _selectionSource(Selectable selectable) {
  while (selectable is _SelectionForwarder) {
    selectable = selectable.source;
  }
  return selectable;
}

/// SelectionRegistrant may remove an empty native container while its parent
/// is iterating a clear/extend event. Keep that public protocol reentrant-safe,
/// while ordinary render detach still unregisters synchronously before sorting.
abstract final class _SelectionDispatchFence {
  static int _depth = 0;
  static bool _scheduled = false;
  static final _pending = <_SelectionForwarder>[];

  static SelectionResult dispatch(Selectable source, SelectionEvent event) {
    _depth++;
    try {
      return source.dispatchSelectionEvent(event);
    } finally {
      _depth--;
      if (_depth == 0 && _pending.isNotEmpty && !_scheduled) {
        _scheduled = true;
        scheduleMicrotask(() {
          _scheduled = false;
          final removals = List<_SelectionForwarder>.of(_pending);
          _pending.clear();
          for (final forwarded in removals) {
            forwarded.parent.remove(forwarded);
          }
        });
      }
    }
  }

  static void remove(_SelectionForwarder forwarded) {
    if (_depth == 0) {
      forwarded.parent.remove(forwarded);
    } else {
      _pending.add(forwarded);
    }
  }
}

/// Transparent Selectable registration; the source retains lifecycle ownership.
class _SelectionForwarder with Selectable {
  _SelectionForwarder(this.source, this.parent);
  final Selectable source;
  final SelectionRegistrar parent;
  bool _active = true;

  void retire() {
    if (!_active) return;
    source.pushHandleLayers(null, null);
    _active = false;
  }

  @override
  SelectionGeometry get value => _active
      ? source.value
      : const SelectionGeometry(
          status: SelectionStatus.none,
          hasContent: false,
        );
  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) => _active
      ? _SelectionDispatchFence.dispatch(source, event)
      : SelectionResult.none;
  @override
  Matrix4 getTransformTo(RenderObject? ancestor) =>
      _active ? source.getTransformTo(ancestor) : Matrix4.identity();
  @override
  Size get size => _active ? source.size : Size.zero;
  @override
  List<Rect> get boundingBoxes =>
      _active ? source.boundingBoxes : const [Rect.zero];
  @override
  int get contentLength => _active ? source.contentLength : 0;
  @override
  SelectedContent? getSelectedContent() =>
      _active ? source.getSelectedContent() : null;
  @override
  SelectedContentRange? getSelection() =>
      _active ? source.getSelection() : null;
  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_active) source.pushHandleLayers(startHandle, endHandle);
  }

  @override
  void addListener(VoidCallback listener) {
    if (_active) source.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) => source.removeListener(listener);
  @override
  void dispose() => retire();
}

/// Runs after the normal rendering/layout callback and before post-frame SDK
/// selection merges. It requests no recurring frame. Only bridges to native
/// registrars participate; nested Uten row scopes feed those same bridges.
abstract final class _SelectionFrameFence {
  static final _bridges = HashSet<_LifecycleState>.identity();
  static bool _installed = false;

  static void update(_LifecycleState scope, bool enabled) {
    enabled ? _bridges.add(scope) : _bridges.remove(scope);
    if (_installed || _bridges.isEmpty) return;
    _installed = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      for (final bridge in _bridges.toList(growable: false)) {
        bridge._afterFrameLayout();
      }
    });
  }
}

/// Scrollable inserts its own SelectionContainer above its chrome. Add the
/// attachment bridge inside that container, where native Text registrations
/// actually arrive. Every platform's existing scroll and input policy remains
/// delegated, including explicit/automatic scrollbar ownership.
class _SelectionScrollBehavior extends ScrollBehavior {
  const _SelectionScrollBehavior(this.delegate);
  final ScrollBehavior delegate;

  static ScrollBehavior wrap(ScrollBehavior behavior) =>
      behavior is _SelectionScrollBehavior
      ? behavior
      : _SelectionScrollBehavior(behavior);

  @override
  ScrollBehavior copyWith({
    bool? scrollbars,
    bool? overscroll,
    Set<PointerDeviceKind>? dragDevices,
    MultitouchDragStrategy? multitouchDragStrategy,
    Set<LogicalKeyboardKey>? pointerAxisModifiers,
    ScrollPhysics? physics,
    TargetPlatform? platform,
    ScrollViewKeyboardDismissBehavior? keyboardDismissBehavior,
  }) => _SelectionScrollBehavior(
    delegate.copyWith(
      scrollbars: scrollbars,
      overscroll: overscroll,
      dragDevices: dragDevices,
      multitouchDragStrategy: multitouchDragStrategy,
      pointerAxisModifiers: pointerAxisModifiers,
      physics: physics,
      platform: platform,
      keyboardDismissBehavior: keyboardDismissBehavior,
    ),
  )._scrollableConfiguration();

  // EditableText retains its Scrollable while a field moves into/out of a
  // selection host. The SDK compares explicit behavior copies directly, with
  // a covariant private wrapper parameter. Return the same SDK copy type on
  // both sides, while keeping requested chrome flags inside our lifecycle hook.
  ScrollBehavior _scrollableConfiguration() => super.copyWith();

  @override
  Set<PointerDeviceKind> get dragDevices => delegate.dragDevices;
  @override
  Set<LogicalKeyboardKey> get pointerAxisModifiers =>
      delegate.pointerAxisModifiers;
  @override
  TargetPlatform getPlatform(BuildContext context) =>
      delegate.getPlatform(context);
  @override
  MultitouchDragStrategy getMultitouchDragStrategy(BuildContext context) =>
      delegate.getMultitouchDragStrategy(context);
  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) =>
      delegate.velocityTrackerBuilder(context);
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      delegate.getScrollPhysics(context);
  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => delegate.getKeyboardDismissBehavior(context);
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => delegate.buildScrollbar(context, child, details);
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => delegate.buildOverscrollIndicator(
    context,
    SelectionContainer.maybeOf(context) == null
        ? child
        : UtenSelectionLifecycleScope(child: child),
    details,
  );
  @override
  bool shouldNotify(ScrollBehavior oldDelegate) =>
      oldDelegate is! _SelectionScrollBehavior ||
      !identical(delegate, oldDelegate.delegate);
}

class _AttachmentObserver extends SingleChildRenderObjectWidget {
  const _AttachmentObserver({
    required this.onAttach,
    required this.onDetach,
    required this.onGeometryReady,
    required super.child,
  });
  final VoidCallback onAttach;
  final VoidCallback onDetach;
  final VoidCallback onGeometryReady;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _AttachmentRenderBox(onAttach, onDetach, onGeometryReady);
}

class _AttachmentRenderBox extends RenderProxyBox {
  _AttachmentRenderBox(this.onAttach, this.onDetach, this.onGeometryReady);
  final VoidCallback onAttach;
  final VoidCallback onDetach;
  final VoidCallback onGeometryReady;

  bool get hasKeptAliveAncestor {
    RenderObject? current = this;
    while (current != null) {
      final data = current.parentData;
      if (data is SliverMultiBoxAdaptorParentData && data.keptAlive) {
        return true;
      }
      current = current.parent;
    }
    return false;
  }

  @override
  void performLayout() {
    super.performLayout();
    onGeometryReady();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    // Tight retained rows can return with their existing layout. A completed
    // visible paint also proves their descendants have usable geometry.
    onGeometryReady();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    onAttach();
  }

  @override
  void detach() {
    onDetach();
    super.detach();
  }
}
