import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_outbound_table_columns.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_picking_fields.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

void main() {
  final summary = WarehouseSalesOutboundSummary.fromJson(_detailJson);
  final detail = WarehouseSalesOutboundDetail.fromJson(_detailJson);

  test(
    'draft prefills the suggested warehouse per line and the master stock place, keeping confirmed facts first',
    () {
      // V631 用户口径：实际库位先按主档建议库位预填；发出仓按行预填服务端建议仓。
      final hinted = WarehouseSalesPickingDraft(detail);
      expect(hinted.stockPlaces, {'line-1': 'A01-01'});
      expect(hinted.lineWarehouses, {'line-1': 'leaf-1'});
      expect(hinted.warehouseNameOf('line-1'), '成品一仓');
      expect(hinted.validate(), isTrue);
      hinted.dispose();

      // 已确认过的实际库位与行仓优先于建议值。
      final historical = WarehouseSalesOutboundDetail.fromJson({
        ..._detailJson,
        'lines': [
          {
            ...(_detailJson['lines'] as List).single as Map<String, dynamic>,
            'actualStockPlace': 'OLD-A',
            'warehouseId': 'leaf-2',
            'warehouseName': '成品二仓',
          },
        ],
      });
      final draft = WarehouseSalesPickingDraft(historical);
      expect(draft.stockPlaces, {'line-1': 'OLD-A'});
      expect(draft.lineWarehouses, {'line-1': 'leaf-2'});
      draft.changeWarehouse('line-1', 'leaf-1');
      expect(draft.lineWarehouses, {'line-1': 'leaf-1'});
      expect(draft.stockPlaces, {'line-1': 'OLD-A'});
      expect(historical.lines.single.actualStockPlace, 'OLD-A');
      draft.dispose();

      // 没有建议仓也没有表头仓：不预填，校验点名该行；选了不足的仓同样拦下。
      final unchosen = WarehouseSalesPickingDraft(
        WarehouseSalesOutboundDetail.fromJson({
          ..._detailJson,
          'warehouseId': null,
          'warehouseName': null,
          'lines': [
            {
              ...(_detailJson['lines'] as List).single as Map<String, dynamic>,
              'suggestedWarehouseId': null,
              'warehouseChoices': [
                {
                  'warehouseId': 'short',
                  'warehouseName': '物料不足的子仓',
                  'availableQty': '2',
                  'requiredQty': '10',
                  'canFulfill': false,
                },
              ],
            },
          ],
        }),
      );
      expect(unchosen.lineWarehouses, {'line-1': null});
      expect(unchosen.warehouseNameOf('line-1'), isNull);
      expect(unchosen.validate(), isFalse);
      expect(unchosen.error, contains('第 1 行'));
      unchosen.changeWarehouse('line-1', 'short');
      expect(unchosen.validate(), isFalse);
      expect(unchosen.lineErrors['line-1'], contains('不足'));
      unchosen.dispose();

      // 已出库的单据不再校验发出仓，只读展示。
      final shipped = WarehouseSalesPickingDraft(
        WarehouseSalesOutboundDetail.fromJson({
          ..._detailJson,
          'warehouseWorkStatus': 'SHIPPED',
          'allowedWarehouseTargets': <String>[],
        }),
      );
      expect(shipped.selectable, isFalse);
      expect(shipped.validate(), isTrue);
      shipped.dispose();
    },
  );

  testWidgets(
    '375px per-line warehouse picker retains a usable long name and disables insufficient source',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = WarehouseSalesOutboundDetail.fromJson({
        ..._detailJson,
        'lines': [
          {
            ...(_detailJson['lines'] as List).single as Map<String, dynamic>,
            'suggestedWarehouseId': 'ready',
            'warehouseChoices': [
              {
                'warehouseId': 'ready',
                'warehouseName': '生产成品总仓下面的可用发货子仓名称较长',
                'availableQty': '10',
                'requiredQty': '10',
                'canFulfill': true,
              },
              {
                'warehouseId': 'short',
                'warehouseName': '物料不足的子仓',
                'availableQty': '2',
                'requiredQty': '10',
                'canFulfill': false,
              },
            ],
          },
        ],
      });
      final draft = WarehouseSalesPickingDraft(pending);
      addTearDown(draft.dispose);
      final row = WarehouseSalesOutboundTableRow(pending, pending.lines.single);
      final column = warehouseSalesOutboundTableColumns(
        l10n: AppLocalizationsZh(),
        rows: [row],
        draftOf: (_) => draft,
      ).singleWhere((column) => column.key == 'warehouse');
      expect(column.value(row), '生产成品总仓下面的可用发货子仓名称较长');
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
                  builder: (context, setState) =>
                      column.cellBuilder!(context, row),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final picker = tester.widget<UtenDropdownField>(
        find.byKey(const ValueKey('sales-picking-warehouse-line-line-1')),
      );
      expect(picker.value, 'ready');
      expect(
        picker.items.singleWhere((item) => item.value == 'short').enabled,
        isFalse,
      );
      expect(
        picker.items.singleWhere((item) => item.value == 'short').label,
        contains('不足'),
      );
      await tester.tap(
        find.byKey(const ValueKey('sales-picking-warehouse-line-line-1')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('warehouse sales parser and routes stay commercial-free', () {
    expect(
      summary.allows(WarehouseSalesOutboundAction.confirmShipment),
      isTrue,
    );
    expect(requiredAnyPermFor(RouteName.warehouseSalesOutbound), <String>[
      Perm.warehouseSalesOutboundView,
    ]);
    expect(
      requiredAnyPermFor(RoutePath.warehouseSalesOutboundDetail('shipment-1')),
      <String>[Perm.warehouseSalesOutboundView],
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
    await tester.tap(find.text('待出库'));
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
    expect(find.text('确认出库'), findsOneWidget);
    expect(find.text('当前建议库位'), findsOneWidget);
    // V631：时间按北京时间显示，不再出现原始 ISO 瞬时。
    expect(find.text('2026-09-20T22:19:29.862649Z'), findsNothing);
    expect(find.textContaining('2026-09-21 06:19'), findsOneWidget);
    expect(find.text('默认发出仓'), findsOneWidget);
    expect(find.text('实际发货仓库'), findsNothing);
    expect(find.textContaining('金额'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'warehouse confirms per-line source warehouse and actual location before the outbound',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = WarehouseSalesOutboundDetail.fromJson({
        ..._detailJson,
        'warehouseId': null,
        'warehouseName': null,
        'lines': [
          {
            ...(_detailJson['lines'] as List).single as Map<String, dynamic>,
            'suggestedWarehouseId': 'leaf-1',
            'warehouseChoices': [
              {
                'warehouseId': 'leaf-1',
                'warehouseName': '成品一仓',
                'availableQty': '10',
                'requiredQty': '10',
                'canFulfill': true,
              },
              {
                'warehouseId': 'leaf-2',
                'warehouseName': '成品二仓',
                'availableQty': '2',
                'requiredQty': '10',
                'canFulfill': false,
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
      expect(find.text('实际发货仓库'), findsNothing);
      final picker = tester.widget<UtenDropdownField>(
        find.byKey(const ValueKey('sales-picking-warehouse-line-line-1')),
      );
      expect(picker.value, 'leaf-1', reason: '预填服务端建议仓');
      expect(find.textContaining('成品一仓 · 可发 10'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('sales-picking-place-line-1')),
            )
            .controller
            ?.text,
        'A01-01',
        reason: '实际库位先按主档建议库位预填',
      );
      await tester.enterText(
        find.byKey(const ValueKey('sales-picking-place-line-1')),
        'B02-08',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-action-SHIPPED')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(gateway.selectedLineWarehouses, {'line-1': 'leaf-1'});
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
  'warehouseId': 'leaf-1',
  'warehouseName': '成品一仓',
  'warehouseWorkStatus': 'PENDING_PICK',
  'warehouseWorkUpdatedAt': '2026-09-20T22:19:29.862649Z',
  'allowedWarehouseTargets': <String>['SHIPPED'],
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
      'suggestedWarehouseId': 'leaf-1',
      'warehouseChoices': <Map<String, dynamic>>[
        <String, dynamic>{
          'warehouseId': 'leaf-1',
          'warehouseName': '成品一仓',
          'availableQty': '10',
          'requiredQty': '10',
          'canFulfill': true,
        },
      ],
    },
  ],
};

class _SalesGateway implements WarehouseSalesOutboundGateway {
  _SalesGateway(this.summary, this.value);

  final WarehouseSalesOutboundSummary summary;
  final WarehouseSalesOutboundDetail value;
  Map<String, String?>? selectedLineWarehouses;
  Map<String, String>? selectedPlaces;

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
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
    Map<String, String>? stockPlaces,
    Map<String, String?>? lineWarehouses,
  }) async {
    selectedLineWarehouses = lineWarehouses;
    selectedPlaces = stockPlaces;
    final warehouseId = lineWarehouses?.values.firstOrNull;
    return WarehouseSalesOutboundDetail.fromJson({
      ..._detailJson,
      'warehouseWorkStatus': targetStatus,
      'allowedWarehouseTargets': <String>[],
      'warehouseId': warehouseId,
      'warehouseName': '成品一仓',
      'lines': [
        for (final line in _detailJson['lines'] as List)
          {
            ...line as Map<String, dynamic>,
            'warehouseId': warehouseId,
            'warehouseName': '成品一仓',
            'actualStockPlace': stockPlaces?[line['id']],
            'warehouseChoices': <Map<String, dynamic>>[],
          },
      ],
    });
  }
}
