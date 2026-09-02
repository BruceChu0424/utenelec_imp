// 即时库存页（2026-09-01 简化布局后）：
// - 分类 = UtenFilterToolbar 大类分段（进页不选 = 不过滤，点段才过滤）；
// - 工具栏行尾 = 仓库下拉 + 含不良品仓 + 共 N 项；
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
    'category segments filter by category id and 全部 returns to unfiltered',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      final segments = find.byKey(
        const ValueKey('instant-inventory-category-segments'),
      );

      // 一级分类（成品）与无子级根（未分类孤儿）都暴露为分段。
      expect(
        find.descendant(of: segments, matching: find.text('成品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: segments, matching: find.text('未分类（历史孤儿）')),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(of: segments, matching: find.text('成品')),
      );
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'finished');

      await tester.tap(
        find.descendant(of: segments, matching: find.text('全部')),
      );
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, isNull);
    },
  );

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

  testWidgets(
    'warehouse dropdown, defective toggle and count share the toolbar',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      expect(find.text('仓库'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, '含不良品仓'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^共 \d+ 项$')), findsOneWidget);
    },
  );
}

class _InventoryApi extends ApiClient {
  _InventoryApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];
}

class _RecordingStockRepository extends StockQueryRepository {
  _RecordingStockRepository() : super(_InventoryApi());

  int calls = 0;
  String? lastCategoryId;
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
