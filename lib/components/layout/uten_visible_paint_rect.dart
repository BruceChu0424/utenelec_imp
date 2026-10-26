import 'package:flutter/rendering.dart';

/// Actual ancestor paint visibility, expressed in [target]'s local coordinates.
/// Nested scroll bodies may lay out beyond their parent's current viewport;
/// their full layout size is not a safe anchor for floating controls.
Rect? utenVisiblePaintRect(RenderBox target) {
  if (!target.attached || !target.hasSize) return null;
  var visible = Offset.zero & target.size;
  RenderObject child = target;
  for (
    RenderObject? parent = target.parent;
    parent != null;
    parent = parent.parent
  ) {
    // Visibility/ticker/route policy belongs to the host. A fade or Offstage
    // transition must not discard otherwise valid clipping geometry.
    var clip = parent.describeApproximatePaintClip(child);
    if (parent is RenderView) {
      // RenderView's transform includes device scaling. Its paint bounds and
      // this transform therefore remain in the same coordinate system.
      clip = parent.paintBounds;
    } else if (parent is RenderAbstractViewport && parent is RenderBox) {
      clip ??= Offset.zero & (parent as RenderBox).size;
    }
    if (clip != null) {
      final local = MatrixUtils.transformRect(
        parent.getTransformTo(target),
        clip,
      );
      if (!local.isFinite) return Rect.zero;
      visible = visible.intersect(local);
      if (visible.isEmpty) return Rect.zero;
    }
    child = parent;
  }
  return visible;
}
