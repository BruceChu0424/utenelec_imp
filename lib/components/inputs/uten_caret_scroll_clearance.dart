import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/responsive/compact_presentation.dart';
import '../../core/ui/capsule_nav_metrics.dart';

/// Enlarges only an input's reveal request. Layout remains full-height beneath
/// the floating navigation; focusing a cell reveals it above navigation/actions.
class UtenCaretScrollClearance extends StatelessWidget {
  const UtenCaretScrollClearance({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (context.dependOnInheritedWidgetOfExactType<_CaretClearanceOwner>() !=
        null) {
      return child;
    }
    final media = MediaQuery.of(context);
    final nav = UtenCapsuleNavScope.occlusionOf(context);
    final bottom =
        UtenCompactPresentation.of(context) &&
            ModalRoute.of(context) is! PopupRoute
        ? nav +
              math.min(
                UtenFloatingOverlayMetrics.actionScrollClearance,
                math.max(0.0, media.size.height - media.viewInsets.bottom) * .3,
              )
        : 0.0;
    return _CaretClearanceOwner(
      child: _RevealPadding(bottom: bottom, child: child),
    );
  }
}

class _CaretClearanceOwner extends InheritedWidget {
  const _CaretClearanceOwner({required super.child});
  @override
  bool updateShouldNotify(_CaretClearanceOwner oldWidget) => false;
}

class _RevealPadding extends SingleChildRenderObjectWidget {
  const _RevealPadding({required this.bottom, required super.child});
  final double bottom;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RevealPaddingBox(bottom);
  @override
  void updateRenderObject(
    BuildContext context,
    _RevealPaddingBox renderObject,
  ) => renderObject.bottom = bottom;
}

class _RevealPaddingBox extends RenderProxyBox {
  _RevealPaddingBox(this.bottom);
  double bottom;
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (bottom <= 0) {
      super.showOnScreen(
        descendant: descendant,
        rect: rect,
        duration: duration,
        curve: curve,
      );
      return;
    }
    final target = descendant ?? this;
    var bounds = rect ?? target.paintBounds;
    if (!identical(target, this)) {
      bounds = MatrixUtils.transformRect(target.getTransformTo(this), bounds);
    }
    super.showOnScreen(
      descendant: this,
      rect: Rect.fromLTRB(
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom + bottom,
      ),
      duration: duration,
      curve: curve,
    );
  }
}
