// 产成品入库任务「表头筛选生效」冒烟断言（2026-09-16）：
// 任务步骤固定枚举桶回传 taskStage；仓库桶（warehouses/dict）回传 warehouseId；
// 筛选后重拉回第 1 页。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/widgets/production_finished_inbound_tasks_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('finished inbound task headers push filters to API', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _FinishedTaskApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const <String>{
            Perm.stockDocView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ProductionFinishedInboundTasksView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<ProductionFinishedInboundTask>>(
          find.byKey(const Key('production-finished-inbound-task-table')),
        );
    expect(
      table.facets.keys,
      containsAll(<String>['taskStage', 'warehouseName']),
    );
    expect(
      table.facets['taskStage']?.map((bucket) => bucket.value),
      containsAll(<String>['ARRIVAL_REGISTRATION', 'FINAL_COUNT']),
    );
    expect(table.facets['warehouseName']?.single.value, 'warehouse-1');

    api.lastQuery = null;
    table.onFilterChanged('taskStage', 'FINAL_COUNT');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['taskStage'], 'FINAL_COUNT');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tester
        .widget<MasterDataTableView<ProductionFinishedInboundTask>>(
          find.byKey(const Key('production-finished-inbound-task-table')),
        );
    refreshed.onFilterChanged('warehouseName', 'warehouse-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['warehouseId'], 'warehouse-1');
    expect(api.lastQuery?['taskStage'], 'FINAL_COUNT');
    expect(tester.takeException(), isNull);
  });
}

class _FinishedTaskApi extends ApiClient {
  _FinishedTaskApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('production-finished-in')) {
      lastQuery = query == null ? null : Map<String, dynamic>.from(query);
      return {
        'items': [
          {
            'taskStage': 'FINAL_COUNT',
            'taskId': 'task-1',
            'reportId': null,
            'documentId': 'doc-1',
            'documentNo': 'CP202609010001',
            'documentDate': '2026-09-01',
            'warehouseId': 'warehouse-1',
            'warehouseName': '一号仓',
            'planNo': 'PP001',
            'reportNos': 'RB001',
            'goodsSummary': '面板 (V51 · 白)',
            'lineCount': 2,
            'pendingQty': 12,
            'createdAt': '2026-09-01T02:00:00Z',
            'residualTask': false,
          },
        ],
        'page': 1,
        'size': 40,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{'items': <Map<String, dynamic>>[]};
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
    return const [];
  }
}
