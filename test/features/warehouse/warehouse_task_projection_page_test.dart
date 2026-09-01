import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_return.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_iqc_return_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_iqc_return_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_return_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('sales list at 375px contains warehouse columns only', (
    tester,
  ) async {
    _viewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseSalesOutboundRepositoryProvider.overrideWithValue(
            _SalesGateway(),
          ),
        ],
        child: const MaterialApp(home: WarehouseSalesOutboundPage()),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester
        .widget<MasterDataTableView<WarehouseSalesOutboundSummary>>(
          find.byKey(const Key('warehouse-sales-outbound-table')),
        );
    final keys = {for (final column in table.columns) column.key};
    expect(keys, containsAll(<String>{'billNo', 'warehouseWorkStatus'}));
    expect(keys.any(_commercialKey), isFalse);
    _expectNoCommercialText();
    expect(tester.takeException(), isNull);
  });

  testWidgets('sales detail shows physical lines and server-allowed actions', (
    tester,
  ) async {
    _viewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseSalesOutboundRepositoryProvider.overrideWithValue(
            _SalesGateway(),
          ),
        ],
        child: const MaterialApp(
          home: WarehouseSalesOutboundDetailPage(id: 'sales-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前建议库位'), findsOneWidget);
    expect(find.text('A01-01'), findsWidgets);
    expect(
      find.byKey(const Key('warehouse-sales-outbound-action-PICKING')),
      findsOneWidget,
    );
    _expectNoCommercialText();
    expect(tester.takeException(), isNull);
  });

  testWidgets('IQC list and detail expose physical return facts only', (
    tester,
  ) async {
    _viewport(tester);
    final gateway = _IqcGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseIqcReturnRepositoryProvider.overrideWithValue(gateway),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionRecordReturn,
          }),
        ],
        child: const MaterialApp(home: WarehouseIqcReturnPage()),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<WarehouseIqcReturnTask>>(
      find.byKey(const Key('warehouse-iqc-return-table')),
    );
    expect({
      for (final column in table.columns) column.key,
    }, containsAll(<String>{'physicalReturnStatus', 'failedQuantity'}));
    _expectNoCommercialText();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseIqcReturnRepositoryProvider.overrideWithValue(gateway),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionRecordReturn,
          }),
        ],
        child: const MaterialApp(
          home: WarehouseIqcReturnDetailPage(id: 'iqc-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_selectableTextContaining('拒收产品'), findsWidgets);
    expect(_selectableTextContaining('2.0000 件'), findsWidgets);
    expect(
      find.byKey(const Key('warehouse-iqc-return-record')),
      findsOneWidget,
    );
    _expectNoCommercialText();
    expect(tester.takeException(), isNull);
  });
}

void _expectNoCommercialText() {
  for (final text in const [
    '999999.99',
    'USD-SECRET',
    'CREDIT-SECRET',
    '单价',
    '金额',
    '币种',
    '税率',
    '贷项',
    '抵销',
  ]) {
    expect(find.textContaining(text), findsNothing);
  }
}

Finder _selectableTextContaining(String value) => find.byWidgetPredicate(
  (widget) => widget is SelectableText && (widget.data ?? '').contains(value),
  skipOffstage: false,
);

bool _commercialKey(String key) {
  final value = key.toLowerCase();
  return value.contains('price') ||
      value.contains('amount') ||
      value.contains('currency') ||
      value.contains('tax') ||
      value.contains('settlement') ||
      value.contains('credit') ||
      value.contains('offset');
}

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(375, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _SalesGateway implements WarehouseSalesOutboundGateway {
  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
  }) async => PagedResult(
    items: [_salesDetail.header],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async => _salesDetail;

  @override
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
  }) async => _salesDetail;
}

class _IqcGateway implements WarehouseIqcReturnGateway {
  @override
  Future<PagedResult<WarehouseIqcReturnTask>> list({
    int page = 1,
    int size = 20,
    WarehouseIqcReceiptType? receiptType,
    String? physicalStatus,
    String? keyword,
  }) async => PagedResult(
    items: [_iqcTask],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<WarehouseIqcReturnTask> detail(String id) async => _iqcTask;

  @override
  Future<WarehouseIqcReturnTask> recordReturn(
    String id,
    WarehouseIqcRecordReturnCommand command,
  ) async => _iqcTask;
}

final WarehouseSalesOutboundDetail _salesDetail =
    WarehouseSalesOutboundDetail.fromJson(<String, dynamic>{
      'id': 'sales-1',
      'billNo': 'XS-001',
      'billDate': '2026-08-31',
      'clientName': '示例客户',
      'warehouseName': '成品仓',
      'warehouseWorkStatus': 'PENDING_PICK',
      'allowedWarehouseTargets': ['PICKING', 'EXCEPTION'],
      'totalLocal': '999999.99',
      'currencyCode': 'USD-SECRET',
      'lines': [
        {
          'id': 'line-1',
          'goodsCode': 'G-001',
          'goodsName': '实物产品',
          'currentStockPlaceHint': 'A01-01',
          'unitName': '件',
          'quantity': '10.0000',
          'unitPrice': '100.00',
        },
      ],
    });

final WarehouseIqcReturnTask _iqcTask = WarehouseIqcReturnTask.fromJson(
  <String, dynamic>{
    'id': 'iqc-1',
    'receiptType': 'PURCHASE',
    'receiptBillNo': 'PR-001',
    'orderBillNo': 'PO-001',
    'supplierName': '示例供应商',
    'warehouseName': '一号仓',
    'goodsCode': 'G-001',
    'goodsName': '拒收产品',
    'unitName': '件',
    'failedQuantity': '2.0000',
    'failedBaseQuantity': '2.0000',
    'physicalReturnStatus': 'PENDING_RETURN',
    'inspectionStatus': 'RESOLVED',
    'version': 3,
    'allowedActions': ['RECORD_RETURN'],
    'failedAmountLocal': '999999.99',
    'currencyCode': 'USD-SECRET',
    'creditReference': 'CREDIT-SECRET',
  },
);
