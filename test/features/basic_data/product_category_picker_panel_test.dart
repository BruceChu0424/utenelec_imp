// 货品分类侧滑选择面板（2026-09-11 取代 ProductCategoryDropdown）：
// - 面板内就是货品资料那棵树（可展开折叠 + 搜索 + 选中高亮 + 每节点货品数）；
// - 顶部「全部」行 = 清空筛选；点分类行 = 返回该分类 id 并立即关窗；
// - 零货品分类（goodsCount == 0）整支剪掉，goodsCount == null（后端未给计数）保留。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/product_category_picker_panel.dart';

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
    // 默认展开一层：根与其子分类同屏（树行文案 = 名称(编码)）。
    expect(find.text('货品资料(G)'), findsOneWidget);
    expect(find.text('成品(FIN)'), findsOneWidget);
    expect(find.text('配件(PRT)'), findsOneWidget);
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

    expect(find.text('配件(PRT)'), findsOneWidget);
    expect(find.text('货品资料(G)'), findsOneWidget); // 祖先留作层级上下文
    expect(find.text('成品(FIN)'), findsNothing);
  });

  testWidgets('点分类行 = 返回该分类 id 并关窗', (tester) async {
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

    await tester.tap(find.text('成品(FIN)'));
    await tester.pumpAndSettle();

    expect(picked?.id, 'finished');
    expect(picked?.name, '成品');
    expect(picked?.isAll, isFalse);
    expect(find.byKey(const Key('category-picker-tree')), findsNothing);
  });

  testWidgets('点「全部」= 返回 isAll（清空筛选）', (tester) async {
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

    expect(picked, isNotNull);
    expect(picked?.isAll, isTrue);
    expect(picked?.id, isNull);
  });

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
}
