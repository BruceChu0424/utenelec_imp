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
  testWidgets('order list shows currency and original amount, not RMB total', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _OrderListApi();
    final router = GoRouter(
      initialLocation: '/sales/orders',
      routes: [
        GoRoute(
          path: '/sales/orders',
          builder: (_, _) =>
              const SalesDocListPage(docType: SalesDocType.order),
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

    final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SalesDocListItem>,
      ),
    );
    final columns = {for (final column in table.columns) column.key: column};
    final item = table.items.single;

    expect(columns['currency']?.label, '币种');
    expect(columns['currency']?.value(item), '美元');
    expect(columns['total']?.label, '订单金额');
    expect(columns['total']?.value(item), '100.00');
    expect(columns['total']?.sortable, isFalse);
    expect(columns['total']?.value(item), isNot('720.00'));
  });

  testWidgets('shipment list exposes finance audit before warehouse status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _ShipmentListApi();
    final router = GoRouter(
      initialLocation: '/sales/shipments',
      routes: [
        GoRoute(
          path: '/sales/shipments',
          builder: (_, _) =>
              const SalesDocListPage(docType: SalesDocType.shipment),
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

    final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SalesDocListItem>,
      ),
    );
    final keys = table.columns.map((column) => column.key).toList();
    final columns = {for (final column in table.columns) column.key: column};
    final item = table.items.single;

    expect(columns['financeAudit']?.label, '财务审核');
    expect(columns['financeAudit']?.value(item), '待财务审核');
    expect(
      keys.indexOf('financeAudit'),
      lessThan(keys.indexOf('warehouseWorkStatus')),
    );
  });
}

class _OrderListApi extends ApiClient {
  _OrderListApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders') {
      return const <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'order-1',
            'billNo': 'XD202608090001',
            'billDate': '2026-08-09',
            'clientId': 'client-1',
            'currencyId': 'currency-usd',
            'totalOriginal': 100,
            'totalLocal': 720,
            'status': 0,
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/clients/dict') {
      return const [
        {'id': 'client-1', 'name': '甲客户'},
      ];
    }
    if (path == '/master/currencies/dict') {
      return const [
        {'id': 'currency-usd', 'name': '美元'},
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}

class _ShipmentListApi extends ApiClient {
  _ShipmentListApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/shipments') {
      return const <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'shipment-1',
            'billNo': 'XS202608310001',
            'billDate': '2026-08-31',
            'clientId': 'client-1',
            'warehouseId': 'warehouse-1',
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
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/clients/dict') {
      return const [
        {'id': 'client-1', 'name': '甲客户'},
      ];
    }
    if (path == '/master/warehouses/dict') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓'},
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}
