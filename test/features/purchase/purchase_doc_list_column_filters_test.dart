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
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

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
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    MasterDataTableView<PurchaseDocListItem> tableWidget() => tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<PurchaseDocListItem>,
      ),
    );
    final table = tableWidget();
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
