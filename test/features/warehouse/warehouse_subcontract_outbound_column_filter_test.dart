// 委外出仓工作台「表头筛选生效」冒烟断言（2026-09-16）：
// 委外商桶（suppliers/dict）回传 supplierId；任务状态派生两档（固定枚举）回传
// status；筛选后重拉回第 1 页。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_subcontract_outbound_workbench.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('subcontract outbound headers push filters to API', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _OutboundApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const <String>{
            Perm.subcontractOutboundView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WarehouseSubcontractOutboundWorkbench()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<OutboundTask>>(
      find.byKey(const Key('subcontract-outbound-task-table')),
    );
    expect(table.facets.keys, containsAll(<String>['supplierName', 'status']));
    expect(table.facets['supplierName']?.single.value, 'supplier-1');
    expect(
      table.facets['status']?.map((bucket) => bucket.value),
      containsAll(<String>['DRAFT_PICKING', 'READY_OUTBOUND']),
    );

    api.lastQuery = null;
    table.onFilterChanged('supplierName', 'supplier-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tester.widget<MasterDataTableView<OutboundTask>>(
      find.byKey(const Key('subcontract-outbound-task-table')),
    );
    refreshed.onFilterChanged('status', 'DRAFT_PICKING');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['status'], 'DRAFT_PICKING');
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(tester.takeException(), isNull);
  });
}

class _OutboundApi extends ApiClient {
  _OutboundApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('subcontract-outbound/tasks')) {
      lastQuery = query == null ? null : Map<String, dynamic>.from(query);
      return {
        'items': [
          {
            'planId': 'plan-1',
            'orderId': 'order-1',
            'orderBillNo': 'WW202609010001',
            'supplierName': '委外商甲',
            'deliverDate': '2026-09-10',
            'lineCount': 2,
            'plannedQty': 100,
            'issuedQty': 0,
            'remainingQty': 100,
            'draftId': 'draft-1',
            'draftBillNo': 'WC202609010001',
            'readyOutboundQty': 0,
            'readyLineCount': 1,
          },
        ],
        'page': 1,
        'size': 20,
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
    if (path.contains('suppliers')) {
      return const [
        {'id': 'supplier-1', 'name': '委外商甲'},
      ];
    }
    return const [];
  }
}
