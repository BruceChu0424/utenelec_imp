// 仓库单据列表「表头筛选生效」冒烟断言：
// 领料单（warehouse + department 两列）选桶后，repository.list 的既有参数
// warehouseId / departmentId 收到字典项 id，且筛选后重拉回第 1 页。
// 2026-09-16 增：转仓单「调入仓」桶（仅 TRANSFER 段有该列）回传 toWarehouseId。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_list_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('draw headers send warehouse and department filters to API', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _StockFilterApi();
    final router = GoRouter(
      initialLocation: '/stock/docs?status=draft',
      routes: [
        GoRoute(
          path: '/stock/docs',
          builder: (_, state) => StockDocListPage(
            docType: StockDocType.draw,
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

    MasterDataTableView<StockDocListItem> tableWidget() => tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<StockDocListItem>,
      ),
    );
    final table = tableWidget();
    expect(table.facets.keys, containsAll(<String>['warehouse', 'department']));
    expect(table.facets['warehouse']?.single.value, 'warehouse-1');
    // 部门树用现有展平工具（MasterNameService._flattenDeptTree）成桶：
    // 根节点与子部门都在桶里，value 为部门 UUID。
    expect(
      table.facets['department']?.map((bucket) => bucket.value),
      containsAll(<String>['dept-root', 'dept-1']),
    );
    expect(
      table.facets['department']?.singleWhere((b) => b.value == 'dept-1').label,
      '一车间',
    );

    api.lastQuery = null;
    table.onFilterChanged('warehouse', 'warehouse-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['warehouseId'], 'warehouse-1');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tableWidget();
    refreshed.onFilterChanged('department', 'dept-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['departmentId'], 'dept-1');
    expect(api.lastQuery?['warehouseId'], 'warehouse-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('transfer headers send toWarehouse filter to API', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _StockFilterApi();
    final router = GoRouter(
      initialLocation: '/stock/docs?status=draft',
      routes: [
        GoRoute(
          path: '/stock/docs',
          builder: (_, state) => StockDocListPage(
            docType: StockDocType.transfer,
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

    final table = tester.widget<MasterDataTableView<StockDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<StockDocListItem>,
      ),
    );
    // 转仓段：仓库 + 调入仓两桶（无领料车间列）。
    expect(
      table.facets.keys,
      containsAll(<String>['warehouse', 'toWarehouse']),
    );
    expect(table.facets['toWarehouse']?.single.value, 'warehouse-1');

    api.lastQuery = null;
    table.onFilterChanged('toWarehouse', 'warehouse-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['toWarehouseId'], 'warehouse-1');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tester.widget<MasterDataTableView<StockDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<StockDocListItem>,
      ),
    );
    expect(refreshed.filters['toWarehouse'], 'warehouse-1');
    expect(tester.takeException(), isNull);
  });
}

class _StockFilterApi extends ApiClient {
  _StockFilterApi() : super(Dio());

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
          'id': 'draw-1',
          'billNo': 'LL26080001',
          'billDate': '2026-08-31',
          'warehouseId': 'warehouse-1',
          'departmentId': 'dept-1',
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
    if (path.contains('warehouses')) {
      return const [
        {'id': 'warehouse-1', 'name': '一号仓'},
      ];
    }
    if (path.contains('departments')) {
      // 部门树：子部门应被展平为桶。
      return const [
        {
          'id': 'dept-root',
          'name': '生产部',
          'children': [
            {'id': 'dept-1', 'name': '一车间'},
          ],
        },
      ];
    }
    return const [];
  }
}
