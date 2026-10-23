// 即时库存使用全宽表格；分类筛选在按需打开的确认面板中进行。
// 搜索默认跨分类平铺，清空后恢复原浏览分类。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
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
    Size size = const Size(1600, 1000),
    _ProductCategoryRepo? categories,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(_InventoryApi()),
          productCategoryRepositoryProvider.overrideWithValue(
            categories ?? _ProductCategoryRepo(),
          ),
          stockQueryRepositoryProvider.overrideWithValue(stock),
          currentPermissionsProvider.overrideWithValue(permissions),
        ],
        child: const MaterialApp(home: InstantInventoryPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapInventoryHeader(WidgetTester tester, Key key) async {
    // Picker close and table reload may collapse the linked header. Restore
    // its visible position before the next real interaction with the filter.
    await tester.ensureVisible(find.byKey(key, skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'inventory actual row retains the smallest stored quantity with its unit',
    (tester) async {
      final row = InstantInventoryRow.fromJson({
        'goodsId': 'small-quantity',
        'name': '四位库存',
        'unitName': '个',
        'qty': 0.0001,
        'pendingQty': 0.0001,
        'pendingStockInQty': 0.0001,
        'moreQty': 0.0001,
      });
      await pumpPage(tester, stock: _RecordingStockRepository(rows: [row]));
      final table = tester.widget<MasterDataTableView<InstantInventoryRow>>(
        find.byType(MasterDataTableView<InstantInventoryRow>),
      );
      for (final key in ['qty', 'pendingQty', 'pendingStockInQty', 'moreQty']) {
        expect(
          table.columns.singleWhere((c) => c.key == key).value(row),
          '0.0001 个',
          reason: key,
        );
      }
      expect(find.text('0.0001 个'), findsWidgets);
      expect(find.text('0 个'), findsNothing);
    },
  );

  testWidgets(
    'full width inventory loads immediately without a category sidebar',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);
      expect(stock.calls, 1);
      expect(stock.lastCategoryId, isNull);
      expect(stock.lastKeyword, isNull);
      expect(find.byType(UtenSplitView), findsNothing);
      expect(
        find.byKey(const Key('instant-inventory-category-tree')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('instant-inventory-category')),
        findsOneWidget,
      );
      expect(_categoryText('原材料'), findsNothing);
    },
  );

  testWidgets(
    'category panel stages the selection until confirmation and cancel is a no-op',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);
      await tapInventoryHeader(tester, const Key('instant-inventory-category'));
      expect(_categoryText('原材料'), findsOneWidget);
      await tester.tap(_categoryText('原材料'));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, isNull);
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'raw');
      await tapInventoryHeader(tester, const Key('instant-inventory-category'));
      await tester.tap(_categoryText('成品'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'raw');
    },
  );

  // V595 线边仓(车间内部直送的料架)退出即时库存：页面进来默认不要线边仓，
  // 只有用户自己点开「含线边仓」才把它算回来——默认值翻了就是业务口径回归。
  testWidgets('line-side stock stays out of instant inventory until asked', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    expect(stock.lastIncludeLineSide, isFalse);
    // ADR-146: 不良品仓同样默认不计入(只看可用良品)，打开「含不良品仓」才另列不良品。
    expect(stock.lastIncludeDefective, isFalse);

    // 换仓库口径(主仓子树聚合)不得顺手把线边仓带回来。
    await tapInventoryHeader(tester, const Key('instant-inventory-warehouse'));
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-w1')));
    await tester.pumpAndSettle();
    expect(stock.lastWarehouseId, isNull);
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    expect(stock.lastWarehouseId, 'w1');
    expect(stock.lastIncludeLineSide, isFalse);

    // 回到「全部」后点开关 → 显式要线边仓才带 true，再点一次收回。
    await tapInventoryHeader(tester, const Key('instant-inventory-warehouse'));
    await tester.tap(find.byKey(const Key('warehouse-picker-all')));
    await tester.pumpAndSettle();
    expect(stock.lastWarehouseId, 'w1');
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    await tapInventoryHeader(tester, const Key('instant-inventory-line-side'));
    expect(stock.lastIncludeLineSide, isTrue);

    await tapInventoryHeader(tester, const Key('instant-inventory-line-side'));
    expect(stock.lastIncludeLineSide, isFalse);
  });

  testWidgets(
    'warehouse field opens the panel and re-queries with warehouseId',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);

      await tapInventoryHeader(
        tester,
        const Key('instant-inventory-warehouse'),
      );
      expect(find.byKey(const Key('warehouse-picker-all')), findsOneWidget);
      // 查询口径不钻层：主仓与子仓同屏，主仓选中并确认后聚合子树。
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
      expect(stock.lastWarehouseId, isNull);
      await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
      await tester.pumpAndSettle();
      expect(stock.lastWarehouseId, 'w1');

      await tapInventoryHeader(
        tester,
        const Key('instant-inventory-warehouse'),
      );
      await tester.tap(find.byKey(const Key('warehouse-picker-all')));
      await tester.pumpAndSettle();
      expect(stock.lastWarehouseId, 'w1');
      await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
      await tester.pumpAndSettle();
      expect(stock.lastWarehouseId, isNull);
    },
  );

  testWidgets(
    'search remains global and clearing restores the browsing category',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock);
      await tapInventoryHeader(tester, const Key('instant-inventory-category'));
      await tester.tap(_categoryText('原材料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      await tester.enterText(_searchEditable(), 'HV-001');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, isNull);
      expect(stock.lastKeyword, 'HV-001');
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams['keyword'], 'HV-001');
      expect(export.queryParams, isNot(contains('categoryId')));
      await tester.tap(_clearSearch());
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'raw');
      expect(stock.lastKeyword, isNull);
    },
  );

  testWidgets(
    'compact and large text layouts retain the full width table and category picker',
    (tester) async {
      final stock = _RecordingStockRepository();
      await pumpPage(tester, stock: stock, size: const Size(375, 812));
      expect(find.byType(UtenSplitView), findsNothing);
      expect(
        find.byType(MasterDataTableView<InstantInventoryRow>),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tapInventoryHeader(tester, const Key('instant-inventory-category'));
      await tester.tap(_categoryText('原材料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(stock.lastCategoryId, 'raw');
      tester.view.physicalSize = const Size(812, 375);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getSize(find.byType(MasterDataTableView<InstantInventoryRow>))
            .height,
        greaterThan(0),
      );
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

  testWidgets('warehouse field, defective toggle and count share the toolbar', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    expect(find.text('仓库'), findsOneWidget);
    expect(find.byKey(const Key('instant-inventory-category')), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '含不良品仓'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^共 \d+ 项$')), findsOneWidget);
  });

  // 2026-09-16 颜色/物料系列/单位表头筛选：选桶 → repository 收到对应参数。
  testWidgets('color, series and unit header filters re-query the API', (
    tester,
  ) async {
    final stock = _RecordingStockRepository();
    await pumpPage(tester, stock: stock);

    MasterDataTableView<InstantInventoryRow> table() =>
        tester.widget<MasterDataTableView<InstantInventoryRow>>(
          find.byType(MasterDataTableView<InstantInventoryRow>),
        );

    table().onFilterChanged('color', 'color-1');
    await tester.pumpAndSettle();
    expect(stock.lastColorId, 'color-1');

    table().onFilterChanged('series', 'X系列');
    await tester.pumpAndSettle();
    expect(stock.lastSeries, 'X系列');

    table().onFilterChanged('unit', 'unit-1');
    await tester.pumpAndSettle();
    expect(stock.lastUnitId, 'unit-1');

    // 分类面板确认后改变范围，保留既有仓库和表头筛选。
    await tapInventoryHeader(tester, const Key('instant-inventory-warehouse'));
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    await tapInventoryHeader(tester, const Key('instant-inventory-category'));
    await tester.tap(_categoryText('成品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
    expect(stock.lastCategoryId, 'finished');
    expect(stock.lastWarehouseId, 'w1');
    expect(stock.lastColorId, 'color-1');
    expect(stock.lastSeries, 'X系列');
    expect(stock.lastUnitId, 'unit-1');
    expect(stock.lastIncludeLineSide, isFalse);
    expect(stock.lastIncludeDefective, isFalse);

    // 取消筛选（选「所有」）→ 参数回到 null。
    table().onFilterChanged('unit', null);
    await tester.pumpAndSettle();
    expect(stock.lastUnitId, isNull);
  });

  // ADR-135：库存重量紧跟库存数量；估算「≈」、有库存没称过「未称」、本行无库存「—」，
  // 绝不把未知显示成 0；工具条「重量单位」切换显示单位，导出跟着带固定单位与表头筛选。
  testWidgets('weight follows quantity, marks estimates and unknowns, and '
      'the display unit drives cells and export', (tester) async {
    const rows = <InstantInventoryRow>[
      InstantInventoryRow(
        goodsId: 'g1',
        name: '螺丝',
        qty: 5000,
        weight: 11.55,
        weightEstimated: true,
      ),
      InstantInventoryRow(goodsId: 'g2', name: '垫片', qty: 20),
      InstantInventoryRow(goodsId: 'g3', name: '待检件', qty: 0),
    ];
    final stock = _RecordingStockRepository(rows: rows);
    await pumpPage(tester, stock: stock);

    MasterDataTableView<InstantInventoryRow> table() =>
        tester.widget<MasterDataTableView<InstantInventoryRow>>(
          find.byType(MasterDataTableView<InstantInventoryRow>),
        );
    MasterColumnDef<InstantInventoryRow> weightColumn() =>
        table().columns.firstWhere((c) => c.key == 'weight');

    final keys = [for (final c in table().columns) c.key];
    expect(keys.indexOf('weight'), keys.indexOf('qty') + 1);
    expect(weightColumn().type, 'weight');
    expect(weightColumn().value(rows[0]), '≈11.55 kg');
    expect(weightColumn().value(rows[1]), '未称');
    expect(weightColumn().value(rows[2]), '—');

    UtenExportButton exportButton() =>
        tester.widget<UtenExportButton>(find.byType(UtenExportButton));
    // 「自动」显示单位导出按千克 (文件数值列不混单位)。
    expect(exportButton().queryParams['weightUnit'], 'KG');

    await tester.tap(find.byKey(const ValueKey('weight-display-unit-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weight-unit-option-克')).last);
    await tester.pumpAndSettle();

    expect(weightColumn().value(rows[0]), '≈11,550 g');
    expect(exportButton().queryParams['weightUnit'], 'G');

    // 表头筛选同样进入导出口径。
    table().onFilterChanged('color', 'color-1');
    await tester.pumpAndSettle();
    expect(exportButton().queryParams['colorId'], 'color-1');
    // 偏好防抖推送计时器走完再结束 (未登录不推服务端)。
    await tester.pump(const Duration(seconds: 1));
  });
}

Finder _searchBar() {
  final drawer = find.byType(Drawer);
  final search = find.byKey(const Key('instant-inventory-search'));
  return drawer.evaluate().isEmpty
      ? search
      : find.descendant(of: drawer, matching: search);
}

Finder _searchEditable() =>
    find.descendant(of: _searchBar(), matching: find.byType(EditableText));

Finder _clearSearch() => find.descendant(
  of: _searchBar(),
  matching: find.byIcon(Icons.close_rounded),
);

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
          {
            'id': 'w1a',
            'name': '成品不良品仓',
            'code': 'C0401',
            'parentId': 'w1',
            'selectableForNew': true,
          },
        ]
      : const <Map<String, dynamic>>[];
}

class _RecordingStockRepository extends StockQueryRepository {
  _RecordingStockRepository({this.rows = const <InstantInventoryRow>[]})
    : super(_InventoryApi());

  final List<InstantInventoryRow> rows;

  int calls = 0;
  String? lastCategoryId;
  String? lastWarehouseId;
  String? lastKeyword;
  String? lastOwningWarehouse;
  String? lastColorId;
  String? lastSeries;
  String? lastUnitId;
  bool? lastIncludeDefective;
  bool? lastIncludeLineSide;

  @override
  Future<PagedResult<InstantInventoryRow>> instantInventory({
    int page = 1,
    int size = 20,
    String? categoryId,
    String? warehouseId,
    bool includeDefective = false,
    bool includeLineSide = false,
    bool warehouseRelatedOnly = false,
    String? keyword,
    String? owningWarehouse,
    bool owningWarehouseNull = false,
    String? colorId,
    String? series,
    String? unitId,
    String? sort,
    String? order,
    String? attention,
    bool includeRelated = false,
  }) {
    calls++;
    lastCategoryId = categoryId;
    lastWarehouseId = warehouseId;
    lastIncludeDefective = includeDefective;
    lastIncludeLineSide = includeLineSide;
    lastKeyword = keyword;
    lastOwningWarehouse = owningWarehouse;
    lastColorId = colorId;
    lastSeries = series;
    lastUnitId = unitId;
    return Future.value(
      PagedResult<InstantInventoryRow>(
        items: rows,
        page: 1,
        size: 20,
        total: rows.length,
        totalPages: 1,
      ),
    );
  }
}

class _ProductCategoryRepo implements ProductCategoryRepository {
  @override
  Future<CategoryPrefixAvailability> prefixAvailability(
    String prefix, {
    String? categoryId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> tree() => treeWithGoodsCounts();

  /// The picker retains the existing category hierarchy and hides empty roots.
  @override
  Future<List<ProductCategoryNode>> treeWithGoodsCounts() async {
    return <ProductCategoryNode>[
      ProductCategoryNode(
        id: 'goods-root',
        code: 'G',
        name: '货品资料',
        level: 0,
        goodsCount: 4,
        children: [
          ProductCategoryNode(
            id: 'finished',
            code: 'FINISHED',
            name: '成品',
            level: 1,
            goodsCount: 3,
            children: [
              ProductCategoryNode(
                id: 'connectors',
                code: 'CONNECTORS',
                name: '连接器',
                level: 2,
                goodsCount: 3,
                children: [
                  ProductCategoryNode(
                    id: 'socket',
                    code: 'SOCKET',
                    name: '插套分类',
                    level: 3,
                    goodsCount: 3,
                    children: const <ProductCategoryNode>[],
                  ),
                ],
              ),
            ],
          ),
          ProductCategoryNode(
            id: 'raw',
            code: 'RAW',
            name: '原材料',
            level: 1,
            goodsCount: 1,
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
  }

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

Finder _categoryText(String label) => find.descendant(
  of: find.byType(UtenCategoryTreeView<ProductCategoryNode>),
  matching: find.text(label),
);
