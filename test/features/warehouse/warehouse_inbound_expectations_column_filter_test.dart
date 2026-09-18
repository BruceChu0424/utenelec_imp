// 预计到货工作台「供应商表头筛选生效」冒烟断言（2026-09-16）：
// suppliers/dict 桶回传 supplierId；筛选后重拉回第 1 页（与类型分段正交叠加）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_expectations_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

void main() {
  testWidgets('expectation supplier header filter reaches API', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ExpectationApi();

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
          home: Scaffold(body: WarehouseInboundExpectationsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<InboundExpectation>>(
      find.byKey(const Key('inbound-expectation-task-table')),
    );
    expect(
      table.facets.keys,
      containsAll(<String>['orderType', 'supplierName']),
    );
    expect(table.facets['supplierName']?.single.value, 'supplier-1');

    api.lastQuery = null;
    table.onFilterChanged('supplierName', 'supplier-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tester.widget<MasterDataTableView<InboundExpectation>>(
      find.byKey(const Key('inbound-expectation-task-table')),
    );
    expect(refreshed.filters['supplierName'], 'supplier-1');
    expect(tester.takeException(), isNull);
  });
}

class _ExpectationApi extends ApiClient {
  _ExpectationApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('expectations')) {
      if (!path.contains('count')) {
        lastQuery = query == null ? null : Map<String, dynamic>.from(query);
      }
      return {
        'items': [
          {
            'id': 'expectation-1',
            'orderType': 'PURCHASE',
            'orderId': 'o-1',
            'billNo': 'PO202609010001',
            'supplierId': 'supplier-1',
            'supplierName': '供应商甲',
            'warehouseId': null,
            'warehouseName': null,
            'expectedDate': '2026-09-10',
            'ownerEmployeeName': '采购员甲',
            'status': 'OPEN',
            'items': const <Map<String, dynamic>>[],
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path.contains('type-counts')) {
      return const {'PURCHASE': 1, 'SUBCONTRACT': 0};
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
    return const [];
  }
}
