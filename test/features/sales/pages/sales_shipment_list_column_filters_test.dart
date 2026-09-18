// 销售出货单列表「表头筛选生效」冒烟断言（出货段；订货段的仓库/币种无服务端
// 参数不做）：客户桶（clients/dict）回传 clientId；财务审核/仓库作业固定枚举
// 桶回传 financeAudit / warehouseWorkStatus；筛选后重拉回第 1 页。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('shipment headers send client and enum filters to API', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ShipmentFilterApi();
    final router = GoRouter(
      initialLocation: '/sales/shipments?status=draft',
      routes: [
        GoRoute(
          path: '/sales/shipments',
          builder: (_, state) => SalesDocListPage(
            docType: SalesDocType.shipment,
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
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    MasterDataTableView<SalesDocListItem> tableWidget() => tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SalesDocListItem>,
      ),
    );
    final table = tableWidget();
    expect(
      table.facets.keys,
      containsAll(<String>[
        'status',
        'client',
        'financeAudit',
        'warehouseWorkStatus',
      ]),
    );
    expect(table.facets['client']?.single.value, 'client-1');
    expect(
      table.facets['financeAudit']?.map((bucket) => bucket.value),
      containsAll(<String>['0', '1']),
    );
    expect(
      table.facets['warehouseWorkStatus']?.map((bucket) => bucket.value),
      containsAll(<String>['PENDING_PICK', 'SHIPPED']),
    );

    api.lastQuery = null;
    table.onFilterChanged('client', 'client-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['clientId'], 'client-1');
    expect(api.lastQuery?['page'], 1);

    var refreshed = tableWidget();
    refreshed.onFilterChanged('financeAudit', '1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['financeAudit'], 1);
    expect(api.lastQuery?['clientId'], 'client-1');

    refreshed = tableWidget();
    refreshed.onFilterChanged('warehouseWorkStatus', 'PENDING_PICK');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['warehouseWorkStatus'], 'PENDING_PICK');
    expect(api.lastQuery?['financeAudit'], 1);
    expect(tester.takeException(), isNull);
  });
}

class _ShipmentFilterApi extends ApiClient {
  _ShipmentFilterApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    if (path == '/sales/shipments') {
      return const {
        'items': [
          {
            'id': 'shipment-1',
            'billNo': 'XS202608310001',
            'billDate': '2026-08-31',
            'clientId': 'client-1',
            'financeAudit': 0,
            'warehouseWorkStatus': 'PENDING_PICK',
            'status': 0,
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
    if (path.contains('clients')) {
      return const [
        {'id': 'client-1', 'name': '客户甲'},
      ];
    }
    return const [];
  }
}
