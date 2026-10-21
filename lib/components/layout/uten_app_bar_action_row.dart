import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../core/theme/uten_tokens.dart';

/// A header row whose zero-width permission/feature actions leave no gaps.
class UtenAppBarActionRow extends MultiChildRenderObjectWidget {
  const UtenAppBarActionRow({super.key, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ActionRowRenderBox(Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBox renderObject,
  ) => (renderObject as _ActionRowRenderBox).textDirection = Directionality.of(
    context,
  );
}

class _ActionRowRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _ActionRowRenderBox(this._textDirection);

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _ActionRowParentData();
    }
  }

  Iterable<RenderBox> get _children sync* {
    var child = firstChild;
    while (child != null) {
      yield child;
      child = childAfter(child);
    }
  }

  double _intrinsicWidth(double height, {required bool maximum}) {
    var width = 0.0;
    var count = 0;
    for (final child in _children) {
      final childWidth = maximum
          ? child.getMaxIntrinsicWidth(height)
          : child.getMinIntrinsicWidth(height);
      if (childWidth <= 0) continue;
      if (count++ > 0) width += UtenSpacing.s4;
      width += childWidth;
    }
    return width;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _intrinsicWidth(height, maximum: false);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _intrinsicWidth(height, maximum: true);

  @override
  double computeMinIntrinsicHeight(double width) {
    var height = 0.0;
    for (final child in _children) {
      height = math.max(height, child.getMinIntrinsicHeight(double.infinity));
    }
    return height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    var height = 0.0;
    for (final child in _children) {
      height = math.max(height, child.getMaxIntrinsicHeight(double.infinity));
    }
    return height;
  }

  Size _layoutChildren(BoxConstraints constraints, {required bool dry}) {
    final childConstraints = BoxConstraints(maxHeight: constraints.maxHeight);
    var width = 0.0;
    var height = 0.0;
    var count = 0;
    for (final child in _children) {
      final Size childSize;
      if (dry) {
        childSize = child.getDryLayout(childConstraints);
      } else {
        child.layout(childConstraints, parentUsesSize: true);
        childSize = child.size;
      }
      if (childSize.width <= 0) continue;
      if (count++ > 0) width += UtenSpacing.s4;
      width += childSize.width;
      height = math.max(height, childSize.height);
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layoutChildren(constraints, dry: true);

  @override
  void performLayout() {
    size = _layoutChildren(constraints, dry: false);
    var offset = 0.0;
    var count = 0;
    for (final child in _children) {
      final data = child.parentData! as ContainerBoxParentData<RenderBox>;
      if (child.size.width <= 0) {
        data.offset = Offset.zero;
        continue;
      }
      if (count++ > 0) offset += UtenSpacing.s4;
      data.offset = Offset(
        _textDirection == TextDirection.ltr
            ? offset
            : size.width - offset - child.size.width,
        (size.height - child.size.height) / 2,
      );
      offset += child.size.width;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _ActionRowParentData extends ContainerBoxParentData<RenderBox> {}
