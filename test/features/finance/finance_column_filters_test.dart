import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/finance/pages/finance_reconciliation_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'raw account flow headers retain exact money, full lineage and complete source choices',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _FinanceFilterApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(home: FinanceReconciliationPage()),
        ),
      );
      await tester.pumpAndSettle();
      MasterDataTableView<ReconciliationItem> table() => tester.widget(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<ReconciliationItem>,
        ),
      );
      expect(
        table().facets['sourceDocType']!.map((item) => item.value),
        containsAll(['RECEIPT_FEE', 'SUPPLIER_CLAIM_RECEIPT']),
      );
      table().onFilterChanged('accountId', 'account-1');
      await tester.pumpAndSettle();
      final header = find.byKey(
        const ValueKey('master-column-filter-inAmount'),
      );
      await tester.ensureVisible(header);
      await tester.pumpAndSettle();
      final rect = tester.getRect(header);
      await tester.tapAt(Offset(rect.left + 16, rect.center.dy));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '>=90071992547409.1234',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      table().onFilterChanged('search.counterpartName', '对方%_');
      await tester.pumpAndSettle();
      const original = '11111111-2222-3333-4444-555555555555';
      table().onFilterChanged('search.reversalOfId', original);
      await tester.pumpAndSettle();
      expect(api.lastQuery?['search.inAmount'], '>=90071992547409.1234');
      expect(api.lastQuery?['search.counterpartName'], '对方%_');
      expect(api.lastQuery?['search.reversalOfId'], original);
      final money = table().columns.singleWhere(
        (column) => column.key == 'inAmount',
      );
      expect(money.exactValueOf!(table().items.single), '90071992547409.1234');
      expect(money.value(table().items.single), '90071992547409.1234');
      table().onFilterChanged('accountId', null);
      await tester.pumpAndSettle();
      expect(
        api.lastQuery?.containsKey('search.inAmount'),
        isFalse,
        reason: '清账户时移除不再有原币资格的金额条件',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final type in FinanceDocType.values) {
    testWidgets(
      '${type.name} ordinary headers send exact server conditions and scope candidate counts',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 950));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _FinanceFilterApi();
        final router = GoRouter(
          initialLocation: '/finance/${type.pathSegment}',
          routes: [
            GoRoute(
              path: '/finance/${type.pathSegment}',
              builder: (_, _) =>
                  FinanceDocListPage(docType: type, initialStatus: 'draft'),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        final amountHeader = tester.getRect(
          find.byKey(const ValueKey('master-column-filter-amountLocal')),
        );
        await tester.tapAt(
          Offset(amountHeader.left + 16, amountHeader.center.dy),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          '>=90071992547409.1234',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('master-column-filter-billDate')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          '2026-10-01..2026-10-31',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<dynamic>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<dynamic>,
          ),
        );
        table.onFilterChanged('search.billNo', 'SK_%');
        await tester.pumpAndSettle();
        expect(
          api.documentQueries.last['search.amountLocal'],
          '>=90071992547409.1234',
        );
        expect(
          api.documentQueries.last['search.billDate'],
          '2026-10-01..2026-10-31',
        );
        expect(api.documentQueries.last['search.billNo'], 'SK_%');
        expect(api.documentQueries.last['page'], 1);
        expect(
          api.facetQueries.last['search.amountLocal'],
          '>=90071992547409.1234',
        );
        expect(
          api.facetQueries.last['search.billDate'],
          '2026-10-01..2026-10-31',
        );
        expect(api.facetQueries.last.containsKey('search.billNo'), isFalse);
        expect(
          table.columns
              .singleWhere((column) => column.key == 'accountId')
              .facetSearchEnabled,
          isTrue,
        );
        api.rejectDocumentQuery = true;
        table.onFilterChanged('search.billNo', 'REJECTED-NEW-SCOPE');
        await tester.pumpAndSettle();
        final rejected = tester.widget<MasterDataTableView<dynamic>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<dynamic>,
          ),
        );
        expect(rejected.items, isEmpty, reason: '新条件失败不能沿用上一页正式行');
        expect(rejected.error, '暂时无法检索');
        expect(rejected.filters['search.billNo'], 'REJECTED-NEW-SCOPE');
        api.rejectDocumentQuery = false;
        rejected.onFilterChanged('search.billNo', null);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('finance document headers send UUID and status filters to API', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _FinanceFilterApi();
    final router = GoRouter(
      initialLocation: '/finance/receipts',
      routes: [
        GoRoute(
          path: '/finance/receipts',
          builder: (_, _) =>
              const FinanceDocListPage(docType: FinanceDocType.receipt),
        ),
        GoRoute(
          path: '/finance/receipts/:id',
          builder: (_, state) => Text(state.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.lastQuery, isNull, reason: '未选分类不能加载全部已过账凭证');
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();
    expect(api.lastQuery?['status'], 0);
    expect(api.lastQuery?['hf.recordOrigin'], 'CURRENT');
    await tester.tap(find.text('历史单据'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<FinanceDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinanceDocListItem>,
      ),
    );
    expect(
      table.facets.keys,
      containsAll(<String>['clientId', 'accountId', 'status']),
    );
    // Party candidates are paged on demand, not preloaded as a full dictionary.
    expect(table.facets['clientId'], isEmpty);
    final clients = (await tester.runAsync(
      () => table.facetPageLoaders['clientId']!('', 1),
    ))!;
    expect(clients.items.single.value, 'party-1');
    expect(clients.hasMore, isFalse);
    expect(api.clientQueries.single['page'], 1);
    expect(api.clientQueries.single['size'], 100);
    expect(api.clientQueries.single['excludeLegacyFinanceStub'], isTrue);
    expect(table.facets['accountId']?.single.value, 'account-1');

    table.onFilterChanged('clientId', 'party-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['clientId'], 'party-1');

    final refreshed = tester.widget<MasterDataTableView<FinanceDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinanceDocListItem>,
      ),
    );
    refreshed.onFilterChanged('accountId', 'account-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['accountId'], 'account-1');

    final statusTable = tester.widget<MasterDataTableView<FinanceDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinanceDocListItem>,
      ),
    );
    statusTable.onFilterChanged('status', '1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['status'], 1);
    expect(
      api.lastQuery?['hf.recordOrigin'],
      'CURRENT',
      reason: '明确当前状态细筛时，来源控件同步可见，避免把原始历史当成当前状态',
    );
    expect(api.lastQuery?['originScope'], 'CURRENT');
    expect(find.text('历史单据'), findsOneWidget);

    // 2026-09-16 收款类型表头筛选：固定枚举桶 + 回传 receiptKind 参数。
    final kindTable = tester.widget<MasterDataTableView<FinanceDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinanceDocListItem>,
      ),
    );
    expect(kindTable.facets.keys, contains('receiptKind'));
    expect(
      kindTable.facets['receiptKind']?.map((bucket) => bucket.value),
      containsAll(<String>['AR_SETTLEMENT', 'CUSTOMER_PREPAYMENT']),
    );
    kindTable.onFilterChanged('receiptKind', 'AR_SETTLEMENT');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['receiptKind'], 'AR_SETTLEMENT');
  });

  testWidgets('account flow headers send account and source filters to API', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _FinanceFilterApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(home: FinanceReconciliationPage()),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<ReconciliationItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<ReconciliationItem>,
      ),
    );
    expect(
      table.facets.keys,
      containsAll(<String>['accountId', 'sourceDocType']),
    );
    expect(
      table.facets['sourceDocType']?.map((bucket) => bucket.value),
      contains('RECEIPT'),
    );

    table.onFilterChanged('accountId', 'account-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['accountId'], 'account-1');

    final refreshed = tester.widget<MasterDataTableView<ReconciliationItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<ReconciliationItem>,
      ),
    );
    refreshed.onFilterChanged('sourceDocType', 'RECEIPT');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['sourceDocType'], 'RECEIPT');

    // 2026-09-16 流水类型表头筛选：固定枚举桶 + 回传 entryKind 参数。
    final kindTable = tester.widget<MasterDataTableView<ReconciliationItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<ReconciliationItem>,
      ),
    );
    expect(kindTable.facets.keys, contains('entryKind'));
    expect(
      kindTable.facets['entryKind']?.map((bucket) => bucket.value),
      containsAll(<String>['POSTING', 'REVERSAL', 'ADJUSTMENT']),
    );
    kindTable.onFilterChanged('entryKind', 'REVERSAL');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['entryKind'], 'REVERSAL');
    expect(api.lastQuery?['sourceDocType'], 'RECEIPT');
  });
}

class _FinanceFilterApi extends ApiClient {
  final documentQueries = <Map<String, dynamic>>[];
  bool rejectDocumentQuery = false;
  final facetQueries = <Map<String, dynamic>>[];
  _FinanceFilterApi() : super(Dio());

  Map<String, dynamic>? lastQuery;
  final clientQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/clients') {
      clientQueries.add(Map<String, dynamic>.from(query!));
      return {
        'items': [
          {'id': 'party-1', 'name': '客户甲'},
        ],
        'page': 1,
        'size': 100,
        'total': 1,
        'totalPages': 1,
      };
    }
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    const documents = {
      '/finance/receipts',
      '/finance/payments',
      '/finance/expenses',
      '/finance/incomes',
      '/finance/bank-transfers',
    };
    if (documents.contains(path)) {
      documentQueries.add(Map.of(query ?? const {}));
      if (rejectDocumentQuery) {
        throw ApiException('TEMPORARY', '暂时无法检索', httpStatus: 503);
      }
    }
    if (documents.any((document) => path == '$document/facets')) {
      facetQueries.add(Map.of(query ?? const {}));
    }
    if (path == '/finance/reconciliations') {
      return {
        'items': [
          {
            'id': 'flow-1',
            'billDate': '2026-08-29T08:00:00Z',
            'billNo': 'SK26080001',
            'accountId': 'account-1',
            'sourceDocType': 'RECEIPT',
            'entryKind': 'POSTING',
            'inAmount': 90071992547409.12,
            'inAmountExact': '90071992547409.1234',
            'outAmount': 0,
          },
        ],
        'page': 1,
        'total': 1,
        'totalPages': 1,
      };
    }
    return {
      'items': [
        {
          'id': 'receipt-1',
          'billNo': 'SK26080001',
          'billDate': '2026-08-29',
          'clientId': 'party-1',
          'accountId': 'account-1',
          'amountLocal': 100,
          'status': 1,
        },
      ],
      'page': 1,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('accounts')) {
      return const [
        {
          'id': 'account-1',
          'code': 'A001',
          'name': '基本户',
          'currencyCode': 'CNY',
          'currencyName': '人民币',
        },
      ];
    }
    if (path.contains('clients')) {
      return const [
        {'id': 'party-1', 'name': '客户甲'},
      ];
    }
    return const [];
  }
}
