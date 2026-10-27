import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// Uses the same native axis policy over thumbs, tracks and arrow buttons.
  /// The input binding already normalized the delta; never rescale it here.
  void handlePointerSignal(
    BuildContext context,
    PointerSignalEvent event, {
    required bool Function() isCurrent,
  }) {
    if (!isCurrent()) return;
    if (event is PointerScrollInertiaCancelEvent) {
      pointerScroll(0);
      return;
    }
    if (event is! PointerScrollEvent || !acceptsUserOffset) return;
    final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    final flipped =
        event.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.logicalKeysPressed.any(modifiers.contains);
    var delta = flipped ? event.scrollDelta.dx : event.scrollDelta.dy;
    if (axisDirection == AxisDirection.up) delta = -delta;
    final target = (pixels + delta).clamp(minScrollExtent, maxScrollExtent);
    if (delta == 0 || target == pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (!isCurrent()) return;
      pointerScroll(delta);
      (resolved as PointerScrollEvent).respond(allowPlatformDefault: false);
    });
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
