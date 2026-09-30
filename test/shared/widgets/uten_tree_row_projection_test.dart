import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/uten_tree_row_projection.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

/// 层级连线的口径回归守卫。
///
/// 2026-09-14 到 09-15 之间，画笔读祖先链的索引被整体翻转过一次（`[level]` →
/// `[level+1]`）：两个宿主一好一坏，而 CI 全绿——因为当时没有任何一条断言过
/// 线段坐标，测试夹具自己用的还是长度对不上的列表。本文件把「推导」与「落笔」
/// 两端都钉死成可断言的纯函数。
void main() {
  group('utenTreeProjection', () {
    test('祖先链按绝对深度索引，长度恒等于 depth', () {
      // 0: 树顶
      //   1: A（还有兄弟 B）
      //     2: A1（末位）
      //   1: B（末位）
      //     2: B1（还有兄弟 B2）
      //     2: B2（末位）
      final rows = [0, 1, 2, 1, 2, 2];
      final tree = utenTreeProjection<int>(rows, depthOf: (row) => row);
      for (var index = 0; index < rows.length; index++) {
        expect(
          tree[index].ancestorContinuations.length,
          rows[index],
          reason: '第 $index 行 depth=${rows[index]}',
        );
      }
      // A1：祖先是「树顶(无兄弟)」与「A(还有兄弟 B)」。
      expect(tree[2].ancestorContinuations, [false, true]);
      expect(tree[2].isLastChild, isTrue);
      // B1：祖先是「树顶」与「B(末位)」。
      expect(tree[4].ancestorContinuations, [false, false]);
      expect(tree[4].isLastChild, isFalse);
      expect(tree[5].isLastChild, isTrue);
    });

    test('直接子数与子树范围按扁平行序推导', () {
      final rows = [0, 1, 2, 1, 2, 2];
      final tree = utenTreeProjection<int>(rows, depthOf: (row) => row);
      expect(tree[0].childCount, 2);
      expect(tree[0].hasChildren, isTrue);
      expect(tree[0].subtreeEnd, 6);
      expect(tree[3].childCount, 2);
      expect(tree[3].subtreeEnd, 6);
      expect(tree[2].hasChildren, isFalse);
      expect(tree[2].subtreeEnd, 3);
    });

    test('同表平铺多棵树时，树与树不互认兄弟', () {
      final rows = [
        (depth: 0, tree: 'A'),
        (depth: 1, tree: 'A'),
        (depth: 0, tree: 'B'),
        (depth: 1, tree: 'B'),
      ];
      final tree = utenTreeProjection<({int depth, String tree})>(
        rows,
        depthOf: (row) => row.depth,
        treeKeyOf: (row) => row.tree,
      );
      expect(tree[0].isLastChild, isTrue, reason: '下一棵树的树顶不是本树顶的兄弟');
      expect(tree[1].ancestorContinuations, [false]);
    });

    test('结构断裂（上层行被筛掉）时保守连画，不抹掉整条层级线', () {
      final tree = utenTreeProjection<int>([2, 3], depthOf: (row) => row);
      expect(tree[0].ancestorContinuations, [true, true]);
      expect(tree[1].ancestorContinuations, [true, true, false]);
    });
  });

  group('utenTreeGuideSegments', () {
    List<({double x1, double y1, double x2, double y2})> segments({
      required int depth,
      required List<bool> continuations,
      required bool isLastChild,
      double height = 56,
      double connectorY = 28,
      bool hasExpandedChildren = false,
      int maxVisualDepth = UtenTreeTableCell.defaultMaxVisualDepth,
    }) => utenTreeGuideSegments(
      depth: depth,
      ancestorContinuations: continuations,
      isLastChild: isLastChild,
      height: height,
      width: depth.clamp(0, maxVisualDepth) * 16.0 + 24,
      connectorY: connectorY,
      hasExpandedChildren: hasExpandedChildren,
      maxVisualDepth: maxVisualDepth,
    );

    test('未展开的 depth 0 不画任何线', () {
      expect(
        segments(depth: 0, continuations: const [], isLastChild: true),
        isEmpty,
      );
    });

    test('展开的根节点从箭头圆心向下接到行底', () {
      expect(
        segments(
          depth: 0,
          continuations: const [],
          isLastChild: true,
          hasExpandedChildren: true,
        ),
        [(x1: 24.0, y1: 28.0, x2: 24.0, y2: 56.0)],
      );
    });

    test('末位子件的竖线收在肘线处，不一路画到格底', () {
      final lines = segments(
        depth: 1,
        continuations: const [false],
        isLastChild: true,
      );
      final branch = lines.firstWhere((line) => line.x1 == line.x2);
      expect(branch.x1, 24, reason: '与 depth 0 父节点的箭头圆心对齐');
      expect(branch.y1, 0);
      expect(branch.y2, 28, reason: '收在肘线（展开位圆心），不是 size.height');
    });

    test('还有兄弟时竖线画到格底，与下一行接上', () {
      final lines = segments(
        depth: 1,
        continuations: const [false],
        isLastChild: false,
      );
      final branch = lines.firstWhere((line) => line.x1 == line.x2);
      expect(branch.y2, 56);
    });

    test('槽 k 承载深度 k+1 的祖先：末位祖先那一槽不画竖线', () {
      // depth 3、深度 1 的祖先是末位（continuations[1] = false）→ 槽 0 不画；
      // 深度 2 的祖先还有兄弟（continuations[2] = true）→ 槽 1 画。
      final lines = segments(
        depth: 3,
        continuations: const [false, false, true],
        isLastChild: true,
      );
      final verticals = lines
          .where((line) => line.x1 == line.x2)
          .map((line) => line.x1)
          .toList();
      expect(verticals, [
        40,
        56,
      ], reason: '祖先线在 depth 1 的箭头中心 x=40，本行分支在 depth 2 的箭头中心 x=56');
    });

    test('肘线横段一路伸到展开位圆心', () {
      final lines = segments(
        depth: 2,
        continuations: const [false, false],
        isLastChild: true,
      );
      final elbow = lines.firstWhere((line) => line.y1 == line.y2);
      expect(elbow.x1, 40, reason: '从父节点圆心起笔');
      expect(elbow.x2, 2 * 16.0 + 24);
      expect(elbow.y1, 28);
    });

    test('祖先链长度不足时按「祖先仍有兄弟」保守连画', () {
      final lines = segments(
        depth: 3,
        continuations: const [],
        isLastChild: true,
      );
      final verticals = lines
          .where((line) => line.x1 == line.x2)
          .map((line) => line.x1)
          .toList();
      expect(verticals, [24, 40, 56]);
    });

    test('末位父件展开时入线收口，下级连线从自身圆心继续', () {
      final expandedLines = segments(
        depth: 1,
        continuations: const [false],
        isLastChild: true,
        hasExpandedChildren: true,
      );
      expect(
        expandedLines,
        containsAll([
          (x1: 24.0, y1: 0.0, x2: 24.0, y2: 28.0),
          (x1: 40.0, y1: 28.0, x2: 40.0, y2: 56.0),
        ]),
      );
      final collapsedLines = segments(
        depth: 1,
        continuations: const [false],
        isLastChild: true,
      );
      expect(
        collapsedLines.any((line) => line.x1 == 40 && line.y2 > 28),
        isFalse,
        reason: '折叠后不得留下悬空的下级连线',
      );
    });

    test('父子行高不同时连接线跨过 8px 内边距仍在边界重合', () {
      const bleed = 8.0;
      const parentContentHeight = 48.0;
      const childContentHeight = 80.0;
      const parentRowTop = 100.0;
      const parentRowHeight = parentContentHeight + 2 * bleed;
      const childRowTop = parentRowTop + parentRowHeight;
      const childRowHeight = childContentHeight + 2 * bleed;
      final parentLines = segments(
        depth: 0,
        continuations: const [],
        isLastChild: true,
        height: parentRowHeight,
        connectorY: bleed + parentContentHeight / 2,
        hasExpandedChildren: true,
      );
      final childLines = segments(
        depth: 1,
        continuations: const [false],
        isLastChild: true,
        height: childRowHeight,
        connectorY: bleed + childContentHeight / 2,
      );
      final parentStem = parentLines.single;
      final childBranch = childLines.singleWhere((line) => line.x1 == line.x2);
      expect(parentStem.x2, childBranch.x1);
      expect(parentRowTop + parentStem.y2, childRowTop + childBranch.y1);
      expect(parentStem.y1, parentRowHeight / 2);
      expect(childBranch.y2, childRowHeight / 2);
    });

    test('末位孙件收口时仍保留通往父件后续兄弟的祖先竖线', () {
      // 根 → A → A1 → B。A1 是 A 的末子，但根下还有 B。
      final depths = [0, 1, 2, 1];
      final tree = utenTreeProjection<int>(depths, depthOf: (row) => row);
      final grandchildLines = segments(
        depth: depths[2],
        continuations: tree[2].ancestorContinuations,
        isLastChild: tree[2].isLastChild,
      );
      expect(
        grandchildLines,
        containsAll([
          (x1: 24.0, y1: 0.0, x2: 24.0, y2: 56.0),
          (x1: 40.0, y1: 0.0, x2: 40.0, y2: 28.0),
        ]),
      );
      final nextSiblingLines = segments(
        depth: depths[3],
        continuations: tree[3].ancestorContinuations,
        isLastChild: tree[3].isLastChild,
      );
      expect(
        nextSiblingLines,
        contains((x1: 24.0, y1: 0.0, x2: 24.0, y2: 28.0)),
      );
    });

    test('缩进封顶后的子件仍接到真实父层箭头圆心', () {
      for (final depth in [3, 4]) {
        final lines = segments(
          depth: depth,
          continuations: List.filled(depth, false),
          isLastChild: true,
          maxVisualDepth: 2,
        );
        expect(
          lines,
          contains((x1: 56.0, y1: 0.0, x2: 56.0, y2: 28.0)),
          reason: '真实 depth=$depth 的父级也已封顶到 x=56',
        );
        expect(lines.every((line) => line.x1 == 56 && line.x2 == 56), isTrue);
      }
    });

    test('封顶重合的祖先仍有兄弟时末子不得截断其竖线', () {
      final lines = segments(
        depth: 4,
        continuations: const [false, false, false, true],
        isLastChild: true,
        maxVisualDepth: 2,
      );
      final verticals = lines.where(
        (line) => line.x1 == line.x2 && line.y1 != line.y2,
      );
      expect(verticals, [
        (x1: 56.0, y1: 0.0, x2: 56.0, y2: 56.0),
      ], reason: '同 x 的祖先续线与末子入线合并，祖先仍需延伸到行底');
    });

    test('封顶后展开父件不重复描画已通到底部的祖先或兄弟竖线', () {
      for (final scenario in [
        (depth: 3, continuations: [false, false, false], isLastChild: false),
        (
          depth: 4,
          continuations: [false, false, false, true],
          isLastChild: true,
        ),
      ]) {
        final lines = segments(
          depth: scenario.depth,
          continuations: scenario.continuations,
          isLastChild: scenario.isLastChild,
          maxVisualDepth: 2,
          hasExpandedChildren: true,
        );
        expect(lines, [
          (x1: 56.0, y1: 0.0, x2: 56.0, y2: 56.0),
        ], reason: 'depth=${scenario.depth} 的入线已经到底，展开连线不得重画半透明轨道');
      }
    });
  });

  test('推导与落笔口径一致：projection 的输出可直接喂给画笔', () {
    final rows = [0, 1, 2, 1];
    final tree = utenTreeProjection<int>(rows, depthOf: (row) => row);
    for (var index = 0; index < rows.length; index++) {
      final depth = rows[index];
      final lines = utenTreeGuideSegments(
        depth: depth,
        ancestorContinuations: tree[index].ancestorContinuations,
        isLastChild: tree[index].isLastChild,
        height: 48,
        width: depth * 16.0 + 24,
        connectorY: 24,
      );
      // 画笔只会读到 [1, depth-1] 区间的索引，绝不会越界回落成「保守连画」。
      expect(
        tree[index].ancestorContinuations.length,
        greaterThanOrEqualTo(depth),
      );
      expect(lines.length, depth == 0 ? 0 : greaterThanOrEqualTo(2));
    }
  });
}
