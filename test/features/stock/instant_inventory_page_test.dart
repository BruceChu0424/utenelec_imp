// 即时库存页（2026-09-01 简化布局后；2026-09-04 顶部统一任务中心范式；
// 2026-09-11 分类/仓库改侧滑面板）：
// - 分类 = UtenFilterPickerField 字段 + 侧滑分类树面板（进页默认「全部」=
//   不过滤；零货品分类整支不出现在面板）+ 页级搜索框（名称/编号/型号/客户型号）；
// - 工具栏行尾 = 分类字段 + 仓库字段（侧滑面板查询口径：全部 / 主仓子树聚合）
//   + 含不良品仓 + 共 N 项；
// - 库存台账金额列已从页面移除（无论是否持有 goods:cost:view）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/features/stock/repositories/stock_query_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required _RecordingStockRepository stock,
    Set<String> permissions = const <String>{},
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(_InventoryApi()),
          productCategoryRepositoryProvider.overrideWithValue(
            _ProductCategoryRepo(),
          ),
          stockQueryRepositoryProvider.overrideWithValue(stock),
          currentPermissionsProvider.overrideWithValue(permissions),
        ],
        child: const MaterialApp(home: InstantInventoryPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opens unfiltered and loads the first page immediately', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    // 进页面分段未选（不过滤）但直接拉第一页，页面不再懒载。
    expect(stock.calls, 1);
    expect(stock.lastCategoryId, isNull);
    expect(stock.lastKeyword, isNull);
  });

  testWidgets(
    'category field opens the side panel; picking a node re-queries and 全部 clears',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      final field = find.byKey(const ValueKey('instant-inventory-category'));
      // 未筛选时字段显示占位「全部」。
      expect(
        find.descendant(of: field, matching: find.text('全部')),
        findsOneWidget,
      );

      // 点字段 = 拉开侧滑面板（不是下拉菜单）。
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('category-picker-tree')), findsOneWidget);
      expect(find.byKey(const Key('category-picker-all')), findsOneWidget);
      // 根分类默认展开一层，子类「成品」可见；零货品分类（未分类孤儿 0 件）整支隐藏。
      expect(find.text('成品(FINISHED)'), findsOneWidget);
      expect(find.textContaining('未分类（历史孤儿）'), findsNothing);

      // 点分类行 = 选中 + 关窗 + 带 categoryId 重查。
      await tester.tap(find.text('成品(FINISHED)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('category-picker-tree')), findsNothing);
      expect(stock.lastCategoryId, 'finished');
      expect(
        find.descendant(of: field, matching: find.text('成品')),
        findsOneWidget,
      );

      // 「全部」行 = 清空筛选。
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('category-picker-all')));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, isNull);
    },
  );

  testWidgets(
    'warehouse field opens the panel and re-queries with warehouseId',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      await tester.tap(
        find.byKey(const ValueKey('instant-inventory-warehouse')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('warehouse-picker-all')), findsOneWidget);
      // 查询口径不钻层：主仓与子仓同屏，主仓一点即选（= 子树聚合）。
      expect(
        find.byKey(const Key('warehouse-picker-entry-w1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-w1a')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('warehouse-picker-entry-w1')));
      await tester.pumpAndSettle();
      expect(stock.lastWarehouseId, 'w1');

      await tester.tap(
        find.byKey(const ValueKey('instant-inventory-warehouse')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-all')));
      await tester.pumpAndSettle();
      expect(stock.lastWarehouseId, isNull);
    },
  );

  testWidgets('search box reloads with keyword', (tester) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    await tester.enterText(
      find.byKey(const ValueKey('instant-inventory-search')),
      '插套',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(stock.lastKeyword, '插套');
  });

  testWidgets('cost column is removed for every account', (tester) async {
    final stock = _RecordingStockRepository();
    await pumpPage(
      tester,
      stock: stock,
      permissions: const <String>{Perm.goodsCostView},
    );

    final table = tester.widget<MasterDataTableView<InstantInventoryRow>>(
      find.byType(MasterDataTableView<InstantInventoryRow>),
    );
    final keys = table.columns.map((column) => column.key).toSet();
    // 数量/重量等运营事实列保留；台账金额即使持权也不出现在页面/打印。
    expect(
      keys,
      containsAll(<String>{'weight', 'qty', 'pendingQty', 'moreQty'}),
    );
    expect(keys, isNot(contains('costAmount')));
  });

  testWidgets('warehouse field, defective toggle and count share the toolbar', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    expect(find.text('仓库'), findsOneWidget);
    expect(find.text('货品分类'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '含不良品仓'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^共 \d+ 项$')), findsOneWidget);
  });
}

class _InventoryApi extends ApiClient {
  _InventoryApi() : super(Dio());

  /// 仓库字典返一主一子（测仓库侧滑面板的主/子层级与子树聚合），其余字典返空表。
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('warehouses/dict')
      ? const <Map<String, dynamic>>[
          {'id': 'w1', 'name': '成品仓库', 'code': 'C04'},
          {'id': 'w1a', 'name': '成品不良品仓', 'code': 'C0401', 'parentId': 'w1'},
        ]
      : const <Map<String, dynamic>>[];
}

class _RecordingStockRepository extends StockQueryRepository {
  _RecordingStockRepository() : super(_InventoryApi());

  int calls = 0;
  String? lastCategoryId;
  String? lastWarehouseId;
  String? lastKeyword;

  @override
  Future<PagedResult<InstantInventoryRow>> instantInventory({
    int page = 1,
    int size = 20,
    String? categoryId,
    String? warehouseId,
    bool includeDefective = true,
    String? keyword,
    String? sort,
    String? order,
  }) {
    calls++;
    lastCategoryId = categoryId;
    lastWarehouseId = warehouseId;
    lastKeyword = keyword;
    return Future.value(
      const PagedResult<InstantInventoryRow>(
        items: <InstantInventoryRow>[],
        page: 1,
        size: 20,
        total: 0,
        totalPages: 1,
      ),
    );
  }
}

class _ProductCategoryRepo implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => <ProductCategoryNode>[
    ProductCategoryNode(
      id: 'goods-root',
      code: 'G',
      name: '货品资料',
      level: 0,
      children: [
        ProductCategoryNode(
          id: 'finished',
          code: 'FINISHED',
          name: '成品',
          level: 1,
          children: const <ProductCategoryNode>[],
        ),
      ],
    ),
    ProductCategoryNode(
      id: 'orphan',
      code: 'ORPHAN',
      name: '未分类（历史孤儿）',
      level: 0,
      children: const <ProductCategoryNode>[],
    ),
  ];

  /// 带计数版树：成品 3 件、未分类孤儿 0 件——零货品分类不应出现为分段。
  @override
  Future<List<ProductCategoryNode>> treeWithGoodsCounts() async =>
      <ProductCategoryNode>[
        ProductCategoryNode(
          id: 'goods-root',
          code: 'G',
          name: '货品资料',
          level: 0,
          goodsCount: 3,
          children: [
            ProductCategoryNode(
              id: 'finished',
              code: 'FINISHED',
              name: '成品',
              level: 1,
              goodsCount: 3,
              children: const <ProductCategoryNode>[],
            ),
          ],
        ),
        ProductCategoryNode(
          id: 'orphan',
          code: 'ORPHAN',
          name: '未分类（历史孤儿）',
          level: 0,
          goodsCount: 0,
          children: const <ProductCategoryNode>[],
        ),
      ];

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');

  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDeletePreview> deletePreview(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}
