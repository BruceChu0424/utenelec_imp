// 采购单据列表「表头筛选生效」冒烟断言：
// 收货单（supplier + warehouse 两列）选桶后，repository.list 的既有参数
// supplierId / warehouseId 收到字典项 id，且筛选后重拉回第 1 页。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/drafts/form_draft_category_table.dart';

void main() {
  testWidgets('receipt headers send supplier and warehouse filters to API', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _PurchaseFilterApi();
    final router = GoRouter(
      initialLocation: '/purchase/receipts?status=draft',
      routes: [
        GoRoute(
          path: '/purchase/receipts',
          builder: (_, state) => PurchaseDocListPage(
            docType: PurchaseDocType.receipt,
            initialStatus: state.uri.queryParameters['status'],
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.purchaseReceiptView,
            Perm.purchaseReceiptPriceView,
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 草稿段经 FormDraftCategoryTable 渲染合并表，双形态 finder 同款口径。
    MasterDataTableView<dynamic> tableWidget() => tester.widget(
      find.byWidgetPredicate(
        (widget) =>
            widget is MasterDataTableView<PurchaseDocListItem> ||
            widget
                is MasterDataTableView<
                  FormDraftCategoryRow<PurchaseDocListItem>
                >,
      ),
    );
    final table = tableWidget();
    final amount =
        (table
                as MasterDataTableView<
                  FormDraftCategoryRow<PurchaseDocListItem>
                >)
            .columns
            .singleWhere((c) => c.key == 'total');
    for (final raw in ['0.0001', '99999999999999.9999']) {
      final row = PurchaseDocListItem.fromJson({
        'id': 'exact',
        'totalLocal': double.parse(raw),
        'totalLocalExact': raw,
      });
      expect(
        amount.value(FormDraftCategoryRow<PurchaseDocListItem>(record: row)),
        '$raw 元',
      );
    }
    final masked = PurchaseDocListItem.fromJson({
      'id': 'masked',
      'priceMasked': true,
      'totalLocal': 1,
      'totalLocalExact': '99999999999999.9999',
    });
    expect(
      amount.value(FormDraftCategoryRow<PurchaseDocListItem>(record: masked)),
      '***',
    );
    expect(
      PurchaseDocListItem.fromJson({
        'id': 'unknown',
        'totalLocal': null,
        'totalLocalExact': '99999999999999.9999',
      }).totalLocalText,
      isNull,
    );
    expect(table.facets.keys, containsAll(<String>['supplier', 'warehouse']));
    expect(table.facets['supplier']?.single.value, 'supplier-1');
    expect(table.facets['warehouse']?.single.value, 'warehouse-1');

    api.lastQuery = null;
    table.onFilterChanged('supplier', 'supplier-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tableWidget();
    refreshed.onFilterChanged('warehouse', 'warehouse-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['warehouseId'], 'warehouse-1');
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    final searchable = tableWidget();
    expect(searchable.serverColumnSearch, isTrue);
    searchable.onFilterChanged('search.billNo', 'CD2026');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['search.billNo'], 'CD2026');
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(api.lastQuery?['warehouseId'], 'warehouse-1');
    expect(tester.takeException(), isNull);
  });
}

class _PurchaseFilterApi extends ApiClient {
  _PurchaseFilterApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    return {
      'items': [
        {
          'id': 'receipt-1',
          'billNo': 'SH26080001',
          'billDate': '2026-08-31',
          'supplierId': 'supplier-1',
          'warehouseId': 'warehouse-1',
          'status': 0,
        },
      ],
      'page': 1,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('suppliers')) {
      return const [
        {'id': 'supplier-1', 'name': '供应商甲'},
      ];
    }
    if (path.contains('warehouses')) {
      return const [
        {'id': 'warehouse-1', 'name': '一号仓'},
      ];
    }
    return const [];
  }
}
