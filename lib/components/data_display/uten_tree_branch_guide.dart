import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

/// Shared branch rails for table cells and compact directory trees.
///
/// The parent sizes this paint-only widget to the row height and to the current
/// toggle centre. No hit target, spacing, semantics or business state is added.
class UtenTreeBranchGuide extends StatelessWidget {
  static const int defaultMaxVisualDepth = 10;
  static const double defaultIndent = 16;
  static const double defaultToggleExtent = 48;

  const UtenTreeBranchGuide({
    super.key,
    required this.depth,
    required this.ancestorContinuations,
    required this.isLastChild,
    required this.hasExpandedChildren,
    required this.indent,
    required this.toggleExtent,
    required this.maxVisualDepth,
    required this.color,
    this.dotted = false,
  });

  final int depth;
  final List<bool> ancestorContinuations;
  final bool isLastChild;
  final bool hasExpandedChildren;
  final double indent;
  final double toggleExtent;
  final int maxVisualDepth;
  final Color color;
  final bool dotted;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: CustomPaint(
        painter: _TreeGuidePainter(
          depth: depth,
          ancestorContinuations: ancestorContinuations,
          isLastChild: isLastChild,
          hasExpandedChildren: hasExpandedChildren,
          indent: indent,
          toggleExtent: toggleExtent,
          maxVisualDepth: maxVisualDepth,
          color: color,
          dotted: dotted,
        ),
      ),
    ),
  );
}

/// 层级连线的纯几何：给定深度、祖先链与画布尺寸，算出要画哪几条线段。
///
/// 抽成独立函数是为了让口径可被直接断言——2026-09-14 把祖先槽的索引整体翻转
/// 过一次，两个宿主一好一坏而 CI 全绿，就是因为当时没有任何一条测试断言过线段
/// 坐标。宿主不需要调用它，画笔与单测各调一次。
List<({double x1, double y1, double x2, double y2})> utenTreeGuideSegments({
  required int depth,
  required List<bool> ancestorContinuations,
  required bool isLastChild,
  required double height,
  required double width,
  required double connectorY,
  bool hasExpandedChildren = false,
  int maxVisualDepth = UtenTreeBranchGuide.defaultMaxVisualDepth,
  double indent = UtenTreeBranchGuide.defaultIndent,
  double toggleExtent = UtenTreeBranchGuide.defaultToggleExtent,
}) {
  final result = <({double x1, double y1, double x2, double y2})>[];
  double centerX(int level) =>
      level.clamp(0, maxVisualDepth) * indent + toggleExtent / 2;

  if (depth > 0) {
    // 每条竖线与对应父行的箭头圆心同轴。槽 level 承载深度 level+1
    // 节点的兄弟连接，仍按投影的绝对祖先深度读取续线标记。
    // 超过视觉深度上限后多层共用一条轨道，任一祖先仍有兄弟就续到行底。
    final verticalEnds = <double, double>{};
    for (var level = 0; level < depth - 1; level++) {
      final index = level + 1;
      final continues =
          index >= ancestorContinuations.length || ancestorContinuations[index];
      if (continues) verticalEnds[centerX(level)] = height;
    }
    final branchX = centerX(depth - 1);
    verticalEnds.putIfAbsent(branchX, () => isLastChild ? connectorY : height);
    for (final line in verticalEnds.entries) {
      result.add((x1: line.key, y1: 0, x2: line.key, y2: line.value));
    }
    if (branchX < width) {
      result.add((x1: branchX, y1: connectorY, x2: width, y2: connectorY));
    }
  }
  // 父行先从箭头圆心向下引出，再由下一行顶端接续；根行也必须画这一段。
  // 折叠时子行不显示，对应的向下连接也一起收起。
  final childStemAlreadyDrawn = result.any(
    (line) =>
        line.x1 == width &&
        line.x2 == width &&
        line.y1 <= connectorY &&
        line.y2 == height,
  );
  if (hasExpandedChildren && !childStemAlreadyDrawn) {
    result.add((x1: width, y1: connectorY, x2: width, y2: height));
  }
  return result;
}

class _TreeGuidePainter extends CustomPainter {
  const _TreeGuidePainter({
    required this.depth,
    required this.maxVisualDepth,
    required this.indent,
    required this.toggleExtent,
    required this.color,
    required this.ancestorContinuations,
    required this.isLastChild,
    required this.hasExpandedChildren,
    required this.dotted,
  });

  final int depth;
  final int maxVisualDepth;
  final double indent;
  final double toggleExtent;
  final Color color;

  /// `[i]` = 深度 i 的祖先后面还有没有兄弟。长度 = 本行深度
  /// （由树的投影提供）。
  final List<bool> ancestorContinuations;
  final bool isLastChild;

  final bool hasExpandedChildren;
  final bool dotted;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final line in utenTreeGuideSegments(
      depth: depth,
      ancestorContinuations: ancestorContinuations,
      isLastChild: isLastChild,
      height: size.height,
      width: size.width,
      // Stack 和 Row 都垂直居中，画布上下 bleed 对称，故中线即箭头圆心。
      connectorY: size.height / 2,
      hasExpandedChildren: hasExpandedChildren,
      maxVisualDepth: maxVisualDepth,
      indent: indent,
      toggleExtent: toggleExtent,
    )) {
      final start = Offset(line.x1, line.y1);
      final end = Offset(line.x2, line.y2);
      if (!dotted) {
        canvas.drawLine(start, end, paint);
        continue;
      }
      final delta = end - start;
      final length = delta.distance;
      if (length == 0) continue;
      final direction = delta / length;
      // Fine 1px dashes keep dense directory rails quieter than the title.
      // The same segments and centres drive solid table and dotted pane rails.
      for (var offset = 0.0; offset < length; offset += 3) {
        canvas.drawLine(
          start + direction * offset,
          start + direction * math.min(offset + 1, length),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TreeGuidePainter oldDelegate) =>
      oldDelegate.depth != depth ||
      oldDelegate.maxVisualDepth != maxVisualDepth ||
      oldDelegate.indent != indent ||
      oldDelegate.toggleExtent != toggleExtent ||
      oldDelegate.color != color ||
      oldDelegate.dotted != dotted ||
      oldDelegate.isLastChild != isLastChild ||
      oldDelegate.hasExpandedChildren != hasExpandedChildren ||
      !listEquals(oldDelegate.ancestorContinuations, ancestorContinuations);
}
