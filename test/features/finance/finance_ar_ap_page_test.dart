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
    expect(find.text('应收应付台账'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^台账 \(')), findsNothing);

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
    expect(columns['settled']?.label, '状态');
    expect(columns['settled']?.value(item), '应收未清');

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
    expect(columns['currency']?.value(item), '人民币');
    // 金额「数值 币种」后缀（2026-10-10 口径）：人民币行后缀为「元」。
    expect(columns['amountOriginal']?.value(item), '100.00 元');
    expect(columns['amountReceivedOriginal']?.value(item), '40.00 元');
    expect(columns['amountBalanceOriginal']?.value(item), '55.00 元');
    expect(columns['amountBalance']?.value(item), '396.00 元');
    expect(
      table.facets.keys,
      containsAll(<String>['direction', 'sourceDocType', 'party', 'settled']),
    );
    expect(
      table.facets['direction']?.map((bucket) => bucket.value),
      containsAll(<String>['AR', 'AP']),
    );
    expect(
      table.facets['settled']?.map((bucket) => bucket.value),
      containsAll(<String>['false', 'true']),
    );
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

  testWidgets(
    'settlement header filters the server and clears in the same direction',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ArApApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: const MaterialApp(home: FinanceArApPage()),
        ),
      );
      await tester.pumpAndSettle();
      MasterDataTableView<ArApLedgerItem> table() =>
          tester.widget(find.byType(MasterDataTableView<ArApLedgerItem>));
      table().onFilterChanged('direction', 'AP');
      await tester.pumpAndSettle();
      table().onFilterChanged('settled', 'false');
      await tester.pumpAndSettle();
      expect(api.lastQuery?['direction'], 'AP');
      expect(api.lastQuery?['settled'], false);
      expect(api.lastQuery?['page'], 1);
      table().onFilterChanged('settled', null);
      await tester.pumpAndSettle();
      expect(api.lastQuery?['direction'], 'AP');
      expect(api.lastQuery?['settled'], isNull);
      table().onFilterChanged('sourceDocNo', ' PO-OTHER-PAGE ');
      await tester.pumpAndSettle();
      expect(api.lastQuery?['sourceDocNo'], 'PO-OTHER-PAGE');
      expect(api.lastQuery?['direction'], 'AP');
      expect(api.lastQuery?['page'], 1);
      table().onFilterChanged('sourceDocNo', null);
      await tester.pumpAndSettle();
      expect(api.lastQuery?['sourceDocNo'], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('currency header filter sends currencyId to API', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArApApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const MaterialApp(home: FinanceArApPage()),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<ArApLedgerItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<ArApLedgerItem>,
      ),
    );
    expect(table.facets.keys, contains('currency'));
    expect(table.facets['currency']?.single.value, 'currency-1');
    expect(table.facets['currency']?.single.label, '美元');

    api.lastQuery = null;
    table.onFilterChanged('currency', 'currency-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['currencyId'], 'currency-1');
    expect(api.lastQuery?['page'], 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legacy opening has a distinct source filter and no fabricated original document link',
    (tester) async {
      final api = _ArApApi(sourceDocType: 'LEGACY_OPENING');
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: const MaterialApp(home: FinanceArApPage()),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<ArApLedgerItem>>(
        find.byType(MasterDataTableView<ArApLedgerItem>),
      );
      final source = table.columns.singleWhere(
        (column) => column.key == 'sourceDocType',
      );
      expect(source.value(table.items.single), '历史期初（原单来源待核实）');
      final resolution = table.columns.singleWhere(
        (column) => column.key == 'legacySourceResolution',
      );
      expect(resolution.value(table.items.single), '原单有多个匹配');
      expect(resolution.sortable, isFalse);
      expect(table.items.single.sourceDocId, isNull);
      expect(table.onRowTap, isNull);
      final bucket = table.facets['sourceDocType']!.singleWhere(
        (entry) => entry.value == 'LEGACY_OPENING',
      );
      expect(bucket.label, '历史期初（原单来源待核实）');
      table.onFilterChanged('sourceDocType', bucket.value);
      await tester.pumpAndSettle();
      expect(api.lastQuery?['sourceDocType'], 'LEGACY_OPENING');
      expect(api.lastQuery?['page'], 1);
    },
  );

  testWidgets('ordinary ledger headers query full scope and keep exact facts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArApApi(exactFacts: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const MaterialApp(home: FinanceArApPage()),
      ),
    );
    await tester.pumpAndSettle();
    MasterDataTableView<ArApLedgerItem> table() =>
        tester.widget(find.byType(MasterDataTableView<ArApLedgerItem>));
    final columns = {for (final column in table().columns) column.key: column};
    final item = table().items.single;
    expect(
      columns['amountOriginal']!.exactValueOf!(item),
      '90071992547409.1234',
    );
    expect(columns['exchangeRate']!.value(item), '1.234567');
    expect(columns['openItemKind']!.value(item), '客户预收');
    expect(
      columns['prepaymentAppliedOriginal']!.exactValueOf!(item),
      '-12.3456',
    );
    expect(
      table().serverColumnSearchKeys,
      containsAll([
        'party',
        'remark',
        'salesOrderNos',
        'dueDate',
        'amountOriginal',
        'legacySourceResolution',
      ]),
    );
    expect(table().summaryBar, isNull);
    table().onFilterChanged('currency', 'retired-usd');
    await tester.pumpAndSettle();
    table().onFilterChanged('search.amountOriginal', '>=90071992547409.1234');
    await tester.pumpAndSettle();
    table().onFilterChanged('search.dueDate', '2026-09..2026-10');
    await tester.pumpAndSettle();
    table().onFilterChanged('search.salesOrderNos', 'SO%_ A B');
    await tester.pumpAndSettle();
    table().onFilterChanged('legacySourceResolution', 'EXACT_SOURCE');
    await tester.pumpAndSettle();
    expect(
      api.lastQuery,
      containsPair('search.amountOriginal', '>=90071992547409.1234'),
    );
    expect(api.lastQuery, containsPair('search.dueDate', '2026-09..2026-10'));
    expect(api.lastQuery, containsPair('search.salesOrderNos', 'SO%_ A B'));
    expect(
      api.lastQuery,
      containsPair('legacySourceResolution', 'EXACT_SOURCE'),
    );
    expect(api.lastQuery, containsPair('currencyId', 'retired-usd'));
    expect(api.lastQuery, containsPair('page', 1));
    expect(
      api.facetQuery,
      containsPair('search.amountOriginal', '>=90071992547409.1234'),
    );
    expect(
      table().facets['currency']!.map((item) => item.value),
      contains('retired-usd'),
    );
    table().onFilterChanged('currency', null);
    await tester.pumpAndSettle();
    expect(api.lastQuery!['search.amountOriginal'], isNull);
    expect(api.lastQuery!['search.dueDate'], '2026-09..2026-10');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AP direction clears AR-only criteria and never labels supplier offsets as prepayments',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ArApApi(exactFacts: true, direction: 'AP');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: const MaterialApp(home: FinanceArApPage()),
        ),
      );
      await tester.pumpAndSettle();
      MasterDataTableView<ArApLedgerItem> table() =>
          tester.widget(find.byType(MasterDataTableView<ArApLedgerItem>));
      final prepay = table().columns.singleWhere(
        (column) => column.key == 'prepaymentAppliedOriginal',
      );
      expect(prepay.value(table().items.single), '—');
      expect(prepay.exactValueOf!(table().items.single), isNull);
      expect(table().items.single.prepaymentAppliedOriginal, isNull);
      table().onFilterChanged('currency', 'retired-usd');
      await tester.pumpAndSettle();
      table().onFilterChanged('search.salesOrderNos', 'SO-OTHER-PAGE');
      await tester.pumpAndSettle();
      table().onFilterChanged('search.prepaymentAppliedOriginal', '>0');
      await tester.pumpAndSettle();
      table().onFilterChanged('direction', 'AP');
      await tester.pumpAndSettle();
      expect(api.lastQuery!['search.salesOrderNos'], isNull);
      expect(api.lastQuery!['search.prepaymentAppliedOriginal'], isNull);
      expect(
        table().columns.map((column) => column.key),
        isNot(contains('prepaymentAppliedOriginal')),
      );
      expect(
        table().columns.map((column) => column.key),
        isNot(contains('salesOrderNos')),
      );
    },
  );
}

class _ArApApi extends ApiClient {
  _ArApApi({this.sourceDocType, this.exactFacts = false, this.direction = 'AR'})
    : super(Dio());

  final String? sourceDocType;
  final bool exactFacts;
  final String direction;

  Map<String, dynamic>? lastQuery;
  Map<String, dynamic>? facetQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/ar-ap/facets') {
      facetQuery = Map.of(query ?? const {});
      return {
        'billNo': const <Map<String, dynamic>>[],
        'sourceDocNo': const <Map<String, dynamic>>[],
        'currency': [
          if (exactFacts)
            {'value': 'retired-usd', 'label': '美元（历史引用）', 'count': 0},
        ],
      };
    }
    if (path == '/finance/ar-ap') {
      lastQuery = query == null ? null : Map<String, dynamic>.from(query);
      return <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'ledger-1',
            'direction': direction,
            if (exactFacts) 'openItemKind': 'CUSTOMER_PREPAYMENT',
            if (exactFacts) 'amountOriginalExact': '90071992547409.1234',
            if (exactFacts) 'exchangeRateExact': '1.234567',
            if (exactFacts) 'amountOffsetOriginalExact': '-12.3456',
            'sourceDocType': sourceDocType,
            'legacySourceResolution': sourceDocType == 'LEGACY_OPENING'
                ? {'status': 'AMBIGUOUS_SOURCE'}
                : null,
            'sourceDocId': null,
            'billNo': 'AR-20260808-001',
            'billDate': '2026-08-08',
            'dueDate': '2026-09-07',
            'settlementStyleLegacy': 6,
            'currencyCode': '001',
            'currencyName': '人民币',
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
  }) async {
    if (path.contains('currencies')) {
      return const [
        {'id': 'currency-1', 'name': '美元'},
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}
