import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_goods_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('统一搜索受 picker scope 限定并定位所有命中分类', (tester) async {
    final goodsRepository = _FakeGoodsRepository();
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();

    final sheet = _widePickerSheet();
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.byType(TextField)),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(_searchTextField()).decoration?.hintText,
      '搜索分类/货品名称或编号',
    );

    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(goodsRepository.searchQueries, ['G-']);
    expect(goodsRepository.searchCategoryIdQueries, ['G-']);
    // sellable scope 已过滤原材料根，且单根「成品」被提升：后端收到的可见森林根
    // 是提升后的子类（含长名分类），不是前端取前 20 条后再过滤。
    expect(goodsRepository.searchRootScopes.single, {
      'section-a',
      'section-b',
      'long-cat',
    });
    expect(find.text('连接器甲(G-001)'), findsOneWidget);
    expect(find.text('连接器乙(G-002) · 黑色'), findsOneWidget);
    // 货品行一行显示（名字(编号) · 颜色），无单位/规格/库位副标题行。
    final goodsRow = tester.widget<ListTile>(
      find
          .ancestor(
            of: find.text('连接器乙(G-002) · 黑色'),
            matching: find.byType(ListTile),
          )
          .first,
    );
    expect(goodsRow.subtitle, isNull);

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.showSearch, isFalse);
    expect(tree.visibleFilterIds, {'section-a', 'section-b'});
    expect(tree.selectedIds, {'section-a'});

    // 搜索期间改点另一个命中分类，关键词保留，并切换为该分类内搜索。
    await tester.tap(find.text('分区乙(B)'));
    await tester.pumpAndSettle();
    expect(goodsRepository.listCalls.last, ('section-b', 'G-'));
    expect(tester.widget<TextField>(_searchTextField()).controller?.text, 'G-');

    // 清除只退出搜索，保留当前位置并恢复分类列表（UtenSearchBar 内置清除按钮）。
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('uten-goods-picker-search')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(goodsRepository.listCalls.last, ('section-b', null));
    final clearedTree = tester
        .widget<UtenCategoryTreeView<ProductCategoryNode>>(
          find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        );
    expect(clearedTree.visibleFilterIds, isNull);
    expect(clearedTree.selectedIds, {'section-b'});
  });

  testWidgets('旧后端忽略 scope 时客户端拒绝展示范围外货品', (tester) async {
    final goodsRepository = _FakeGoodsRepository(returnOutOfScopeItem: true);
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'RAW-001');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(find.text('搜索货品失败，请稍后重试'), findsWidgets);
    expect(find.text('范围外原料(RAW-001)'), findsNothing);
  });

  testWidgets('纯分类命中后点分类不把分类词当成货品关键词', (tester) async {
    final goodsRepository = _FakeGoodsRepository(categoryOnlyQuery: '分区');
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), '分区');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(goodsRepository.searchQueries, ['分区']);
    expect(goodsRepository.searchCategoryIdQueries, ['分区']);
    expect(goodsRepository.listCalls.last, ('section-a', null));

    await tester.tap(find.text('分区乙(B)'));
    await tester.pumpAndSettle();

    expect(goodsRepository.listCalls.last, ('section-b', null));
    expect(
      tester.widget<TextField>(_searchTextField()).controller?.text,
      '分区',
      reason: '分类词仍应保留在统一搜索框，只是不应下推为货品字段过滤',
    );
  });

  testWidgets('多页搜索会汇总后续页分类用于完整展开', (tester) async {
    final goodsRepository = _FakeGoodsRepository(splitAcrossPages: true);
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.visibleFilterIds, {'section-a', 'section-b'});
    expect(goodsRepository.searchPages, [1]);
    expect(goodsRepository.searchCategoryIdQueries, ['G-']);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded).last);
    await tester.pumpAndSettle();

    final pageTwoTree = tester
        .widget<UtenCategoryTreeView<ProductCategoryNode>>(
          find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        );
    expect(pageTwoTree.visibleFilterIds, {'section-a', 'section-b'});
    expect(goodsRepository.searchPages, [1, 2]);
    expect(goodsRepository.searchCategoryIdQueries, [
      'G-',
    ], reason: '翻页应复用首次轻量定位结果，不能重扫或缩窄分类树');
  });

  testWidgets('旧慢请求晚返回不会覆盖较新的搜索结果', (tester) async {
    final goodsRepository = _FakeGoodsRepository(delayedQuery: '旧关键词');
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(_searchEditable(), '旧关键词');
    await tester.pump(const Duration(milliseconds: 301));
    expect(goodsRepository.searchQueries, ['旧关键词']);

    await tester.enterText(_searchEditable(), 'G-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('连接器甲(G-001)'), findsOneWidget);

    goodsRepository.completeDelayedSearch(const [_outOfScopeGoods]);
    await tester.pumpAndSettle();

    expect(find.text('连接器甲(G-001)'), findsOneWidget);
    expect(find.text('范围外原料(RAW-001)'), findsNothing);
    expect(find.text('搜索货品失败，请稍后重试'), findsNothing);
  });

  testWidgets('单根提升 + 无缩进层级色 + 可拖分割线', (tester) async {
    final goodsRepository = _FakeGoodsRepository();
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();

    // sellable 过滤后只剩单根「成品」，自动提升：包装根不再显示，直接列子类。
    expect(find.text('成品(FINISHED)'), findsNothing);
    expect(find.text('分区甲(A)'), findsOneWidget);
    expect(find.text('分区乙(B)'), findsOneWidget);

    // medium+ 布局换成 UtenSplitView（可拖分割线，货品资料页同款）。
    expect(find.byType(UtenSplitView), findsOneWidget);

    // 一级行（提升后的三个根分类）：深绿实底 + 方角（无缩进层级色模式）。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Material &&
            widget.color == UtenColors.deepGreen &&
            widget.borderRadius == BorderRadius.zero,
      ),
      findsNWidgets(3),
    );
    // flat 行间有 1px 分隔线：收起时整列同色（全是一级深绿行）也分得清一行一行。
    expect(
      find.descendant(
        of: find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              ((widget.decoration as BoxDecoration).border?.bottom.width ??
                      0) ==
                  1,
        ),
      ),
      findsWidgets,
    );
    // 左树默认宽度 = 最长一行内容的实测宽度（不取固定 240）。
    final split = tester.widget<UtenSplitView>(find.byType(UtenSplitView));
    expect(split.persistenceKey, 'goodsPicker.categoryTree');
    expect(split.initialLeadingWidth, greaterThan(240));
  });

  testWidgets('多选：底部「已选 N 项」滑层可逐项取消选择', (tester) async {
    final goodsRepository = _FakeGoodsRepository();
    final results = <List<GoodsListItem>>[];
    await _pumpMultiPicker(tester, goodsRepository, results);

    await tester.tap(find.byKey(const Key('open-multi-picker')));
    await tester.pumpAndSettle();

    // 懒载：先点根分类（提升后 = 分区甲）加载货品列表，再点货品行勾选。
    await tester.tap(find.text('分区甲(A)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接器甲(G-001)'));
    await tester.pumpAndSettle();
    // 选中行 = 全站统一淡绿背景（utenTableSelectedRowColor）。
    final pickedTile = tester.widget<ListTile>(
      find
          .ancestor(
            of: find.text('连接器甲(G-001)'),
            matching: find.byType(ListTile),
          )
          .first,
    );
    expect(pickedTile.selected, isTrue);
    expect(pickedTile.selectedTileColor, UtenColors.tableSelectedRow);
    // 切到分区乙再勾一条。
    await tester.tap(find.text('分区乙(B)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接器乙(G-002) · 黑色'));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 项'), findsOneWidget);

    // 点「已选 2 项」从底部滑出已选清单。
    await tester.tap(find.byKey(const Key('goods-picker-selected-summary')));
    await tester.pumpAndSettle();
    expect(find.text('已选货品（2）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('goods-picker-selected-row-goods-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('goods-picker-selected-row-goods-b')),
      findsOneWidget,
    );

    // 清单内逐项取消一条，标题与外部胶囊计数同步。
    await tester.tap(
      find.byKey(const ValueKey('goods-picker-selected-remove-goods-a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选货品（1）'), findsOneWidget);

    // 收起滑层后确定，只返回剩余一条。
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
    await tester.pumpAndSettle();
    expect(results, hasLength(1));
    expect(results.single.map((goods) => goods.id), ['goods-b']);
  });
}

Future<void> _pumpPicker(
  WidgetTester tester,
  GoodsRepository goodsRepository,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(),
        ),
        goodsRepositoryProvider.overrideWithValue(goodsRepository),
      ],
      child: const MaterialApp(home: _PickerHarness()),
    ),
  );
}

Future<void> _pumpMultiPicker(
  WidgetTester tester,
  GoodsRepository goodsRepository,
  List<List<GoodsListItem>> results,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(),
        ),
        goodsRepositoryProvider.overrideWithValue(goodsRepository),
      ],
      child: MaterialApp(home: _MultiPickerHarness(results: results)),
    ),
  );
}

Finder _widePickerSheet() => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == 720 &&
      widget.height == double.infinity,
);

/// 统一搜索已换成 UtenSearchBar：key 在组件上，输入/取控件须定位其内部输入框。
Finder _searchEditable() => find.descendant(
  of: find.byKey(const Key('uten-goods-picker-search')),
  matching: find.byType(EditableText),
);

Finder _searchTextField() => find.descendant(
  of: find.byKey(const Key('uten-goods-picker-search')),
  matching: find.byType(TextField),
);

class _PickerHarness extends ConsumerWidget {
  const _PickerHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: ElevatedButton(
        key: const Key('open-goods-picker'),
        onPressed: () => showUtenGoodsPicker(context, ref),
        child: const Text('打开货品选择'),
      ),
    );
  }
}

class _MultiPickerHarness extends ConsumerWidget {
  const _MultiPickerHarness({required this.results});

  final List<List<GoodsListItem>> results;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: ElevatedButton(
        key: const Key('open-multi-picker'),
        onPressed: () async {
          final picked = await showUtenGoodsPickerMulti(
            context,
            ref,
            scope: UtenGoodsPickerScope.sellable,
          );
          results.add(picked);
        },
        child: const Text('打开多选货品选择'),
      ),
    );
  }
}

class _FakeCategoryRepository extends Fake
    implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => _tree;

  // 货品选择器不消费货品计数；沿用无计数树即可。
  @override
  Future<List<ProductCategoryNode>> treeWithGoodsCounts() async => _tree;
}

class _FakeGoodsRepository extends Fake implements GoodsRepository {
  _FakeGoodsRepository({
    this.returnOutOfScopeItem = false,
    this.splitAcrossPages = false,
    this.delayedQuery,
    this.categoryOnlyQuery,
  });

  final bool returnOutOfScopeItem;
  final bool splitAcrossPages;
  final String? delayedQuery;
  final String? categoryOnlyQuery;
  final _delayedSearch = Completer<PagedResult<GoodsListItem>>();
  final searchQueries = <String>[];
  final searchPages = <int>[];
  final searchRootScopes = <Set<String>>[];
  final searchCategoryIdQueries = <String>[];
  final listCalls = <(String, String?)>[];

  void completeDelayedSearch(List<GoodsListItem> items) {
    _delayedSearch.complete(_page(items, page: 1, size: 100));
  }

  @override
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    Set<String> categoryRootIds = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    searchQueries.add(keyword);
    searchPages.add(page);
    searchRootScopes.add({...categoryRootIds});
    if (keyword == delayedQuery) return _delayedSearch.future;
    if (keyword == categoryOnlyQuery) {
      return _page(const [], page: page, size: size);
    }
    if (splitAcrossPages) {
      return PagedResult(
        items: page == 1 ? const [_goodsA] : const [_goodsB],
        page: page,
        size: size,
        total: 2,
        totalPages: 2,
      );
    }
    return _page(
      returnOutOfScopeItem
          ? const [_outOfScopeGoods]
          : const [_goodsA, _goodsB],
      page: page,
      size: size,
    );
  }

  @override
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    searchCategoryIdQueries.add(keyword);
    if (returnOutOfScopeItem) return const {'raw-root'};
    if (keyword == categoryOnlyQuery) return const <String>{};
    return const {'section-a', 'section-b'};
  }

  @override
  Future<PagedResult<GoodsListItem>> list(
    String? categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
  }) async {
    listCalls.add((categoryId!, keyword));
    final items = categoryId == 'section-b' ? const [_goodsB] : const [_goodsA];
    return _page(items, page: page, size: size);
  }
}

PagedResult<GoodsListItem> _page(
  List<GoodsListItem> items, {
  required int page,
  required int size,
}) => PagedResult(
  items: items,
  page: page,
  size: size,
  total: items.length,
  totalPages: 1,
);

const _goodsA = GoodsListItem(
  id: 'goods-a',
  code: 'G-001',
  name: '连接器甲',
  categoryId: 'section-a',
);
const _goodsB = GoodsListItem(
  id: 'goods-b',
  code: 'G-002',
  name: '连接器乙',
  categoryId: 'section-b',
  colorName: '黑色',
);
const _outOfScopeGoods = GoodsListItem(
  id: 'raw-goods',
  code: 'RAW-001',
  name: '范围外原料',
  categoryId: 'raw-root',
);

final _tree = <ProductCategoryNode>[
  ProductCategoryNode(
    id: 'finished-root',
    code: 'FINISHED',
    name: '成品',
    level: 0,
    children: [
      ProductCategoryNode(
        id: 'section-a',
        code: 'A',
        name: '分区甲',
        level: 1,
        parentId: 'finished-root',
        children: const [],
      ),
      ProductCategoryNode(
        id: 'section-b',
        code: 'B',
        name: '分区乙',
        level: 1,
        parentId: 'finished-root',
        children: const [],
      ),
      ProductCategoryNode(
        id: 'long-cat',
        code: 'LONG',
        name: '名字特别特别特别特别特别特别长的分类',
        level: 1,
        parentId: 'finished-root',
        children: const [],
      ),
    ],
  ),
  ProductCategoryNode(
    id: 'raw-root',
    code: 'RAW',
    name: '原材料',
    level: 0,
    legacyId: 2113,
    children: const [],
  ),
];
