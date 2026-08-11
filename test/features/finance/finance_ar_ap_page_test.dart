import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_page.dart';

void main() {
  testWidgets('AR ledger exposes due date settlement style and remark', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(_ArApApi())],
        child: const MaterialApp(home: FinanceArApPage()),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<ArApLedgerItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<ArApLedgerItem>,
      ),
    );
    final columns = {for (final column in table.columns) column.key: column};
    final item = table.items.single;

    expect(columns['dueDate']?.label, '到期日');
    expect(columns['dueDate']?.value(item), '2026-09-07');
    expect(columns['settlementStyleLegacy']?.label, '结账方式');
    expect(columns['settlementStyleLegacy']?.value(item), '月结');
    expect(columns['remark']?.label, '备注');
    expect(columns['remark']?.value(item), '分批收款客户');

    final keys = table.columns.map((column) => column.key).toList();
    expect(keys.indexOf('currency'), lessThan(keys.indexOf('exchangeRate')));
    expect(
      keys.indexOf('exchangeRate'),
      lessThan(keys.indexOf('amountOriginal')),
    );
    expect(
      keys.indexOf('amountBalanceOriginal'),
      lessThan(keys.indexOf('amountBalance')),
    );
    expect(columns['currency']?.value(item), 'USD');
    expect(columns['amountOriginal']?.value(item), '100.00');
    expect(columns['amountReceivedOriginal']?.value(item), '40.00');
    expect(columns['amountBalanceOriginal']?.value(item), '55.00');
    expect(columns['amountBalance']?.value(item), '396.00');
  });

  test('AR ledger settlement mapping matches the finance sales dictionary', () {
    expect(financeArApSettlementStyleLabel(1), '现金');
    expect(financeArApSettlementStyleLabel(2), '提货');
    expect(financeArApSettlementStyleLabel(3), '代付');
    expect(financeArApSettlementStyleLabel(4), '支票');
    expect(financeArApSettlementStyleLabel(6), '月结');
    expect(financeArApSettlementStyleLabel(7), '垫付');
    expect(financeArApSettlementStyleLabel(8), '汇款');
    expect(financeArApSettlementStyleLabel(10), '代收');
    expect(financeArApSettlementStyleLabel(null), '未设置');
    expect(financeArApSettlementStyleLabel(99), '未设置');
  });
}

class _ArApApi extends ApiClient {
  _ArApApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/ar-ap') {
      return <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'ledger-1',
            'direction': 'AR',
            'billNo': 'AR-20260808-001',
            'billDate': '2026-08-08',
            'dueDate': '2026-09-07',
            'settlementStyleLegacy': 6,
            'currencyCode': 'USD',
            'exchangeRate': 7.2,
            'amountOriginal': 100,
            'amountReceivedOriginal': 40,
            'amountWriteOffOriginal': 5,
            'amountBalanceOriginal': 55,
            'amountBalance': 396,
            'remark': '分批收款客户',
          },
        ],
        'page': 1,
        'size': 50,
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
  }) async => const <Map<String, dynamic>>[];
}
