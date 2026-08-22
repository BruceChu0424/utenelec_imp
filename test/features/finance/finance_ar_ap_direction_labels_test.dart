import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_page.dart';

void main() {
  testWidgets('AP direction uses payable wording and exposes source type', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(_ApApi())],
        child: const MaterialApp(home: FinanceArApPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '应付'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<ArApLedgerItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<ArApLedgerItem>,
      ),
    );
    final columns = {for (final column in table.columns) column.key: column};
    final item = table.items.single;
    expect(columns['party']?.label, '供应商');
    expect(columns['sourceDocType']?.label, '来源类型');
    expect(columns['sourceDocType']?.value(item), '委外进仓');
    expect(columns['amountOriginal']?.label, '应付款金额');
    expect(columns['amountReceivedOriginal']?.label, '已付款金额');
    expect(columns['amountBalanceOriginal']?.label, '未付金额');
    expect(columns['amountBalance']?.label, '未付人民币');
    expect(columns.containsKey('salesOrderNos'), isFalse);
  });

  test('source type labels remain fail-visible for unknown values', () {
    expect(financeArApSourceTypeLabel('PURCHASE_RECEIPT'), '采购收货');
    expect(financeArApSourceTypeLabel('SUBCONTRACT_WASTE'), '委外损耗扣款');
    expect(financeArApSourceTypeLabel('FUTURE_SOURCE'), 'FUTURE_SOURCE');
    expect(financeArApSourceTypeLabel(null), '—');
  });
}

class _ApApi extends ApiClient {
  _ApApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => <String, dynamic>{
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'ap-1',
        'direction': 'AP',
        'sourceDocType': 'SUBCONTRACT_RECEIPT',
        'sourceDocNo': 'SWI-001',
        'supplierName': '精密加工厂',
        'amountOriginal': 100,
        'amountReceivedOriginal': 40,
        'amountBalanceOriginal': 60,
        'amountBalance': 60,
      },
    ],
    'page': 1,
    'size': 20,
    'total': 1,
    'totalPages': 1,
  };
}
