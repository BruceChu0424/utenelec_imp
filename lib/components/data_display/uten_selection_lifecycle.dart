import 'dart:async';
import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

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
      child: UtenSelectionLifecycleScope(child: widget.child),
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
/// layout has completed. Removing a child still removes it immediately; this
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
  final _selectionListeners = HashMap<Selectable, VoidCallback>.identity();
  final _selectedMembers = HashSet<Selectable>.identity();
  bool _hasSelection = false;
  SelectionRegistrar? _parent;
  bool _attached = false;
  bool _active = true;
  bool _flushScheduled = false;

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
    if (identical(parent, _parent)) return;
    _unregister();
    _parent = parent;
    _scheduleFlush();
  }

  @override
  void add(Selectable selectable) {
    assert(!_members.contains(selectable), 'Duplicate selection registration');
    _members.add(selectable);
    _watchSelection(selectable);
    if (_attached && _active && _parent != null) {
      // The SDK already batches ordinary additions until post-frame layout.
      // An extra deferred layer would leave empty native scroll containers
      // registered when table selection is cleared at the end of that frame.
      _registered.add(selectable);
      _parent!.add(selectable);
    } else {
      _scheduleFlush();
    }
  }

  @override
  void remove(Selectable selectable) {
    _members.remove(selectable);
    final listener = _selectionListeners.remove(selectable);
    if (listener != null) selectable.removeListener(listener);
    _selectedMembers.remove(selectable);
    _notifySelection();
    if (_registered.remove(selectable)) _parent!.remove(selectable);
  }

  void _unregister() {
    final previous = _registered.toList(growable: false);
    _registered.clear();
    for (final selectable in previous) {
      // Retained paragraphs also retain their handle LeaderLayers. Release the
      // old parent's links before detach so reattachment cannot paint two
      // leaders for one selection edge. The text selection itself is retained.
      selectable.pushHandleLayers(null, null);
      _parent!.remove(selectable);
    }
  }

  void _scheduleFlush() {
    if (!_attached || !_active || _parent == null || _flushScheduled) return;
    _flushScheduled = true;
    void flush([Duration? _]) {
      _flushScheduled = false;
      if (!mounted || !_attached || !_active || _parent == null) return;
      // One pass per frame, including additions from nested selection delegates.
      // Native delegates subsequently merge/sort only the attached additions.
      for (final selectable in _members.toList(growable: false)) {
        if (_registered.add(selectable)) _parent!.add(selectable);
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

  void _willDetach() {
    // Called before RenderProxyBox.detach, while all geometry is still valid.
    _attached = false;
    _unregister();
  }

  @override
  void deactivate() {
    _active = false;
    _unregister();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _scheduleFlush();
  }

  @override
  void dispose() {
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
    child: _parent == null
        ? widget.child
        : SelectionRegistrarScope(registrar: this, child: widget.child),
  );
}

class _AttachmentObserver extends SingleChildRenderObjectWidget {
  const _AttachmentObserver({
    required this.onAttach,
    required this.onDetach,
    required super.child,
  });
  final VoidCallback onAttach;
  final VoidCallback onDetach;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _AttachmentRenderBox(onAttach, onDetach);
}

class _AttachmentRenderBox extends RenderProxyBox {
  _AttachmentRenderBox(this.onAttach, this.onDetach);
  final VoidCallback onAttach;
  final VoidCallback onDetach;

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
