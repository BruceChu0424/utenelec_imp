import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds bottom-edge loading to a list that already owns its accumulated rows
/// (including editable grids). Selection and input controllers stay with it.
class UtenLoadMoreBoundary extends StatefulWidget {
  const UtenLoadMoreBoundary({
    super.key,
    required this.child,
    required this.enabled,
    required this.onLoadMore,
    this.scope,
  });
  final Widget child;
  final bool enabled;
  final Future<void> Function() onLoadMore;
  final Object? scope;

  @override
  State<UtenLoadMoreBoundary> createState() => _UtenLoadMoreBoundaryState();
}

class _UtenLoadMoreBoundaryState extends State<UtenLoadMoreBoundary> {
  ScrollMetrics? _metrics;
  bool _pending = false;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant UtenLoadMoreBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _generation++;
      _pending = false;
    }
  }

  void _request(ScrollMetrics? metrics) {
    if (!widget.enabled ||
        _pending ||
        metrics == null ||
        metrics.axis != Axis.vertical ||
        metrics.extentAfter > 0.5) {
      return;
    }
    _pending = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _generation) return;
      try {
        if (widget.enabled) await widget.onLoadMore();
      } finally {
        if (mounted && generation == _generation) _pending = false;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent ||
          event.scrollDelta.dy <= 0 ||
          event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
        return;
      }
      final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
      if (HardwareKeyboard.instance.logicalKeysPressed.any(
        modifiers.contains,
      )) {
        return;
      }
      _request(_metrics);
    },
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          _metrics = notification.metrics;
        }
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth != 0 ||
              notification.metrics.axis != Axis.vertical) {
            return false;
          }
          _metrics = notification.metrics;
          final forward =
              notification is ScrollUpdateNotification &&
                  notification.dragDetails != null &&
                  (notification.scrollDelta ?? 0) > 0 ||
              notification is OverscrollNotification &&
                  notification.overscroll > 0;
          if (forward) _request(notification.metrics);
          return false;
        },
        child: widget.child,
      ),
    ),
  );
}
