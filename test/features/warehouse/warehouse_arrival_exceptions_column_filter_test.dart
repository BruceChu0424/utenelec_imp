// 到货异常任务中心「表头筛选生效」冒烟断言（2026-09-16）：
// 供应商/仓库桶（suppliers/warehouses dict）回传 supplierId/warehouseId；
// 状态固定枚举桶回传 status；筛选后重拉回第 1 页。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_arrival_exceptions_view.dart';

void main() {
  testWidgets('arrival exception headers push filters to API', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalExceptionApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const <String>{
            Perm.warehouseInboundView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WarehouseArrivalExceptionsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<ProcurementArrivalException>>(
          find.byKey(const Key('warehouse-arrival-exception-task-table')),
        );
    expect(
      table.facets.keys,
      containsAll(<String>['supplierName', 'warehouseName', 'status']),
    );
    expect(table.facets['supplierName']?.single.value, 'supplier-1');
    expect(table.facets['warehouseName']?.single.value, 'warehouse-1');
    expect(
      table.facets['status']?.map((bucket) => bucket.value),
      containsAll(<String>['PENDING_FINANCE', 'RECEIPT_ADJUSTED', 'CLOSED']),
    );

    api.lastQuery = null;
    table.onFilterChanged('supplierName', 'supplier-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(api.lastQuery?['page'], 1);

    var refreshed = tester
        .widget<MasterDataTableView<ProcurementArrivalException>>(
          find.byKey(const Key('warehouse-arrival-exception-task-table')),
        );
    refreshed.onFilterChanged('warehouseName', 'warehouse-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['warehouseId'], 'warehouse-1');
    expect(api.lastQuery?['supplierId'], 'supplier-1');

    refreshed = tester.widget<MasterDataTableView<ProcurementArrivalException>>(
      find.byKey(const Key('warehouse-arrival-exception-task-table')),
    );
    refreshed.onFilterChanged('status', 'PENDING_FINANCE');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['status'], 'PENDING_FINANCE');
    final afterStatus = tester
        .widget<MasterDataTableView<ProcurementArrivalException>>(
          find.byKey(const Key('warehouse-arrival-exception-task-table')),
        );
    expect(afterStatus.filters['status'], 'PENDING_FINANCE');
    expect(tester.takeException(), isNull);
  });
}

class _ArrivalExceptionApi extends ApiClient {
  _ArrivalExceptionApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('arrival-exceptions')) {
      lastQuery = query == null ? null : Map<String, dynamic>.from(query);
      return const {
        'items': [
          {
            'id': 'exc-1',
            'orderType': 'PURCHASE',
            'receiptId': 'r-1',
            'receiptItemId': 'ri-1',
            'receiptBillNo': 'SH202609010001',
            'orderId': 'o-1',
            'orderItemId': 'oi-1',
            'orderBillNo': 'PO202609010001',
            'supplierId': 'supplier-1',
            'supplierName': '供应商甲',
            'warehouseId': 'warehouse-1',
            'warehouseName': '一号仓',
            'goodsCode': 'G1',
            'goodsName': '面板',
            'declaredQty': 10,
            'approvedRemainingQty': 8,
            'requestedExcessQty': 2,
            'acceptedQty': 8,
            'unacceptedQty': 2,
            'status': 'PENDING_FINANCE',
            'decision': null,
            'version': 1,
            'detectedAt': '2026-09-01T02:00:00Z',
            'canStockIn': false,
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
