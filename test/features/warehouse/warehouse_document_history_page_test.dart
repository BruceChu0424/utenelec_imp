import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_document_history_config.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_document_history.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_document_history_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_document_history_list_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_document_history_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets(
    'list is responsive, filterable, and exposes physical columns only',
    (tester) async {
      _setViewport(tester, const Size(1200, 1500));
      final gateway = _Gateway();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            warehouseDocumentHistoryRepositoryProvider(
              WarehouseDocumentHistoryType.purchaseReceipt,
            ).overrideWithValue(gateway),
          ],
          child: const MaterialApp(
            home: WarehouseDocumentHistoryListPage(
              type: WarehouseDocumentHistoryType.purchaseReceipt,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('warehouse-history-physical-banner-purchase-receipts'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('当前货品主档建议'), findsOneWidget);
      expect(find.textContaining('不包含商业与财务信息'), findsOneWidget);

      final table = tester
          .widget<MasterDataTableView<WarehouseDocumentHistorySummary>>(
            find.byKey(const Key('warehouse-history-table-purchase-receipts')),
          );
      final keys = {for (final column in table.columns) column.key};
      expect(
        keys,
        containsAll(<String>{
          'billNo',
          'billDate',
          'status',
          'supplierName',
          'warehouseName',
          'sourceDocNo',
          'itemCount',
          'makerName',
          'approverName',
        }),
      );
      expect(keys, isNot(contains('totalQuantity')));
      expect(keys, isNot(contains('totalWeight')));
      expect(keys.any(_commercialKey), isFalse);

      await tester.tap(
        find.byKey(const Key('warehouse-history-status-purchase-receipts-1')),
      );
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, '1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail at 375px renders physical facts and no commercial leak', (
    tester,
  ) async {
    _setViewport(tester, const Size(375, 1400));
    final gateway = _Gateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseDocumentHistoryRepositoryProvider(
            WarehouseDocumentHistoryType.purchaseReceipt,
          ).overrideWithValue(gateway),
        ],
        child: const MaterialApp(
          home: WarehouseDocumentHistoryDetailPage(
            type: WarehouseDocumentHistoryType.purchaseReceipt,
            id: 'history-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key('warehouse-history-detail-banner-purchase-receipts'),
      ),
      findsOneWidget,
    );
    expect(find.text('G-001'), findsWidgets);
    expect(find.text('实物产品'), findsWidgets);
    expect(find.text('当前建议库位'), findsOneWidget);
    expect(find.text('A01-01'), findsWidgets);
    expect(find.textContaining('999999.99'), findsNothing);
    expect(find.textContaining('USD-SECRET'), findsNothing);
    expect(find.textContaining('单价'), findsNothing);
    expect(find.textContaining('金额'), findsNothing);
    expect(find.textContaining('币种'), findsNothing);
    expect(find.textContaining('税率'), findsNothing);
    expect(find.textContaining('应付'), findsNothing);

    final table = tester
        .widget<MasterDataTableView<WarehouseDocumentPhysicalItem>>(
          find.byKey(
            const Key('warehouse-history-detail-table-purchase-receipts'),
          ),
        );
    final keys = {for (final column in table.columns) column.key};
    expect(keys, containsAll(<String>{'goodsCode', 'goodsName', 'quantity'}));
    expect(keys.any(_commercialKey), isFalse);
    expect(tester.takeException(), isNull);
  });
}

bool _commercialKey(String key) {
  final normalized = key.toLowerCase();
  return normalized.contains('price') ||
      normalized.contains('amount') ||
      normalized.contains('currency') ||
      normalized.contains('tax') ||
      normalized.contains('settlement') ||
      normalized.contains('claim') ||
      normalized == 'apposted';
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Gateway implements WarehouseDocumentHistoryGateway {
  final List<String?> statuses = <String?>[];

  @override
  Future<PagedResult<WarehouseDocumentHistorySummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
  }) async {
    statuses.add(status);
    return PagedResult<WarehouseDocumentHistorySummary>(
      items: <WarehouseDocumentHistorySummary>[_detail.header],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<WarehouseDocumentHistoryDetail> detail(String id) async => _detail;
}

final WarehouseDocumentHistoryDetail _detail =
    WarehouseDocumentHistoryDetail.fromJson(
      WarehouseDocumentHistoryType.purchaseReceipt,
      <String, dynamic>{
        'id': 'history-1',
        'billNo': 'PR-001',
        'billDate': '2026-08-31',
        'supplierName': '示例供应商',
        'warehouseName': '一号仓',
        'status': 1,
        'closed': false,
        'sourceDocumentNo': 'PO-001',
        'lineCount': 1,
        'totalQuantity': '10.0000',
        'totalWeight': '25.5000',
        'makerName': '仓管甲',
        'approverName': '仓管乙',
        'remark': '外箱完好',
        'createdAt': '2026-08-31T08:30:00+08:00',
        'currencyId': 'USD-SECRET',
        'taxRate': '13',
        'totalLocal': '999999.99',
        'apPosted': true,
        'lines': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'line-1',
            'lineNumber': 1,
            'goodsCode': 'G-001',
            'goodsName': '实物产品',
            'stockPlace': 'A01-01',
            'unitName': '件',
            'quantity': '10.0000',
            'weight': '25.5000',
            'iqcStatus': 'PARTIAL',
            'iqcPassedBaseQuantity': '9.0000',
            'iqcFailedBaseQuantity': '1.0000',
            'referenceDocumentNo': 'PO-001',
            'unitPrice': '100.00',
            'amountLocal': '999999.99',
          },
        ],
      },
    );
