import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_document_history_config.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_document_history.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_document_history_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_document_history_list_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_document_history_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_document_history_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('同一历史视图切type且其它条件不变时，不保留旧域行或筛选', (tester) async {
    _setViewport(tester, const Size(1200, 1500));
    final type = ValueNotifier(WarehouseDocumentHistoryType.subcontractReturn);
    addTearDown(type.dispose);
    final returns = _TypeGateway(
      WarehouseDocumentHistoryType.subcontractReturn,
      'RETURN',
    );
    final wastes = _TypeGateway(
      WarehouseDocumentHistoryType.subcontractWaste,
      'WASTE',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseDocumentHistoryRepositoryProvider(
            WarehouseDocumentHistoryType.subcontractReturn,
          ).overrideWithValue(returns),
          warehouseDocumentHistoryRepositoryProvider(
            WarehouseDocumentHistoryType.subcontractWaste,
          ).overrideWithValue(wastes),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: type,
              builder: (_, value, _) => WarehouseDocumentHistoryView(
                key: const Key('same-history-state'),
                type: value,
                keyword: 'same-query',
                refreshTick: 7,
                embedded: true,
                dateFrom: '2026-10-01',
                dateTo: '2026-10-12',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    MasterDataTableView<WarehouseDocumentHistorySummary> table(
      WarehouseDocumentHistoryType value,
    ) => tester.widget(
      find.byKey(Key('warehouse-history-table-${value.segment}')),
    );
    table(type.value).onFilterChanged('status', '-1');
    await tester.pumpAndSettle();
    table(type.value).onFilterChanged('billNo', 'OLD-RETURN-NO');
    await tester.pumpAndSettle();
    table(type.value).onFilterChanged('sourceDocNo', 'OLD-RETURN-SOURCE');
    await tester.pumpAndSettle();
    table(type.value).onPageChange!(3);
    await tester.pumpAndSettle();
    expect(find.text('RETURN-3'), findsOneWidget);
    returns.listGate = Completer<void>();
    table(type.value).onRetry!();
    await tester.pump();
    type.value = WarehouseDocumentHistoryType.subcontractWaste;
    await tester.pump();
    expect(find.text('RETURN-3'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('WASTE-1'), findsOneWidget);
    expect(wastes.lastPage, 1);
    expect(wastes.lastStatus, isNull);
    expect(wastes.lastBillNo, isNull);
    expect(wastes.lastSourceDocNo, isNull);
    expect(wastes.lastRange, ('2026-10-01', '2026-10-12'));
    expect(table(type.value).requiredLeadingColumnKeys, ['status', 'goodsName']);
    expect(
      table(type.value).items.single.type,
      WarehouseDocumentHistoryType.subcontractWaste,
    );
    returns.listGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('RETURN-3'), findsNothing);
    expect(find.text('WASTE-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

      // 2026-09-24 标题下说明小字/横幅全站删除：「仓库实物视图」提示条不再渲染。
      expect(
        find.byKey(
          const Key('warehouse-history-physical-banner-purchase-receipts'),
        ),
        findsNothing,
      );
      expect(find.textContaining('当前货品主档建议'), findsNothing);

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
          'goodsName',
          'goodsCode',
          'specification',
          'colorName',
          'quantity',
          'makerName',
          'approverName',
        }),
      );
      expect(keys, isNot(contains('totalQuantity')));
      expect(keys, isNot(contains('totalWeight')));
      expect(keys.any(_commercialKey), isFalse);

      await tester.tap(
        // 状态筛选已从 ChoiceChip 行换成统一筛选工具条：分段键为原 Chip 键前缀
        // （原为每 Chip 一键），按分段文字定位「已审核」（value '1'）。
        find.descendant(
          of: find.byKey(
            const Key('warehouse-history-status-purchase-receipts'),
          ),
          matching: find.text('已审核'),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, '1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'embedded history uses the status header and preserves the date range',
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
            home: Scaffold(
              body: WarehouseDocumentHistoryView(
                type: WarehouseDocumentHistoryType.purchaseReceipt,
                embedded: true,
                dateFrom: '2026-10-01',
                dateTo: '2026-10-11',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-history-status-purchase-receipts')),
        findsNothing,
      );
      MasterDataTableView<WarehouseDocumentHistorySummary> table() =>
          tester.widget(
            find.byKey(const Key('warehouse-history-table-purchase-receipts')),
          );
      expect(table().facets['status']?.map((bucket) => bucket.value), [
        '0',
        '1',
        '-1',
      ]);
      table().onFilterChanged('status', '1');
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, '1');
      expect(gateway.lastRange, ('2026-10-01', '2026-10-11'));
      expect(gateway.lastPage, 1);
      expect(table().filters['status'], '1');
      table().onFilterChanged('status', null);
      await tester.pumpAndSettle();
      expect(gateway.statuses.last, isNull);
      expect(gateway.lastRange, ('2026-10-01', '2026-10-11'));
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

    // 2026-09-24 标题下说明小字/横幅全站删除：详情页「仓库实物视图」横幅不再渲染。
    expect(
      find.byKey(
        const Key('warehouse-history-detail-banner-purchase-receipts'),
      ),
      findsNothing,
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
    // 重量 (千克) 紧跟数量, 按显示单位带单位显示 (ADR-135), 不再是裸数字。
    final order = [for (final column in table.columns) column.key];
    expect(order.indexOf('weight'), order.indexOf('quantity') + 1);
    final weightColumn = table.columns.firstWhere((c) => c.key == 'weight');
    expect(weightColumn.type, 'weight');
    expect(weightColumn.value(_detail.items.single), '25.5 kg');
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
  @override
  Future<Map<String, List<MasterFacetBucket>>> billNoFacets({
    String? keyword,
    String? status,
    String? dateFrom,
    String? dateTo,
  }) async => const {'billNo': [], 'sourceDocNo': []}; // 2026-09-25 单号列统一：静默降级。
  final List<String?> statuses = <String?>[];
  (String?, String?)? lastRange;
  int? lastPage;

  @override
  Future<PagedResult<WarehouseDocumentHistorySummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    String? billNo,
    String? sourceDocNo,
  }) async {
    statuses.add(status);
    lastRange = (dateFrom, dateTo);
    lastPage = page;
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

class _TypeGateway extends _Gateway {
  _TypeGateway(this.type, this.prefix);
  final WarehouseDocumentHistoryType type;
  final String prefix;
  String? lastStatus;
  String? lastBillNo;
  String? lastSourceDocNo;
  Completer<void>? listGate;
  @override
  Future<PagedResult<WarehouseDocumentHistorySummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    String? billNo,
    String? sourceDocNo,
  }) async {
    lastPage = page;
    lastStatus = status;
    lastBillNo = billNo;
    lastSourceDocNo = sourceDocNo;
    lastRange = (dateFrom, dateTo);
    await listGate?.future;
    return PagedResult(
      items: [
        WarehouseDocumentHistorySummary(
          id: '${type.segment}-$page',
          type: type,
          closed: false,
          itemCount: 1,
          billNo: '$prefix-$page',
          status: status ?? '1',
        ),
      ],
      page: page,
      size: 1,
      total: 3,
      totalPages: 3,
    );
  }
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
