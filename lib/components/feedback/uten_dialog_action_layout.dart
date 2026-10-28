import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Dialog actions keep their natural widths and share the tallest action's
/// actual height. Unlike a minimum-height style, this also equalizes wrapped
/// labels, icons, native Material buttons and Uten buttons in the same group.
class UtenDialogActionLayout extends MultiChildRenderObjectWidget {
  const UtenDialogActionLayout({
    super.key,
    required super.children,
    required this.alignment,
    required this.overflowAlignment,
    required this.overflowDirection,
    required this.spacing,
    required this.overflowSpacing,
  });

  final MainAxisAlignment alignment;
  final OverflowBarAlignment overflowAlignment;
  final VerticalDirection overflowDirection;
  final double spacing;
  final double overflowSpacing;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDialogActions(this, Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBox renderObject,
  ) => (renderObject as _RenderDialogActions).configure(
    this,
    Directionality.of(context),
  );
}

class _RenderDialogActions extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _RenderDialogActions(this._config, this._direction);

  UtenDialogActionLayout _config;
  TextDirection _direction;

  void configure(UtenDialogActionLayout config, TextDirection direction) {
    _config = config;
    _direction = direction;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _DialogActionParentData();
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
      final value = maximum
          ? child.getMaxIntrinsicWidth(height)
          : child.getMinIntrinsicWidth(height);
      if (value <= 0) continue;
      width += value;
      count++;
    }
    return width + math.max(0, count - 1) * _config.spacing;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _intrinsicWidth(height, maximum: false);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _intrinsicWidth(height, maximum: true);

  @override
  double computeMinIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  Size _layout(BoxConstraints limits, {required bool dry}) {
    Size measure(RenderBox child, BoxConstraints box) {
      if (dry) return child.getDryLayout(box);
      child.layout(box, parentUsesSize: true);
      return child.size;
    }

    final active = <RenderBox>[];
    final sizes = <RenderBox, Size>{};
    var height = 0.0;
    for (final child in _children) {
      final natural = measure(child, limits.loosen());
      if (natural.width <= 0) {
        if (!dry) {
          (child.parentData! as ContainerBoxParentData<RenderBox>).offset =
              Offset.zero;
        }
        continue;
      }
      active.add(child);
      height = math.max(height, natural.height);
    }
    if (active.isEmpty) return limits.smallest;

    // Tight height reaches each button's painted Material, rather than merely
    // increasing its hit target or vertically centering a shorter surface.
    final equal = BoxConstraints(
      maxWidth: limits.maxWidth,
      minHeight: height,
      maxHeight: height,
    );
    var totalWidth = 0.0;
    for (final child in active) {
      sizes[child] = measure(child, equal);
      totalWidth += sizes[child]!.width;
    }
    final gaps = math.max(0, active.length - 1);
    totalWidth += gaps * _config.spacing;
    final stacked = totalWidth > limits.maxWidth;
    final naturalWidth = stacked
        ? active.map((child) => sizes[child]!.width).reduce(math.max)
        : totalWidth;
    final result = limits.constrain(
      Size(
        limits.hasBoundedWidth ? limits.maxWidth : naturalWidth,
        stacked
            ? height * active.length + gaps * _config.overflowSpacing
            : height,
      ),
    );
    if (dry) return result;

    final rtl = _direction == TextDirection.rtl;
    if (stacked) {
      final ordered = _config.overflowDirection == VerticalDirection.up
          ? active.reversed
          : active;
      var y = 0.0;
      for (final child in ordered) {
        final width = sizes[child]!.width;
        final extra = result.width - width;
        final x = switch (_config.overflowAlignment) {
          OverflowBarAlignment.center => extra / 2,
          OverflowBarAlignment.start => rtl ? extra : 0.0,
          OverflowBarAlignment.end => rtl ? 0.0 : extra,
        };
        (child.parentData! as ContainerBoxParentData<RenderBox>).offset =
            Offset(x, y);
        y += height + _config.overflowSpacing;
      }
    } else {
      final free = math.max(0.0, result.width - totalWidth);
      final count = active.length;
      final leading = switch (_config.alignment) {
        MainAxisAlignment.start || MainAxisAlignment.spaceBetween => 0.0,
        MainAxisAlignment.end => free,
        MainAxisAlignment.center => free / 2,
        MainAxisAlignment.spaceAround => free / count / 2,
        MainAxisAlignment.spaceEvenly => free / (count + 1),
      };
      final between =
          _config.spacing +
          switch (_config.alignment) {
            MainAxisAlignment.spaceBetween =>
              count > 1 ? free / (count - 1) : 0.0,
            MainAxisAlignment.spaceAround => free / count,
            MainAxisAlignment.spaceEvenly => free / (count + 1),
            _ => 0.0,
          };
      var x = leading;
      for (final child in active) {
        final width = sizes[child]!.width;
        (child.parentData! as ContainerBoxParentData<RenderBox>).offset =
            Offset(
              rtl ? result.width - x - width : x,
              (result.height - height) / 2,
            );
        x += width + between;
      }
    }
    return result;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _DialogActionParentData extends ContainerBoxParentData<RenderBox> {}
