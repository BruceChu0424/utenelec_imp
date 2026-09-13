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
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_picking_fields.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  final summary = WarehouseSalesOutboundSummary.fromJson(_detailJson);
  final detail = WarehouseSalesOutboundDetail.fromJson(_detailJson);

  test(
    'actual location never comes from a master hint and changing warehouse clears current intent',
    () {
      final hinted = WarehouseSalesPickingDraft(detail);
      expect(hinted.stockPlaces, {'line-1': ''});
      hinted.dispose();
      final historical = WarehouseSalesOutboundDetail.fromJson({
        ..._detailJson,
        'warehouseId': 'old-leaf',
        'lines': [
          {
            ...(_detailJson['lines'] as List).single as Map<String, dynamic>,
            'actualStockPlace': 'OLD-A',
          },
        ],
      });
      final draft = WarehouseSalesPickingDraft(historical);
      expect(draft.stockPlaces, {'line-1': 'OLD-A'});
      draft.changeWarehouse('new-leaf');
      expect(draft.stockPlaces, {'line-1': ''});
      expect(historical.lines.single.actualStockPlace, 'OLD-A');
      draft.dispose();
      final unchosen = WarehouseSalesPickingDraft(
        WarehouseSalesOutboundDetail.fromJson({
          ..._detailJson,
          'warehouseId': 'old-leaf',
          'canSelectWarehouse': true,
          'warehouseOptions': [
            {
              'warehouseId': 'new-a',
              'warehouseName': '新仓甲',
              'canFulfill': true,
            },
            {
              'warehouseId': 'new-b',
              'warehouseName': '新仓乙',
              'canFulfill': true,
            },
          ],
          'lines': [
            {
              ...(_detailJson['lines'] as List).single as Map<String, dynamic>,
              'actualStockPlace': 'OLD-A',
            },
          ],
        }),
      );
      expect(unchosen.warehouseId, isNull);
      expect(
        unchosen.warehouseName,
        isNull,
        reason:
            'no current choice must not display a former warehouse as actual',
      );
      expect(unchosen.stockPlaces, {'line-1': ''});
      expect(unchosen.validate(), isFalse);
      unchosen.dispose();
    },
  );

  testWidgets(
    '375px warehouse picker retains a usable long name and disables insufficient source',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = WarehouseSalesOutboundDetail.fromJson({
        ..._detailJson,
        'canSelectWarehouse': true,
        'warehouseOptions': [
          {
            'warehouseId': 'ready',
            'warehouseName': '生产成品总仓下面的可用发货子仓名称较长',
            'canFulfill': true,
            'lines': <Map<String, dynamic>>[],
          },
          {
            'warehouseId': 'short',
            'warehouseName': '物料不足的子仓',
            'canFulfill': false,
            'lines': <Map<String, dynamic>>[],
          },
        ],
      });
      final draft = WarehouseSalesPickingDraft(pending);
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                size: Size(375, 844),
                textScaler: TextScaler.linear(1.3),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: StatefulBuilder(
                  builder: (context, setState) => WarehouseSalesPickingFields(
                    draft: draft,
                    onChanged: () => setState(() {}),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final picker = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('sales-picking-warehouse-shipment-1')),
      );
      final dropdown = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byWidget(picker),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(
        dropdown.items!.singleWhere((item) => item.value == 'short').enabled,
        isFalse,
      );
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

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
    // 1440 宽：状态分段（含「历史单据」段）+ 搜索框 + 尾部统计一行排开。
    await tester.binding.setSurfaceSize(const Size(1440, 850));
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
    // 2026-09-03 分类范式：状态行默认不选（不发请求），先 tap「待拣货」才加载。
    await tester.tap(find.text('待拣货'));
    await tester.pumpAndSettle();
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

  testWidgets(
    'warehouse chooses a real source and confirms actual location before picking',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = WarehouseSalesOutboundDetail.fromJson({
        ..._detailJson,
        'warehouseName': null,
        'canSelectWarehouse': true,
        'warehouseOptions': [
          {
            'warehouseId': 'leaf-1',
            'warehouseName': '成品一仓',
            'canFulfill': true,
            'lines': [
              {
                'shipmentItemId': 'line-1',
                'availableQty': '10',
                'requiredQty': '10',
              },
            ],
          },
          {
            'warehouseId': 'leaf-2',
            'warehouseName': '成品二仓',
            'canFulfill': false,
            'lines': [
              {
                'shipmentItemId': 'line-1',
                'availableQty': '2',
                'requiredQty': '10',
              },
            ],
          },
        ],
      });
      final gateway = _SalesGateway(pending.header, pending);
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
      expect(find.text('实际发货仓库'), findsOneWidget);
      expect(find.textContaining('本仓可发 10 / 本单需发 10'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('sales-picking-place-line-1')),
        'B02-08',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-action-PICKING')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(gateway.selectedWarehouse, 'leaf-1');
      expect(gateway.selectedPlaces, {'line-1': 'B02-08'});
      expect(tester.takeException(), isNull);
    },
  );
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
  String? selectedWarehouse;
  Map<String, String>? selectedPlaces;

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
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
    String? warehouseId,
    Map<String, String>? stockPlaces,
  }) async {
    selectedWarehouse = warehouseId;
    selectedPlaces = stockPlaces;
    return WarehouseSalesOutboundDetail.fromJson({
      ..._detailJson,
      'warehouseWorkStatus': targetStatus,
      'allowedWarehouseTargets': <String>[],
      'warehouseId': warehouseId,
      'warehouseName': '成品一仓',
    });
  }
}
