import 'package:flutter/widgets.dart';

/// Applies a measured prepend height during the scroll view's next layout.
///
/// Keep one instance for the lifetime of the owning table. The same instance
/// must reach the active scroll view, including a primary or fullscreen view.
/// Call [prepare] after measuring the actual inserted rows, immediately before
/// committing them. Cancel an abandoned insertion with [reset].
///
/// This only compensates for inserted content. The host owns row identity,
/// measurement, query changes, and any visual-anchor verification after layout.
class UtenPrependScrollAnchor {
  double? _insertedExtent;

  bool get pending => _insertedExtent != null;

  /// Replaces any unconsumed correction with the actual inserted height.
  ///
  /// Zero means that no content was inserted before the visible anchor.
  void prepare(double insertedExtent) {
    if (!insertedExtent.isFinite || insertedExtent < 0) {
      throw ArgumentError.value(
        insertedExtent,
        'insertedExtent',
        'must be finite and non-negative',
      );
    }
    _insertedExtent = insertedExtent == 0 ? null : insertedExtent;
  }

  void reset() => _insertedExtent = null;

  /// Preserves the supplied physics for every operation except one pending
  /// content-dimension correction. Flutter's applyTo chain shares this state.
  ScrollPhysics wrap(ScrollPhysics parent) =>
      _UtenPrependAnchorPhysics(anchor: this, parent: parent);

  double? _takeExtent() {
    final extent = _insertedExtent;
    _insertedExtent = null;
    return extent;
  }
}

class _UtenPrependAnchorPhysics extends ScrollPhysics {
  const _UtenPrependAnchorPhysics({required this.anchor, super.parent});

  final UtenPrependScrollAnchor anchor;

  @override
  _UtenPrependAnchorPhysics applyTo(ScrollPhysics? ancestor) =>
      _UtenPrependAnchorPhysics(anchor: anchor, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final extent = anchor._takeExtent();
    if (extent != null) {
      // A lazy list's current maxScrollExtent is an estimate. Clamping against
      // it can lose the anchor before the newly inserted rows are laid out.
      // ScrollPosition applies this correction and repeats layout in this frame.
      return newPosition.pixels + extent;
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}
