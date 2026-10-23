import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

const double utenTableMinimumScrollableWidth = 120;

/// Preserve a usable scrollable middle without changing the saved pin settings.
/// The fallback is the real selection column, or zero for a read-only table.
double utenEffectiveFrozenLeadingWidth({
  required double requestedWidth,
  required double viewportWidth,
  double fallbackWidth = 0,
  double trailingWidth = 0,
}) {
  final viewport = math.max(0.0, viewportWidth);
  final requested = math.max(0.0, requestedWidth);
  final fallback = fallbackWidth
      .clamp(0.0, math.min(requested, viewport))
      .toDouble();
  final trailing = trailingWidth.clamp(0.0, viewport - fallback);
  final available = viewport - trailing;
  final middle = math.min(
    utenTableMinimumScrollableWidth,
    available - fallback,
  );
  return requested <= available - middle ? requested : fallback;
}

/// Geometry changes are separate from pixel changes: a resize is not a scroll.
Listenable utenTableHorizontalChanges(ScrollController horizontal) =>
    horizontal is UtenTableHorizontalScrollController
    ? horizontal.visualChanges
    : horizontal;

/// Reveals table fields within the portion left visible by frozen edge columns.
/// Native ensureVisible uses the entire viewport and can put a compact field
/// underneath the frozen checkbox column after a focus or details action.
class UtenTableHorizontalScrollController extends ScrollController {
  UtenTableHorizontalScrollController({
    required this.leadingInset,
    required this.trailingInset,
    this.fallbackLeadingInset,
  });

  final double Function() leadingInset;
  final double Function() trailingInset;
  final double Function()? fallbackLeadingInset;
  final _geometryChanges = ValueNotifier<int>(0);
  late final Listenable visualChanges = Listenable.merge([
    this,
    _geometryChanges,
  ]);
  bool _geometryPending = false;
  bool _disposed = false;

  void _scheduleGeometryChange() {
    if (_geometryPending || _disposed) return;
    _geometryPending = true;
    scheduleMicrotask(() {
      _geometryPending = false;
      if (!_disposed) _geometryChanges.value++;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _geometryChanges.dispose();
    super.dispose();
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TableHorizontalPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    leadingInset: leadingInset,
    trailingInset: trailingInset,
    fallbackLeadingInset: fallbackLeadingInset,
    onGeometryChanged: _scheduleGeometryChange,
  );
}

class _TableHorizontalPosition extends ScrollPositionWithSingleContext {
  _TableHorizontalPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    super.oldPosition,
    required this.leadingInset,
    required this.trailingInset,
    required this.fallbackLeadingInset,
    required this.onGeometryChanged,
  });

  final double Function() leadingInset;
  final double Function() trailingInset;
  final double Function()? fallbackLeadingInset;
  final VoidCallback onGeometryChanged;

  @override
  bool applyViewportDimension(double viewportDimension) {
    final changed =
        !hasViewportDimension || this.viewportDimension != viewportDimension;
    final accepted = super.applyViewportDimension(viewportDimension);
    if (changed) onGeometryChanged();
    return accepted;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final changed =
        !hasContentDimensions ||
        this.minScrollExtent != minScrollExtent ||
        this.maxScrollExtent != maxScrollExtent;
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (changed) onGeometryChanged();
    return accepted;
  }

  @override
  Future<void> ensureVisible(
    RenderObject object, {
    double alignment = 0,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
    ScrollPositionAlignmentPolicy alignmentPolicy =
        ScrollPositionAlignmentPolicy.explicit,
    RenderObject? targetRenderObject,
  }) async {
    final viewport = RenderAbstractViewport.maybeOf(object);
    if (viewport == null) return;
    Rect? targetRect;
    if (targetRenderObject != null && targetRenderObject != object) {
      targetRect = MatrixUtils.transformRect(
        targetRenderObject.getTransformTo(object),
        object.paintBounds.intersect(targetRenderObject.paintBounds),
      );
    }
    final leading = utenEffectiveFrozenLeadingWidth(
      requestedWidth: leadingInset(),
      viewportWidth: viewportDimension,
      fallbackWidth: fallbackLeadingInset?.call() ?? 0,
      trailingWidth: trailingInset(),
    );
    final trailing = trailingInset().clamp(0.0, viewportDimension - leading);
    double reveal(double at) => viewport
        .getOffsetToReveal(object, at, rect: targetRect, axis: axis)
        .offset;
    final start = reveal(0) - leading;
    final end = reveal(1) + trailing;
    var policy = alignmentPolicy;
    if (axisDirection == AxisDirection.left) {
      policy = switch (policy) {
        ScrollPositionAlignmentPolicy.keepVisibleAtStart =>
          ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd =>
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ScrollPositionAlignmentPolicy.explicit => policy,
      };
    }
    double target;
    switch (policy) {
      case ScrollPositionAlignmentPolicy.explicit:
        final requested = reveal(alignment);
        // Fields wider than the visible middle keep the requested alignment.
        target = end <= start ? requested.clamp(end, start) : requested;
      case ScrollPositionAlignmentPolicy.keepVisibleAtStart:
        target = start.clamp(minScrollExtent, maxScrollExtent);
        if (target > pixels) target = pixels;
      case ScrollPositionAlignmentPolicy.keepVisibleAtEnd:
        target = end.clamp(minScrollExtent, maxScrollExtent);
        if (target < pixels) target = pixels;
    }
    target = target.clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    if (duration == Duration.zero) {
      jumpTo(target);
      return;
    }
    await animateTo(target, duration: duration, curve: curve);
  }
}
