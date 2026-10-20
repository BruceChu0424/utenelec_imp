import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// A local selection region whose registrations follow render attachment.
///
/// Flutter's SelectionContainer unregisters on State.dispose, which is later
/// than render detach for retained/reparented content. Its deferred screen-order
/// sort must never receive a container whose RenderObject no longer has an owner.
class UtenSelectionArea extends StatelessWidget {
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
  Widget build(BuildContext context) => SelectionArea(
    key: selectionKey,
    focusNode: focusNode,
    onSelectionChanged: onSelectionChanged,
    contextMenuBuilder: contextMenuBuilder,
    child: UtenSelectionLifecycleScope(child: child),
  );
}

/// Keeps child registrations locally while detached, then restores them once
/// layout has completed. Removing a child still removes it immediately; this
/// does not retain removed text, swallow geometry errors or disable copying.
class UtenSelectionLifecycleScope extends StatefulWidget {
  const UtenSelectionLifecycleScope({super.key, required this.child});
  final Widget child;

  @override
  State<UtenSelectionLifecycleScope> createState() => _LifecycleState();
}

class _LifecycleState extends State<UtenSelectionLifecycleScope>
    implements SelectionRegistrar {
  final _members = LinkedHashSet<Selectable>.identity();
  final _registered = LinkedHashSet<Selectable>.identity();
  SelectionRegistrar? _parent;
  bool _attached = false;
  bool _active = true;
  bool _flushScheduled = false;

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
