import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'uten_page_layout.dart';

/// Reserves only the trailing scrollbar lane. Page margins belong to the page
/// container and must not be repeated inside every tree, list or cell viewport.
class UtenScrollGutter extends StatelessWidget {
  const UtenScrollGutter({super.key, required this.child, this.enabled = true});

  const UtenScrollGutter.trailing({
    super.key,
    required this.child,
    this.enabled = true,
  });

  static const double trackWidth = 16;

  static double insetForWidth(double width) =>
      width.isFinite ? math.min(trackWidth, math.max(0, width)) : trackWidth;

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => _GutterPadding(
    enabled:
        enabled &&
        !(UtenPageScrollLaneScope.pageOwnedOf(context) &&
            UtenPageScrollRoleScope.isPageOf(context)),
    child: child,
  );
}

/// A render decorator supports table cells under IntrinsicHeight. LayoutBuilder
/// cannot answer their intrinsic measurements and would break long-value cells.
class _GutterPadding extends SingleChildRenderObjectWidget {
  const _GutterPadding({required this.enabled, required super.child});

  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGutterPadding(enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGutterPadding renderObject,
  ) => renderObject.update(enabled);
}

class _RenderGutterPadding extends RenderShiftedBox {
  _RenderGutterPadding(this._enabled) : super(null);

  bool _enabled;

  void update(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    markNeedsLayout();
  }

  EdgeInsets _insets(double width) {
    if (!_enabled) return EdgeInsets.zero;
    final inset = UtenScrollGutter.insetForWidth(width);
    return EdgeInsets.only(right: inset);
  }

  double _outerWidth(double contentWidth) {
    if (!_enabled) return contentWidth;
    return contentWidth + UtenScrollGutter.trackWidth;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _outerWidth(child?.getMinIntrinsicWidth(height) ?? 0);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _outerWidth(child?.getMaxIntrinsicWidth(height) ?? 0);

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(
        math.max(0, width - _insets(width).horizontal),
      ) ??
      0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(
        math.max(0, width - _insets(width).horizontal),
      ) ??
      0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final insets = _insets(constraints.maxWidth);
    final content =
        child?.getDryLayout(constraints.deflate(insets)) ?? Size.zero;
    return constraints.constrain(
      Size(content.width + insets.horizontal, content.height),
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryBaseline(
    constraints.deflate(_insets(constraints.maxWidth)),
    baseline,
  );

  @override
  void performLayout() {
    final insets = _insets(constraints.maxWidth);
    child?.layout(constraints.deflate(insets), parentUsesSize: true);
    final content = child?.size ?? Size.zero;
    size = constraints.constrain(
      Size(content.width + insets.horizontal, content.height),
    );
    if (child case final child?) {
      (child.parentData! as BoxParentData).offset = Offset(insets.left, 0);
    }
  }
}

/// Only page containers publish margin ownership. A local scrollbar lane must
/// not pretend that its child page has already received two-sided page margins.
class UtenContentInsetsScope extends InheritedWidget {
  const UtenContentInsetsScope({
    super.key,
    this.ownsInsets = true,
    required super.child,
  });

  final bool ownsInsets;

  static bool isPresentOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenContentInsetsScope>()
          ?.ownsInsets ??
      false;

  @override
  bool updateShouldNotify(UtenContentInsetsScope oldWidget) =>
      ownsInsets != oldWidget.ownsInsets;
}
