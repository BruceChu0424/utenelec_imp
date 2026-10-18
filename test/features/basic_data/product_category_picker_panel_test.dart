// 货品分类侧滑选择面板（2026-09-11 取代 ProductCategoryDropdown）：
// - 面板内就是货品资料那棵树（可展开折叠 + 搜索 + 选中高亮 + 每节点货品数）；
// - 顶部「全部」行 = 清空筛选；点分类行或全部暂存，确定后返回；
// - 零货品分类（goodsCount == 0）整支剪掉，goodsCount == null（后端未给计数）保留。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/product_category_picker_panel.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

List<ProductCategoryNode> _tree() => [
  ProductCategoryNode(
    id: 'root',
    code: 'G',
    name: '货品资料',
    level: 0,
    goodsCount: 5,
    children: [
      ProductCategoryNode(
        id: 'finished',
        code: 'FIN',
        name: '成品',
        level: 1,
        goodsCount: 3,
        children: const <ProductCategoryNode>[],
      ),
      ProductCategoryNode(
        id: 'parts',
        code: 'PRT',
        name: '配件',
        level: 1,
        goodsCount: 2,
        children: const <ProductCategoryNode>[],
      ),
    ],
  ),
  ProductCategoryNode(
    id: 'orphan',
    code: 'ORP',
    name: '未分类（历史孤儿）',
    level: 0,
    goodsCount: 0,
    children: const <ProductCategoryNode>[],
  ),
];

void main() {
  Future<ProductCategoryPickResult?> open(
    WidgetTester tester, {
    String? selectedId,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ProductCategoryPickResult? picked;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showUtenProductCategoryPickerPanel(
                  context,
                  tree: _tree(),
                  selectedId: selectedId,
                );
                closed = true;
              },
              child: const Text('选择分类'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择分类'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    return picked;
  }

  testWidgets('面板渲染分类树：全部行 + 根/子分类 + 货品数；零货品分类整支隐藏', (tester) async {
    await open(tester);

    expect(find.byKey(const Key('category-picker-all')), findsOneWidget);
    expect(find.byKey(const Key('category-picker-tree')), findsOneWidget);
    // 单根「货品资料」被提升（2026-09-24）：包装根不再显示，直接列其子类。
    expect(find.text('货品资料'), findsNothing);
    expect(find.text('成品'), findsOneWidget);
    expect(find.text('配件').last, findsOneWidget);
    // 每节点尾部显子树货品数。
    expect(find.text('3'), findsOneWidget);
    // 零货品分类不出现。
    expect(find.textContaining('未分类（历史孤儿）'), findsNothing);
  });

  testWidgets('搜索收窄到命中分类（命中路径保留祖先）', (tester) async {
    await open(tester);

    await tester.enterText(
      find.byKey(const Key('category-picker-search')),
      '配件',
    );
    await tester.pumpAndSettle();

    expect(find.text('配件').last, findsOneWidget);
    // 提升后的森林里「配件」已是根：没有更高祖先可留，也不回到被提升的包装根。
    expect(find.text('货品资料'), findsNothing);
    expect(find.text('成品'), findsNothing);
  });

  for (final selectedId in ['missing', 'orphan']) {
    testWidgets('已删除或被零货品剪枝的初值 $selectedId 不可直接确认', (tester) async {
      await open(tester, selectedId: selectedId);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('category-picker-all')));
      await tester.pump();
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
            .onPressed,
        isNotNull,
      );
    });
  }

  testWidgets('只是单根提升的包装根初值仍有效且显示其名称', (tester) async {
    await open(tester, selectedId: 'root');
    expect(find.text('已选择：货品资料'), findsOneWidget);
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('点分类行只更新选中态，确定后返回分类 id 并关窗', (tester) async {
    ProductCategoryPickResult? picked;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showUtenProductCategoryPickerPanel(
                  context,
                  tree: _tree(),
                );
              },
              child: const Text('选择分类'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择分类'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('成品'));
    await tester.pumpAndSettle();

    expect(picked, isNull);
    expect(
      tester
          .widget<UtenCategoryTreeView<ProductCategoryNode>>(
            find.byKey(const Key('category-picker-tree')),
          )
          .selectedIds,
      {'finished'},
    );
    await tester.tap(find.widgetWithText(UtenButton, '确定'));
    await tester.pumpAndSettle();

    expect(picked?.id, 'finished');
    expect(picked?.name, '成品');
    expect(picked?.isAll, isFalse);
    expect(find.byKey(const Key('category-picker-tree')), findsNothing);
  });

  testWidgets('点「全部」先暂存，确定才返回 isAll（清空筛选）', (tester) async {
    ProductCategoryPickResult? picked;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showUtenProductCategoryPickerPanel(
                  context,
                  tree: _tree(),
                  selectedId: 'finished',
                );
              },
              child: const Text('选择分类'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择分类'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('category-picker-all')));
    await tester.pumpAndSettle();

    expect(picked, isNull);
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('category-picker-all')))
          .selected,
      isTrue,
    );
    await tester.tap(find.widgetWithText(UtenButton, '确定'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked?.isAll, isTrue);
    expect(picked?.id, isNull);
  });

  for (final dismiss in ['取消', '关闭', '遮罩']) {
    testWidgets('分类改选与全部均可由$dismiss放弃，重开保留原初值', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final results = <ProductCategoryPickResult?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(
                  await showUtenProductCategoryPickerPanel(
                    context,
                    tree: _tree(),
                    selectedId: 'finished',
                  ),
                ),
                child: const Text('打开分类'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('配件'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('category-picker-all')));
      await tester.pump();
      expect(results, isEmpty);
      switch (dismiss) {
        case '取消':
          await tester.tap(find.widgetWithText(UtenButton, '取消'));
        case '关闭':
          await tester.tap(find.byTooltip('关闭'));
        case '遮罩':
          await tester.tapAt(const Offset(20, 400));
      }
      await tester.pumpAndSettle();
      expect(results, [null]);
      await tester.tap(find.text('打开分类'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenCategoryTreeView<ProductCategoryNode>>(
              find.byKey(const Key('category-picker-tree')),
            )
            .selectedIds,
        {'finished'},
      );
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(results.last?.id, 'finished');
    });
  }

  test('pruneCategoriesWithoutGoods：零货品整支剪掉，未给计数一律保留', () {
    final pruned = pruneCategoriesWithoutGoods(_tree());
    expect(pruned.map((n) => n.id), ['root']);
    expect(pruned.single.children.map((n) => n.id), ['finished', 'parts']);

    // 父类零货品 → 整支消失（计数是子树口径）。
    final emptyParent = [
      ProductCategoryNode(
        id: 'p',
        code: 'P',
        name: '空父类',
        level: 0,
        goodsCount: 0,
        children: [
          ProductCategoryNode(
            id: 'c',
            code: 'C',
            name: '子类',
            level: 1,
            goodsCount: 0,
            children: const <ProductCategoryNode>[],
          ),
        ],
      ),
    ];
    expect(pruneCategoriesWithoutGoods(emptyParent), isEmpty);

    // goodsCount == null（后端未给计数）不剪。
    final noCounts = [
      ProductCategoryNode(
        id: 'x',
        code: 'X',
        name: '无计数',
        level: 0,
        children: const <ProductCategoryNode>[],
      ),
    ];
    expect(pruneCategoriesWithoutGoods(noCounts).single.id, 'x');
  });

  test('hoistSingleRootTree：单根逐层提升，多根与叶子根保持原样', () {
    // 剪枝后只剩单根「货品资料」→ 提升为其子类（成品/配件）。
    final hoisted = hoistSingleRootTree(pruneCategoriesWithoutGoods(_tree()));
    expect(hoisted.map((n) => n.id), ['finished', 'parts']);

    // 多根森林不提升（原样返回）。
    expect(identical(hoistSingleRootTree(hoisted), hoisted), isTrue);

    // 单根且为叶子（如 scope 过滤后仅剩一个叶子分类）保持可选，不提升成空。
    final leafOnly = [
      ProductCategoryNode(
        id: 'leaf',
        code: 'L',
        name: '叶子根',
        level: 0,
        children: const <ProductCategoryNode>[],
      ),
    ];
    expect(hoistSingleRootTree(leafOnly).single.id, 'leaf');

    // 嵌套单根链：逐层提升到出现多个根为止。
    final nested = [
      ProductCategoryNode(
        id: 'a',
        code: 'A',
        name: '外层包装',
        level: 0,
        children: [
          ProductCategoryNode(
            id: 'b',
            code: 'B',
            name: '内层包装',
            level: 1,
            children: [
              ProductCategoryNode(
                id: 'c1',
                code: 'C1',
                name: '分类一',
                level: 2,
                children: const <ProductCategoryNode>[],
              ),
              ProductCategoryNode(
                id: 'c2',
                code: 'C2',
                name: '分类二',
                level: 2,
                children: const <ProductCategoryNode>[],
              ),
            ],
          ),
        ],
      ),
    ];
    expect(hoistSingleRootTree(nested).map((n) => n.id), ['c1', 'c2']);
  });
}
