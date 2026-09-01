import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_shipment_audit_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('finance task page defaults to pending and uses desktop table', (
    tester,
  ) async {
    final api = _ShipmentTaskApi();
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.financeShipmentAudit,
      api: api,
      size: const Size(1440, 900),
    );

    expect(
      find.byKey(const Key('finance-shipment-audit-table')),
      findsOneWidget,
    );
    expect(api.shipmentQueries.single['financeAudit'], 0);
    expect(api.shipmentQueries.single['status'], kSalesStatusDraft);
    expect(
      api.shipmentQueries.single['warehouseWorkStatus'],
      SalesWarehouseWorkStatus.pendingPick,
    );
    expect(find.text('财务审核'), findsWidgets);
    expect(find.text('仓库作业'), findsOneWidget);
  });

  testWidgets(
    'warehouse task page stays usable at 375px and filters work status',
    (tester) async {
      final api = _ShipmentTaskApi(financeAudit: 1);
      await _pump(
        tester,
        page: const WarehouseSalesOutboundPage(),
        permission: Perm.salesShipmentWarehouseWork,
        api: api,
        size: const Size(375, 812),
      );

      expect(
        find.byKey(const Key('warehouse-sales-outbound-compact-list')),
        findsOneWidget,
      );
      expect(find.text('查看详情'), findsOneWidget);
      expect(api.shipmentQueries.first['financeAudit'], 1);
      expect(api.shipmentQueries.first['status'], kSalesStatusDraft);
      expect(
        api.shipmentQueries.first['warehouseWorkStatus'],
        SalesWarehouseWorkStatus.pendingPick,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, '拣货中'));
      await tester.pumpAndSettle();

      expect(api.shipmentQueries.last['financeAudit'], 1);
      expect(api.shipmentQueries.last['status'], kSalesStatusDraft);
      expect(api.shipmentQueries.last['warehouseWorkStatus'], 'PICKING');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('task page exposes recoverable initial error state', (
    tester,
  ) async {
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.financeShipmentAudit,
      api: _ShipmentTaskApi(fail: true),
      size: const Size(375, 812),
    );

    expect(find.text('出货财务审核任务加载失败'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
  });

  testWidgets('missing exact permission shows denial without requesting API', (
    tester,
  ) async {
    final api = _ShipmentTaskApi();
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.salesShipmentView,
      api: api,
      size: const Size(375, 812),
    );

    expect(find.text('无权查看出货财务审核'), findsOneWidget);
    expect(api.shipmentQueries, isEmpty);
  });

  testWidgets('empty finance queue explains how a new task appears', (
    tester,
  ) async {
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.financeShipmentAudit,
      api: _ShipmentTaskApi(empty: true),
      size: const Size(375, 812),
    );

    expect(find.text('暂无待财务审核的出货单'), findsOneWidget);
    expect(find.textContaining('等待财务逐张人工放行'), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget page,
  required String permission,
  required _ShipmentTaskApi api,
  required Size size,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue({permission}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
}

class _ShipmentTaskApi extends ApiClient {
  _ShipmentTaskApi({
    this.fail = false,
    this.empty = false,
    this.financeAudit = 0,
  }) : super(Dio());

  final bool fail;
  final bool empty;
  final int financeAudit;
  final List<Map<String, dynamic>> shipmentQueries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/shipments') return const <String, dynamic>{};
    shipmentQueries.add(Map<String, dynamic>.from(query ?? const {}));
    if (fail) throw StateError('offline');
    return <String, dynamic>{
      'items': empty
          ? <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'shipment-1',
                'billNo': 'XS202608310001',
                'billDate': '2026-08-31',
                'clientId': 'client-1',
                'warehouseId': 'warehouse-1',
                'currencyId': 'currency-1',
                'totalOriginal': 100,
                'status': 0,
                'financeAudit': financeAudit,
                'warehouseWorkStatus': 'PENDING_PICK',
              },
            ],
      'page': 1,
      'size': 20,
      'total': empty ? 0 : 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/clients/dict')) {
      return const [
        {'id': 'client-1', 'code': 'C001', 'name': '测试客户'},
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}
