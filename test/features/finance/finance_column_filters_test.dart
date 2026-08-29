import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/finance/pages/finance_reconciliation_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
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

    final table = tester.widget<MasterDataTableView<FinanceDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinanceDocListItem>,
      ),
    );
    expect(
      table.facets.keys,
      containsAll(<String>['clientId', 'accountId', 'status']),
    );
    expect(table.facets['clientId']?.single.value, 'party-1');
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
  });
}

class _FinanceFilterApi extends ApiClient {
  _FinanceFilterApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
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
            'inAmount': 100,
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
