// 表头"按住纵向拖→隐藏列"手势测试。
//
// 覆盖：拖下过阈值→隐藏；交互列(带筛选InkWell)也能拖隐；拖回取消；点按仍开筛选；
//      末列不可隐；横向拖不隐藏（纵向专属）。手势消歧见 master_data_table_view.dart
//      _buildDraggableHeaderCell 注释。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _c1 = '列1';
const _c2 = '列2';
const _c3 = '列3';

class _Row {
  const _Row(this.v1, this.v2, this.v3);
  final String v1;
  final String v2;
  final String v3;
}

const _rows = <_Row>[_Row('a1', 'a2', 'a3')];

/// 「表头设置 x/y」按钮文案：x=当前可见列数，y=总列数。隐藏一列后 x 减 1。
Finder _chooserLabel(int visible, int total) =>
    find.text('表头设置 $visible/$total');

Widget _table({Map<String, List<MasterFacetBucket>> facets = const {}}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        child: MasterDataTableView<_Row>(
          columns: [
            MasterColumnDef<_Row>(
              key: 'c1',
              label: _c1,
              width: 160,
              value: (r) => r.v1,
            ),
            MasterColumnDef<_Row>(
              key: 'c2',
              label: _c2,
              width: 160,
              value: (r) => r.v2,
            ),
            MasterColumnDef<_Row>(
              key: 'c3',
              label: _c3,
              width: 160,
              value: (r) => r.v3,
            ),
          ],
          items: _rows,
          facets: facets,
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          embedded: true,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('drag header down past threshold hides the column', (
    tester,
  ) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    expect(_chooserLabel(3, 3), findsOneWidget);
    // 纵向拖 c1 表头 60px（过 slop~18 + 阈值10）→ armed → 松开隐藏。
    await tester.drag(find.text(_c1), const Offset(0, 60));
    await tester.pumpAndSettle();

    expect(_chooserLabel(2, 3), findsOneWidget);
    expect(_chooserLabel(3, 3), findsNothing);
  });

  testWidgets(
    'drag down hides an interactive column (with filter InkWell) too',
    (tester) async {
      // c1 带 facets → _FilterCell 走交互分支（InkWell.onTap=_open）。
      // 验证 InkWell 的 tap 识别器不抢占纵向拖拽（竞技场 tap vs vertical-drag）。
      await tester.pumpWidget(
        _table(
          facets: {
            'c1': const [MasterFacetBucket(value: 'a1', count: 1, label: 'A1')],
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.text(_c1), const Offset(0, 60));
      await tester.pumpAndSettle();

      expect(_chooserLabel(2, 3), findsOneWidget);
    },
  );

  testWidgets('drag back below threshold cancels hide', (tester) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.text(_c1));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, 60)); // 向下→arm（累计 dy≈60）
    await gesture.moveBy(const Offset(0, -60)); // 拖回原位→累计 dy≈0，|dy|<10 取消 arm
    await gesture.up();
    await tester.pumpAndSettle();

    // 拖回原位松开 → 不隐藏。
    expect(_chooserLabel(3, 3), findsOneWidget);
  });

  testWidgets('tap header still opens the filter dropdown', (tester) async {
    await tester.pumpWidget(
      _table(
        facets: {
          'c1': const [MasterFacetBucket(value: 'a1', count: 1, label: 'A1')],
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_c1));
    await tester.pumpAndSettle();

    // 筛选下拉的「所有」菜单项出现 → 点按未被拖拽手势抢占。
    expect(find.text('所有'), findsOneWidget);
  });

  testWidgets('long-press header drag reorders columns (session order)', (
    tester,
  ) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    // 长按列1 拎起 → 横拖过列2（160 宽）→ 松手落位到列2 之后。
    final gesture = await tester.startGesture(tester.getCenter(find.text(_c1)));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(180, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // 表头与表体行同步换序：列2 → 列1 → 列3。
    expect(
      tester.getTopLeft(find.text(_c2)).dx,
      lessThan(tester.getTopLeft(find.text(_c1)).dx),
    );
    expect(
      tester.getTopLeft(find.text('a2')).dx,
      lessThan(tester.getTopLeft(find.text('a1')).dx),
    );
    // 排序不隐藏：三列都在。
    expect(_chooserLabel(3, 3), findsOneWidget);
  });

  testWidgets('last visible column cannot be hidden by drag', (tester) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    // 先隐藏 c2、c3，仅剩 c1（末列）。
    await tester.drag(find.text(_c2), const Offset(0, 60));
    await tester.pumpAndSettle();
    await tester.drag(find.text(_c3), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(_chooserLabel(1, 3), findsOneWidget);

    // 拖末列 c1 → armed 条件含 _visibleCount>1，永不 arm → 不隐藏。
    await tester.drag(find.text(_c1), const Offset(0, 60));
    await tester.pumpAndSettle();

    expect(_chooserLabel(1, 3), findsOneWidget);
    expect(find.text(_c1), findsOneWidget);
  });

  testWidgets('horizontal drag on header does not hide (vertical-only)', (
    tester,
  ) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    // 横向拖表头 → 归横向 ScrollView（或不滚动），纵向识别器不触发 → 不隐藏。
    await tester.drag(find.text(_c1), const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(_chooserLabel(3, 3), findsOneWidget);
  });

  testWidgets(
    'drag ghost floats on the topmost overlay, visible beyond the header',
    (tester) async {
      await tester.pumpWidget(_table());
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.text(_c1));
      final gesture = await tester.startGesture(center);
      // 向下大幅拖出表头范围（过 slop + 阈值，且远超表头高度 ~44）。
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();

      // 拖拽中：原格（变淡留原位）+ 跟手浮层（root Overlay）各渲染一份 c1 文案 → 共 2。
      // 旧实现用 Transform.translate 平移原格，整拖拽期间只会找到 1 份文案——
      // 此处 findsNWidgets(2) 即把"浮层是独立 overlay 单元"这一行为钉死。
      expect(find.text(_c1), findsNWidgets(2));

      // 浮层在最顶层、不被表体裁切：其文案明显位于原格下方（跟手位移，clamp 到 120）。
      final t0 = tester.getTopLeft(find.text(_c1).at(0)).dy;
      final t1 = tester.getTopLeft(find.text(_c1).at(1)).dy;
      expect((t1 - t0).abs(), greaterThan(80));

      // 松开（已 armed）→ 隐藏 c1：原格消失、浮层卸下 → 无 c1 文案。
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text(_c1), findsNothing);
      expect(_chooserLabel(2, 3), findsOneWidget);
    },
  );

  testWidgets('drag ghost keeps the original header cell size', (tester) async {
    // 回归（2026-08-11）：Overlay 台上条目是 tight 全屏约束，浮层一度被拉成
    // 800×600 的巨大面板（Align 无 heightFactor expand + Center 参与 Stack 尺寸）。
    // 修复后浮层必须保持原表头格大小：列宽 × ~44。
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(find.text(_c1)));
    await gesture.moveBy(const Offset(0, 100)); // 过阈值 → armed（含红×徽标）
    await tester.pump();

    // 浮层容器 = 带阴影的 Container
    final ghost = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final d = w.decoration;
      return d is BoxDecoration &&
          d.boxShadow != null &&
          d.boxShadow!.isNotEmpty;
    });
    expect(ghost, findsOneWidget);
    final size = tester.getSize(ghost);
    expect(size.width, lessThan(200)); // 列宽量级，绝非全屏宽
    expect(size.height, lessThan(60)); // 表头格 ~44，绝非全屏高

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_chooserLabel(2, 3), findsOneWidget);
  });
}
