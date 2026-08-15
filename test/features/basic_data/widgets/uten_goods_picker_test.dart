import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
      tester
          .widget<TextField>(find.byKey(const Key('uten-goods-picker-search')))
          .decoration
          ?.hintText,
      '搜索分类/货品名称或编号',
    );

    await tester.enterText(
      find.byKey(const Key('uten-goods-picker-search')),
      'G-',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(goodsRepository.searchQueries, ['G-']);
    expect(goodsRepository.searchCategoryIdQueries, ['G-']);
    // sellable scope 已过滤原材料根；后端收到的是可见森林根，不是前端取前 20 条后再过滤。
    expect(goodsRepository.searchRootScopes.single, {'finished-root'});
    expect(find.text('连接器甲（G-001）'), findsOneWidget);
    expect(find.text('连接器乙（G-002）'), findsOneWidget);

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.showSearch, isFalse);
    expect(tree.visibleFilterIds, {'finished-root', 'section-a', 'section-b'});
    expect(tree.selectedIds, {'section-a'});

    // 搜索期间改点另一个命中分类，关键词保留，并切换为该分类内搜索。
    await tester.tap(find.text('分区乙（B）'));
    await tester.pumpAndSettle();
    expect(goodsRepository.listCalls.last, ('section-b', 'G-'));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('uten-goods-picker-search')))
          .controller
          ?.text,
      'G-',
    );

    // 清除只退出搜索，保留当前位置并恢复分类列表。
    await tester.tap(find.byKey(const Key('uten-goods-picker-search-clear')));
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
    await tester.enterText(
      find.byKey(const Key('uten-goods-picker-search')),
      'RAW-001',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(find.text('搜索货品失败，请稍后重试'), findsWidgets);
    expect(find.text('范围外原料（RAW-001）'), findsNothing);
  });

  testWidgets('纯分类命中后点分类不把分类词当成货品关键词', (tester) async {
    final goodsRepository = _FakeGoodsRepository(categoryOnlyQuery: '分区');
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-goods-picker-search')),
      '分区',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(goodsRepository.searchQueries, ['分区']);
    expect(goodsRepository.searchCategoryIdQueries, ['分区']);
    expect(goodsRepository.listCalls.last, ('section-a', null));

    await tester.tap(find.text('分区乙（B）'));
    await tester.pumpAndSettle();

    expect(goodsRepository.listCalls.last, ('section-b', null));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('uten-goods-picker-search')))
          .controller
          ?.text,
      '分区',
      reason: '分类词仍应保留在统一搜索框，只是不应下推为货品字段过滤',
    );
  });

  testWidgets('多页搜索会汇总后续页分类用于完整展开', (tester) async {
    final goodsRepository = _FakeGoodsRepository(splitAcrossPages: true);
    await _pumpPicker(tester, goodsRepository);

    await tester.tap(find.byKey(const Key('open-goods-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-goods-picker-search')),
      'G-',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.visibleFilterIds, {'finished-root', 'section-a', 'section-b'});
    expect(goodsRepository.searchPages, [1]);
    expect(goodsRepository.searchCategoryIdQueries, ['G-']);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded).last);
    await tester.pumpAndSettle();

    final pageTwoTree = tester
        .widget<UtenCategoryTreeView<ProductCategoryNode>>(
          find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        );
    expect(pageTwoTree.visibleFilterIds, {
      'finished-root',
      'section-a',
      'section-b',
    });
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
    await tester.enterText(
      find.byKey(const Key('uten-goods-picker-search')),
      '旧关键词',
    );
    await tester.pump(const Duration(milliseconds: 301));
    expect(goodsRepository.searchQueries, ['旧关键词']);

    await tester.enterText(
      find.byKey(const Key('uten-goods-picker-search')),
      'G-',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('连接器甲（G-001）'), findsOneWidget);

    goodsRepository.completeDelayedSearch(const [_outOfScopeGoods]);
    await tester.pumpAndSettle();

    expect(find.text('连接器甲（G-001）'), findsOneWidget);
    expect(find.text('范围外原料（RAW-001）'), findsNothing);
    expect(find.text('搜索货品失败，请稍后重试'), findsNothing);
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

Finder _widePickerSheet() => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == 720 &&
      widget.height == double.infinity,
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

class _FakeCategoryRepository extends Fake
    implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => _tree;
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
