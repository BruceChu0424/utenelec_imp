import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/responsive/display_zoom.dart';
import 'uten_scroll_prefetch_policy.dart';

/// Adds direction-aware look-ahead loading to an accumulated list's viewport
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
  ScrollableState? _source;
  bool _pending = false;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant UtenLoadMoreBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _generation++;
      _pending = false;
      _metrics = null;
      final generation = _generation;
      // A same-sized replacement query need not emit another dimensions
      // notification. Refresh from the real, retained viewport after its new
      // scope has laid out; never request from the old scope's cached metrics.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final source = _source;
        if (!mounted ||
            generation != _generation ||
            source == null ||
            !source.mounted) {
          return;
        }
        var owned = false;
        source.context.visitAncestorElements((element) {
          if (identical(element, context)) {
            owned = true;
            return false;
          }
          return true;
        });
        if (owned &&
            source.position.hasContentDimensions &&
            source.position.hasViewportDimension) {
          _metrics = source.position.copyWith();
        }
      });
    }
  }

  void _request(ScrollMetrics? metrics) {
    if (!widget.enabled ||
        _pending ||
        metrics == null ||
        metrics.axis != Axis.vertical ||
        !UtenScrollPrefetchPolicy.isNearEdge(
          metrics,
          fontZoom: UtenDisplayScale.fontZoomOf(context),
        ) ||
        !TickerMode.valuesOf(context).enabled ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    _pending = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _generation) return;
      try {
        if (widget.enabled &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          await widget.onLoadMore();
        }
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
          _source = Scrollable.maybeOf(notification.context);
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
          if (notification.context case final sourceContext?) {
            _source = Scrollable.maybeOf(sourceContext);
          }
          if (UtenScrollPrefetchPolicy.directionOf(notification) > 0) {
            _request(notification.metrics);
          }
          return false;
        },
        child: widget.child,
      ),
    ),
  );
}
