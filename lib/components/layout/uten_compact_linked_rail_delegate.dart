import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'uten_scrollbar_rail_delegate.dart';

/// One stable browser-style rail for the existing compact outer + inner layout.
/// Only range projection and jump/step mapping live here; wheel handoff/hold
/// remains in the original gate and receives the original pointer signal.
class UtenCompactLinkedRailDelegate extends UtenScrollbarRailDelegate {
  UtenCompactLinkedRailDelegate(
    this._outer, {
    required this.inner,
    required this.viewportKey,
    required this.isEnabled,
  }) {
    _outer.addListener(_changed);
    inner.addListener(_changed);
  }

  ScrollController _outer;
  final ScrollController inner;
  @override
  final GlobalKey viewportKey;
  final bool Function() isEnabled;
  ScrollPosition? _preferredInner;
  bool _disposed = false;
  bool _mapping = false;
  bool _notifyScheduled = false;

  void updateOuter(ScrollController controller) {
    if (identical(controller, _outer)) return;
    _outer.removeListener(_changed);
    _outer = controller;
    _outer.addListener(_changed);
  }

  bool canBindSource(ScrollController source) {
    if (_disposed || !isEnabled() || source.positions.length != 1) return false;
    final position = source.position;
    return _outer.positions.contains(position) ||
        inner.positions.contains(position);
  }

  @override
  void bindSource(ScrollController source) {
    if (source.positions.length != 1) return;
    final position = source.position;
    if (inner.positions.contains(position)) _preferredInner = position;
  }

  ({ScrollPosition outer, ScrollPosition inner})? get _positions {
    if (_disposed || !isEnabled() || _outer.positions.length != 1) return null;
    final outer = _outer.position;
    final preferred = _preferredInner;
    final innerPosition =
        preferred != null && inner.positions.contains(preferred)
        ? preferred
        : inner.positions.length == 1
        ? inner.position
        : null;
    if (innerPosition == null) return null;
    for (final position in [outer, innerPosition]) {
      if (!position.hasPixels ||
          !position.hasContentDimensions ||
          !position.hasViewportDimension ||
          position.axisDirection != AxisDirection.down ||
          !position.minScrollExtent.isFinite ||
          !position.maxScrollExtent.isFinite) {
        return null;
      }
    }
    return (outer: outer, inner: innerPosition);
  }

  @override
  Object? get metricsIdentity {
    final positions = _positions;
    return positions == null ? null : (positions.outer, positions.inner);
  }

  @override
  ScrollMetrics? get metrics {
    final positions = _positions;
    if (positions == null) return null;
    return FixedScrollMetrics(
      minScrollExtent:
          positions.outer.minScrollExtent + positions.inner.minScrollExtent,
      maxScrollExtent:
          positions.outer.maxScrollExtent + positions.inner.maxScrollExtent,
      pixels: positions.outer.pixels + positions.inner.pixels,
      viewportDimension: positions.outer.viewportDimension,
      axisDirection: AxisDirection.down,
      devicePixelRatio: positions.outer.devicePixelRatio,
    );
  }

  @override
  bool get acceptsUserOffset {
    final positions = _positions;
    return positions != null &&
        (positions.outer.physics.shouldAcceptUserOffset(positions.outer) ||
            positions.inner.physics.shouldAcceptUserOffset(positions.inner));
  }

  @override
  void jumpTo(double pixels) {
    final positions = _positions;
    final current = metrics;
    if (positions == null || current == null) return;
    final target = pixels.clamp(
      current.minScrollExtent,
      current.maxScrollExtent,
    );
    final offset = target - current.minScrollExtent;
    final outerRange =
        positions.outer.maxScrollExtent - positions.outer.minScrollExtent;
    final outerTarget =
        positions.outer.minScrollExtent + offset.clamp(0, outerRange);
    final innerTarget =
        positions.inner.minScrollExtent +
        (offset - outerRange).clamp(
          0,
          positions.inner.maxScrollExtent - positions.inner.minScrollExtent,
        );
    _mapping = true;
    try {
      if (target >= current.pixels) {
        positions.outer.jumpTo(outerTarget);
        positions.inner.jumpTo(innerTarget);
      } else {
        positions.inner.jumpTo(innerTarget);
        positions.outer.jumpTo(outerTarget);
      }
    } finally {
      _mapping = false;
    }
    _changed();
  }

  @override
  void scrollBy(double delta) {
    final current = metrics;
    if (current != null) jumpTo(current.pixels + delta);
  }

  /// Dimension notifications may not invoke ScrollController listeners.
  void metricsChanged() => _changed();

  void _changed() {
    if (_disposed || _mapping) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notifyScheduled = false;
        if (!_disposed) notifyListeners();
      });
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _outer.removeListener(_changed);
    inner.removeListener(_changed);
    super.dispose();
  }
}
