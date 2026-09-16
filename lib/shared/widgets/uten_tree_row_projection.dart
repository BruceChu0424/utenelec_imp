import 'package:flutter/foundation.dart' show listEquals;

/// 一行在树里的结构投影：由**最终渲染序**（扁平 DFS）与每行的 depth 推导。
///
/// 全站只保留这一份推导（2026-09-15）。此前物料分析主表与「父件+下层一起下单」
/// 级联页各写了一套：主表从「物料根」起算、列表长度 = depth − 1，级联页从树顶
/// 起算、长度 = depth。[UtenTreeTableCell] 的连线画笔只能按一种口径读，于是
/// 两处必有一处画错——主表所有 depth ≥ 2 的行都读错一级，最深那级恒定越界回落
/// 成「保守连画」，末位子件的竖线永远不收口。
///
/// 口径（与画笔同源，改这里必须同步改 `_TreeGuidePainter`）：
/// - [ancestorContinuations] 长度恒等于 [depth]；`[i]` = **深度 i 的祖先**后面
///   还有没有同深度的兄弟。`[0]`（深度 0 的祖先）永远不会被画出来——它的竖线
///   落在槽 −1——但必须占位，否则索引整体错开一格。
/// - [isLastChild] = 本行后面没有同深度、同棵树的兄弟。
class UtenTreeRowProjection {
  const UtenTreeRowProjection({
    required this.depth,
    required this.hasChildren,
    required this.childCount,
    required this.ancestorContinuations,
    required this.isLastChild,
    required this.subtreeEnd,
  });

  final int depth;
  final bool hasChildren;

  /// 直接下级（depth + 1）的行数。
  final int childCount;

  final List<bool> ancestorContinuations;
  final bool isLastChild;

  /// 本行子树在输入行序里的结束下标（不含）。折叠/批量勾选可直接复用，
  /// 不必各自再手写一遍「往后扫到 depth <= 本行 depth 为止」。
  final int subtreeEnd;

  @override
  bool operator ==(Object other) =>
      other is UtenTreeRowProjection &&
      other.depth == depth &&
      other.hasChildren == hasChildren &&
      other.childCount == childCount &&
      other.isLastChild == isLastChild &&
      other.subtreeEnd == subtreeEnd &&
      listEquals(other.ancestorContinuations, ancestorContinuations);

  @override
  int get hashCode =>
      Object.hash(depth, hasChildren, childCount, isLastChild, subtreeEnd);
}

/// 由扁平渲染序推导每行的树投影。
///
/// [rows] 必须已经是**屏幕上的顺序**（父行紧邻其子树）。这是本函数唯一的前提，
/// 也是它取代「另建一棵树再 DFS 一遍」的原因：两份排序只要有一处不一致，
/// 末位标记就会贴到不是最后一行的行上（主表 `_orderedBomNodes` 按 level+编号排、
/// 而旧的 `_materialTreePositions` 只按编号排，就是这个毛病）。
///
/// [treeKeyOf] 用于同一张表里平铺多棵树（级联页一次勾多行下达）：只有同一棵树
/// 里的同深度行才互为兄弟，否则连线会从上一棵树一路画到下一棵。不传 = 全表一棵树。
List<UtenTreeRowProjection> utenTreeProjection<T>(
  List<T> rows, {
  required int Function(T row) depthOf,
  Object? Function(T row)? treeKeyOf,
}) {
  final count = rows.length;
  if (count == 0) return const [];
  final depths = List<int>.generate(count, (index) => depthOf(rows[index]));
  final treeKeys = treeKeyOf == null
      ? null
      : List<Object?>.generate(count, (index) => treeKeyOf(rows[index]));
  final childCounts = List<int>.filled(count, 0);
  final subtreeEnds = List<int>.filled(count, 0);
  final hasNextSibling = List<bool>.filled(count, false);
  for (var index = 0; index < count; index++) {
    var cursor = index + 1;
    var children = 0;
    while (cursor < count && depths[cursor] > depths[index]) {
      if (depths[cursor] == depths[index] + 1) children++;
      cursor++;
    }
    childCounts[index] = children;
    subtreeEnds[index] = cursor;
    hasNextSibling[index] =
        cursor < count &&
        depths[cursor] == depths[index] &&
        (treeKeys == null || treeKeys[cursor] == treeKeys[index]);
  }
  final result = <UtenTreeRowProjection>[];
  // 每个深度上「最近一个已出现的祖先」的下标，用来 O(1) 继承祖先链。
  final ancestorAtDepth = <int, int>{};
  for (var index = 0; index < count; index++) {
    final depth = depths[index];
    List<bool> continuations;
    if (depth <= 0) {
      continuations = const [];
    } else {
      final parent = ancestorAtDepth[depth - 1];
      if (parent == null) {
        // 结构断裂（上层行被筛掉 / 数据越级）：保守按「祖先都还有兄弟」画满，
        // 宁可多一条竖线，也不要凭空把整条层级线抹掉。
        continuations = List<bool>.filled(depth, true);
      } else {
        continuations = [
          ...result[parent].ancestorContinuations,
          hasNextSibling[parent],
        ];
      }
    }
    ancestorAtDepth[depth] = index;
    ancestorAtDepth.removeWhere((key, value) => key > depth);
    result.add(
      UtenTreeRowProjection(
        depth: depth,
        hasChildren: childCounts[index] > 0,
        childCount: childCounts[index],
        ancestorContinuations: List.unmodifiable(continuations),
        isLastChild: !hasNextSibling[index],
        subtreeEnd: subtreeEnds[index],
      ),
    );
  }
  return List.unmodifiable(result);
}

/// [utenTreeProjection] 的按行索引版本：宿主按行对象取投影，不必自己记下标。
///
/// 行对象必须可作 Map 键（默认引用相等即可）；同一个行对象在 [rows] 里只能
/// 出现一次。
Map<T, UtenTreeRowProjection> utenTreeProjectionByRow<T extends Object>(
  List<T> rows, {
  required int Function(T row) depthOf,
  Object? Function(T row)? treeKeyOf,
}) {
  final projections = utenTreeProjection(
    rows,
    depthOf: depthOf,
    treeKeyOf: treeKeyOf,
  );
  return {
    for (var index = 0; index < rows.length; index++)
      rows[index]: projections[index],
  };
}
