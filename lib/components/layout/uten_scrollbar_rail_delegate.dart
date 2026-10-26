import 'package:flutter/material.dart';

/// Optional presentation adapter for one logical rail backed by real viewports.
/// It owns no ScrollPosition and must never replace business controllers.
abstract class UtenScrollbarRailDelegate extends ChangeNotifier {
  ScrollMetrics? get metrics;
  GlobalKey? get viewportKey;
  bool get acceptsUserOffset;
  Object? get metricsIdentity => this;
  void bindSource(ScrollController source) {}
  void jumpTo(double pixels);
  void scrollBy(double delta);
}

/// Shared read/action facade for custom thumbs and arrows. The ordinary
/// controller path keeps its original physics, animation and pointerScroll.
class UtenScrollbarRailTarget {
  UtenScrollbarRailTarget._(this.metrics, this.position, this.delegate);

  final ScrollMetrics metrics;
  final ScrollPosition? position;
  final UtenScrollbarRailDelegate? delegate;

  static UtenScrollbarRailTarget? resolve({
    required ScrollController controller,
    UtenScrollbarRailDelegate? delegate,
    bool visible = true,
  }) {
    if (!visible) return null;
    final position = delegate == null && controller.positions.length == 1
        ? controller.position
        : null;
    final metrics = delegate?.metrics ?? (delegate == null ? position : null);
    if (metrics == null ||
        !metrics.hasContentDimensions ||
        !metrics.hasViewportDimension ||
        !metrics.hasPixels ||
        metrics.axis != Axis.vertical ||
        !metrics.maxScrollExtent.isFinite ||
        !metrics.minScrollExtent.isFinite ||
        metrics.maxScrollExtent <= metrics.minScrollExtent) {
      return null;
    }
    return UtenScrollbarRailTarget._(metrics, position, delegate);
  }

  Object get identity => delegate ?? position!;
  double get pixels => metrics.pixels;
  double get minScrollExtent => metrics.minScrollExtent;
  double get maxScrollExtent => metrics.maxScrollExtent;
  double get viewportDimension => metrics.viewportDimension;
  AxisDirection get axisDirection => metrics.axisDirection;
  bool get acceptsUserOffset =>
      delegate?.acceptsUserOffset ??
      position!.physics.shouldAcceptUserOffset(position!);

  void jumpTo(double pixels) {
    if (delegate case final delegate?) {
      delegate.jumpTo(pixels);
    } else {
      position!.jumpTo(pixels);
    }
  }

  void pointerScroll(double delta) {
    if (delegate case final delegate?) {
      delegate.scrollBy(delta);
    } else {
      position!.pointerScroll(delta);
    }
  }

  Future<void> animateTo(
    double pixels, {
    required Duration duration,
    required Curve curve,
  }) {
    if (delegate case final delegate?) {
      delegate.jumpTo(pixels);
      return Future<void>.value();
    }
    return position!.animateTo(pixels, duration: duration, curve: curve);
  }
}
