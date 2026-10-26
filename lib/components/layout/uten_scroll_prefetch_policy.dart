import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The shared look-ahead contract for real vertical scroll metrics. It never
/// initiates a request on its own or changes offsets/visible page/row anchors.
abstract final class UtenScrollPrefetchPolicy {
  static const double minimumWindowPixels = 200;
  static const double maximumWindowPixels = 1200;
  static const double viewportFraction = .75;

  static double distanceOf(ScrollMetrics metrics, {double fontZoom = 1}) {
    final zoom = fontZoom.isFinite && fontZoom > 0 ? fontZoom : 1.0;
    final viewport =
        metrics.hasViewportDimension && metrics.viewportDimension.isFinite
        ? math.max(0.0, metrics.viewportDimension)
        : 0.0;
    return (viewport * viewportFraction)
        .clamp(minimumWindowPixels / zoom, maximumWindowPixels / zoom)
        .toDouble();
  }

  static bool isNearEdge(
    ScrollMetrics metrics, {
    bool prepend = false,
    double fontZoom = 1,
  }) {
    if (metrics.axis != Axis.vertical ||
        !metrics.hasContentDimensions ||
        !metrics.hasPixels ||
        !metrics.hasViewportDimension ||
        !metrics.pixels.isFinite ||
        !metrics.minScrollExtent.isFinite ||
        !metrics.maxScrollExtent.isFinite ||
        !metrics.viewportDimension.isFinite) {
      return false;
    }
    final remaining = prepend ? metrics.extentBefore : metrics.extentAfter;
    return remaining.isFinite &&
        remaining <= distanceOf(metrics, fontZoom: fontZoom);
  }

  /// All SDK scroll methods report scrollDelta, including thumb jumpTo,
  /// track animateTo, pointerScroll arrows, wheel, touch and keyboard.
  /// Layout-only ScrollMetricsNotification deliberately has no direction.
  static int directionOf(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return 0;
    final delta = switch (notification) {
      ScrollUpdateNotification(scrollDelta: final delta) => delta ?? 0.0,
      OverscrollNotification(overscroll: final delta) => delta,
      _ => 0.0,
    };
    return delta.isFinite && delta != 0 ? (delta > 0 ? 1 : -1) : 0;
  }
}
