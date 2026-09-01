import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  final summary = WarehouseSalesOutboundSummary.fromJson(_detailJson);
  final detail = WarehouseSalesOutboundDetail.fromJson(_detailJson);

  test('warehouse sales parser and routes stay commercial-free', () {
    expect(summary.allows(WarehouseSalesOutboundAction.startPicking), isTrue);
    expect(requiredAnyPermFor(RouteName.warehouseSalesOutbound), <String>[
      Perm.salesShipmentWarehouseWork,
    ]);
    expect(
      requiredAnyPermFor(RoutePath.warehouseSalesOutboundDetail('shipment-1')),
      <String>[Perm.salesShipmentWarehouseWork],
    );
    expect(
      pagePermissionScopeFor(
        RoutePath.warehouseSalesOutboundDetail('shipment-1'),
      )?.surfaceKey,
      'warehouse.sales-outbound',
    );

    final source = File(
      'lib/features/warehouse/models/warehouse_sales_outbound.dart',
    ).readAsStringSync();
    for (final key in warehouseSalesOutboundForbiddenKeys) {
      expect(
        source,
        isNot(contains("json['$key']")),
        reason: 'warehouse sales parser must ignore $key',
      );
    }
    final pageSource = File(
      'lib/features/warehouse/pages/warehouse_sales_outbound_page.dart',
    ).readAsStringSync();
    expect(pageSource, isNot(contains('SalesShipmentTaskWorkbench')));
    expect(pageSource, isNot(contains('SalesDocDetailPage')));
  });

  testWidgets('warehouse sales list and detail expose physical work only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 850));
    final gateway = _SalesGateway(summary, detail);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseSalesOutboundRepositoryProvider.overrideWithValue(gateway),
        ],
        child: const MaterialApp(home: WarehouseSalesOutboundPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('仓库销售出库'), findsOneWidget);
    expect(find.text('SO-OUT-001'), findsOneWidget);
    expect(find.textContaining('仓库作业视图'), findsOneWidget);
    expect(find.textContaining('金额'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseSalesOutboundRepositoryProvider.overrideWithValue(gateway),
        ],
        child: const MaterialApp(
          home: WarehouseSalesOutboundDetailPage(id: 'shipment-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SO-OUT-001'), findsWidgets);
    expect(find.text('开始拣货'), findsOneWidget);
    expect(find.text('当前建议库位'), findsOneWidget);
    expect(find.textContaining('金额'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}

const _detailJson = <String, dynamic>{
  'id': 'shipment-1',
  'billNo': 'SO-OUT-001',
  'billDate': '2026-08-31',
  'clientName': '客户甲',
  'warehouseName': '一号仓',
  'warehouseWorkStatus': 'PENDING_PICK',
  'allowedWarehouseTargets': <String>['PICKING', 'EXCEPTION'],
  'shipAddress': '交接地址',
  'contactPhone': '13800000000',
  'logisticsNo': 'LOG-001',
  'currencyId': 'secret',
  'totalLocal': 9999,
  'lines': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'line-1',
      'lineNumber': 1,
      'goodsCode': 'G-001',
      'goodsName': '货品甲',
      'currentStockPlaceHint': 'A01-01',
      'colorName': '本色',
      'unitName': '件',
      'quantity': '10.0000',
      'weight': '20.0000',
      'price': 999,
      'amountLocal': 9990,
    },
  ],
};

class _SalesGateway implements WarehouseSalesOutboundGateway {
  @override
  Future<int> pendingCount() async => 0;

  _SalesGateway(this.summary, this.value);

  final WarehouseSalesOutboundSummary summary;
  final WarehouseSalesOutboundDetail value;

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
  }) async => PagedResult(
    items: [summary],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async => value;

  @override
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
  }) async => value;
}
