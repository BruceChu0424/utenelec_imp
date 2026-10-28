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
import 'package:uten_imp/features/warehouse/widgets/warehouse_stock_doc_segment.dart';
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

    MasterDataTableView<Object> tableWidget() => tester.widget(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView<Object>),
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
    expect(tableWidget().serverColumnSearch, isTrue);
    expect(
      tableWidget().columns
          .singleWhere((column) => column.key == 'billDate')
          .columnSearchEnabled,
      isTrue,
    );
    tableWidget().onFilterChanged('search.warehouse', '原料%_');
    await tester.pumpAndSettle();
    tableWidget().onFilterChanged('search.department', '一车间');
    await tester.pumpAndSettle();
    tableWidget().onFilterChanged('search.billDate', '2026-08-01..2026-08-31');
    await tester.pumpAndSettle();
    expect(api.lastListQuery?['search.warehouse'], '原料%_');
    expect(api.lastListQuery?['search.department'], '一车间');
    expect(api.lastListQuery?['search.billDate'], '2026-08-01..2026-08-31');
    expect(api.lastListQuery?['warehouseId'], 'warehouse-1');
    expect(api.lastListQuery?['departmentId'], 'dept-1');

    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-doc-issue-DRAW')), findsNothing);
    expect(tableWidget().facets['issueStatus']?.map((bucket) => bucket.value), [
      '0',
      '1',
    ]);
    tableWidget().onFilterChanged('issueStatus', '1');
    await tester.pumpAndSettle();
    expect(api.lastListQuery?['status'], 1);
    expect(api.lastListQuery?['issueStatus'], 1);
    expect(api.lastListQuery?['page'], 1);
    expect(api.lastListQuery?['warehouseId'], 'warehouse-1');
    expect(tableWidget().filters['issueStatus'], '1');
    tableWidget().onFilterChanged('issueStatus', '2');
    await tester.pumpAndSettle();
    expect(api.lastListQuery?['view'], 'ACTIVE');
    expect(api.lastListQuery?.containsKey('issueStatus'), isFalse);
    expect(tableWidget().filters['issueStatus'], isNull);
    tableWidget().onFilterChanged('issueStatus', null);
    await tester.pumpAndSettle();
    expect(api.lastListQuery?.containsKey('issueStatus'), isFalse);

    await tester.tap(find.text('草稿').first);
    await tester.pumpAndSettle();
    expect(tableWidget().facets.containsKey('issueStatus'), isFalse);
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

    final table = tester.widget<MasterDataTableView<Object>>(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView<Object>),
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

    final refreshed = tester.widget<MasterDataTableView<Object>>(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView<Object>),
    );
    expect(refreshed.filters['toWarehouse'], 'warehouse-1');
    await tester.tap(find.text('历史单据'));
    await tester.pumpAndSettle();
    MasterDataTableView<Object> current() => tester.widget(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView<Object>),
    );
    final dateFrom = api.lastListQuery?['dateFrom'];
    current().onFilterChanged('status', '-1');
    await tester.pumpAndSettle();
    expect(api.lastListQuery?['status'], -1);
    expect(api.lastListQuery?['originScope'], 'CURRENT');
    expect(api.lastListQuery?['dateFrom'], dateFrom);
    current().onFilterChanged('status', 'LEGACY');
    await tester.pumpAndSettle();
    expect(api.lastListQuery?['originScope'], 'LEGACY');
    expect(api.lastListQuery?.containsKey('status'), isFalse);
    current().onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(api.lastListQuery?['originScope'], 'ALL');
    expect(api.lastListQuery?['dateFrom'], dateFrom);
    expect(
      StockDocListItem.fromJson({
        'id': 'provenance-only',
        'legacyImported': true,
        'status': 0,
      }).legacyImported,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'task segment reference choices and typed searches share the full server query',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance(),
          api = _StockFilterApi();
      final router = GoRouter(
        initialLocation: '/warehouse/task-test',
        routes: [
          GoRoute(
            path: '/warehouse/task-test',
            builder: (_, _) => const Scaffold(
              body: WarehouseStockDocSegment(docType: StockDocType.draw),
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
      await tester.tap(find.text('草稿'));
      await tester.pumpAndSettle();
      MasterDataTableView<Object> table() => tester.widget(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<Object>,
        ),
      );
      expect(
        table().facets.keys,
        containsAll(['warehouse', 'department', 'status']),
      );
      table().onFilterChanged('warehouse', 'warehouse-1');
      await tester.pumpAndSettle();
      table().onFilterChanged('department', 'dept-1');
      await tester.pumpAndSettle();
      table().onFilterChanged('search.billNo', 'LL%_');
      await tester.pumpAndSettle();
      table().onFilterChanged('search.billDate', '2026-08');
      await tester.pumpAndSettle();
      expect(api.lastListQuery?['page'], 1);
      expect(api.lastListQuery?['warehouseId'], 'warehouse-1');
      expect(api.lastListQuery?['departmentId'], 'dept-1');
      expect(api.lastListQuery?['search.billNo'], 'LL%_');
      expect(api.lastListQuery?['search.billDate'], '2026-08');
      expect(api.lastListQuery?['status'], 0);
      expect(tester.takeException(), isNull);
    },
  );
}

class _StockFilterApi extends ApiClient {
  _StockFilterApi() : super(Dio());

  Map<String, dynamic>? lastQuery;
  Map<String, dynamic>? lastListQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    if (path == '/stock/docs') lastListQuery = lastQuery;
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
