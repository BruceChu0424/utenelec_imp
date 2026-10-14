import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Reveals table fields within the portion left visible by frozen edge columns.
/// Native ensureVisible uses the entire viewport and can put a compact field
/// underneath the frozen checkbox column after a focus or details action.
class UtenTableHorizontalScrollController extends ScrollController {
  UtenTableHorizontalScrollController({
    required this.leadingInset,
    required this.trailingInset,
  });

  final double Function() leadingInset;
  final double Function() trailingInset;

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
  });

  final double Function() leadingInset;
  final double Function() trailingInset;

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
    final leading = leadingInset().clamp(0.0, viewportDimension);
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
