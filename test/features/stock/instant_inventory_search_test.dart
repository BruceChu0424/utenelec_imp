import 'dart:async';

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
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'failed locator clears a superseded in-flight table loading state',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _InventoryApi();
      final stock = _HeldStockQueryRepository(api);

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            apiClientProvider.overrideWithValue(api),
            productCategoryRepositoryProvider.overrideWithValue(
              _ProductCategoryRepo(),
            ),
            stockQueryRepositoryProvider.overrideWithValue(stock),
          ],
          child: const MaterialApp(home: InstantInventoryPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('成品'));
      await tester.pump();
      expect(stock.calls, 1);
      expect(
        tester
            .widget<MasterDataTableView<InstantInventoryRow>>(
              find.byType(MasterDataTableView<InstantInventoryRow>),
            )
            .isLoading,
        isTrue,
      );

      final search = find.descendant(
        of: find.byKey(const ValueKey('instant-inventory-unified-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, 'BROKEN-LOCATOR');
      await tester.pump();

      // Input invalidates the held table request immediately; its stale finally
      // branch can no longer clear state, so the page must do that synchronously.
      expect(
        tester
            .widget<MasterDataTableView<InstantInventoryRow>>(
              find.byType(MasterDataTableView<InstantInventoryRow>),
            )
            .isLoading,
        isFalse,
      );

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(api.locatorCalls, 1);
      expect(find.textContaining('货品搜索失败'), findsOneWidget);
      expect(
        tester
            .widget<MasterDataTableView<InstantInventoryRow>>(
              find.byType(MasterDataTableView<InstantInventoryRow>),
            )
            .isLoading,
        isFalse,
      );

      stock.completeHeldRequest();
      await tester.pump();
      expect(
        tester
            .widget<MasterDataTableView<InstantInventoryRow>>(
              find.byType(MasterDataTableView<InstantInventoryRow>),
            )
            .isLoading,
        isFalse,
      );
    },
  );
}

class _InventoryApi extends ApiClient {
  _InventoryApi() : super(Dio());

  int locatorCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];

  @override
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    locatorCalls++;
    throw StateError('locator unavailable');
  }
}

class _HeldStockQueryRepository extends StockQueryRepository {
  _HeldStockQueryRepository(super.api);

  final _held = Completer<PagedResult<InstantInventoryRow>>();
  int calls = 0;

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
    return _held.future;
  }

  void completeHeldRequest() {
    if (_held.isCompleted) return;
    _held.complete(
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
      id: 'finished',
      code: 'FINISHED',
      name: '成品',
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
