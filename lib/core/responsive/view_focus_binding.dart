import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Finalizes retiring focus elements before directional native focus traversal.
///
/// A native focus callback can arrive synchronously while a frame detaches a
/// render subtree. Its FocusScope still belongs to the focus tree until element
/// finalization; Flutter's geometric traversal then reads a detached RenderBox.
/// Defer that exact traversal intent, not error reporting or widget disposal.
mixin UtenViewFocusEvents on WidgetsBinding {
  final Map<int, _PendingViewFocus> _pendingViewFocus = {};

  @override
  void handleViewFocusChanged(ViewFocusEvent event) {
    _pendingViewFocus.remove(event.viewId);
    final directional =
        event.state == ViewFocusState.focused &&
        event.direction != ViewFocusDirection.undefined;
    final view = renderViews
        .where((view) => view.flutterView.viewId == event.viewId)
        .firstOrNull;
    if (!directional || schedulerPhase != SchedulerPhase.persistentCallbacks) {
      super.handleViewFocusChanged(event);
      return;
    }

    final pending = _PendingViewFocus(event, view);
    _pendingViewFocus[event.viewId] = pending;
    addPostFrameCallback((_) {
      if (!identical(_pendingViewFocus[event.viewId], pending)) return;
      _pendingViewFocus.remove(event.viewId);
      // A later blur/focus replaces this intent. A retired view cannot dispatch
      // to its replacement, even if the platform reuses the same view id.
      final view = pending.view;
      if (view == null || !view.attached || !renderViews.contains(view)) return;
      super.handleViewFocusChanged(pending.event);
    });
  }
}

class _PendingViewFocus {
  const _PendingViewFocus(this.event, this.view);

  final ViewFocusEvent event;
  final RenderView? view;
}
