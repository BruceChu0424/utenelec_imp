import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/repositories/finance_payables_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('renders KPI, payable columns and payment deep link', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _PageApi();
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/finance/payables',
      routes: [
        GoRoute(
          path: '/finance/payables',
          builder: (_, _) => const FinancePayablesPage(),
        ),
        GoRoute(
          path: '/finance/payments/new',
          builder: (_, state) => Scaffold(
            body: Text('付款预填 ${state.uri.queryParameters['payableIds'] ?? ''}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financePayablesRepositoryProvider.overrideWithValue(
            FinancePayablesRepository(api),
          ),
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          settlementMethodOptionsProvider.overrideWith((_) async => const []),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.arApLedgerView,
            Perm.financeViewAll,
            Perm.financePaymentView,
            Perm.financePaymentCreate,
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('应付结算工作台'), findsOneWidget);
    expect(find.text('应付(本币)'), findsNWidgets(2));
    expect(find.text('¥10000.00'), findsOneWidget);
    expect(find.text('逾期(本币)'), findsOneWidget);
    expect(find.text('¥5000.00'), findsOneWidget);
    expect(find.text('账面核销(本币)'), findsOneWidget);
    expect(find.text('汇兑差额(本币)'), findsOneWidget);
    expect(find.textContaining('应付 − 账面核销 − 抵销 = 未付'), findsOneWidget);

    final table = tester.widget<MasterDataTableView<FinancePayableItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinancePayableItem>,
      ),
    );
    final columns = {for (final column in table.columns) column.key: column};
    final item = table.items.single;
    expect(columns['businessType']?.value(item), '委外');
    expect(columns['sourceDocType']?.value(item), '委外进仓');
    expect(columns['openItemKind']?.value(item), '正应付');
    expect(columns['currencyCode']?.value(item), '人民币');
    expect(columns['grossOriginal']?.label, '应付(原币)');
    expect(columns['grossLocal']?.label, '应付(本币)');
    expect(columns['paidOriginal']?.label, '现金已付(原币)');
    expect(columns['paidLocal']?.label, '现金已付(本币)');
    expect(columns['offsetOriginal']?.label, '抵销(原币)');
    expect(columns['offsetLocal']?.label, '抵销(本币)');
    expect(columns['outstandingOriginal']?.label, '未付(原币)');
    expect(columns['outstandingLocal']?.label, '未付(本币)');
    expect(columns['outstandingOriginal']?.value(item), '5200.00');
    expect(columns['outstandingLocal']?.value(item), '5200.00');
    expect(
      table.facets.keys,
      containsAll(<String>[
        'businessType',
        'supplierName',
        'settlementMethod',
        'status',
      ]),
    );
    expect(
      table.facets['businessType']?.map((bucket) => bucket.value),
      containsAll(<String>['PURCHASE', 'SUBCONTRACT']),
    );

    table.onFilterChanged('businessType', 'PURCHASE');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['businessType'], 'PURCHASE');

    final refreshedTable = tester
        .widget<MasterDataTableView<FinancePayableItem>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<FinancePayableItem>,
          ),
        );
    refreshedTable.onSelectedIdsChanged?.call({'ap-1'});
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('finance-payables-create-payment')),
    );
    await tester.pumpAndSettle();
    expect(find.text('付款预填 ap-1'), findsOneWidget);
  });

  testWidgets('compact layout keeps filters and table reachable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _PageApi();
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financePayablesRepositoryProvider.overrideWithValue(
            FinancePayablesRepository(api),
          ),
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          settlementMethodOptionsProvider.overrideWith((_) async => const []),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.arApLedgerView,
            Perm.financeViewAll,
          }),
        ],
        child: const MaterialApp(home: FinancePayablesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('finance-payables-kpi-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('finance-payables-search')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinancePayableItem>,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('payment location is stable and deduplicates payable ids', () {
    expect(
      financePayablesPaymentLocation(['b', 'a', 'b']),
      '/finance/payments/new?payableIds=a%2Cb',
    );
  });
}

class _PageApi extends ApiClient {
  _PageApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    return <String, dynamic>{
      'summary': <String, dynamic>{
        'payableLocal': '10000.00',
        'paidLocal': '4000.00',
        'settledBookLocal': '4800.00',
        'exchangeDifferenceLocal': '-800.00',
        'offsetLocal': '800.00',
        'outstandingLocal': '5200.00',
        'overdueLocal': '5000.00',
        'dueThisMonthLocal': '5100.00',
        'creditLocal': '300.00',
        'prepaymentLocal': '200.00',
        'pendingLossCases': 2,
      },
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'ap-1',
          'businessType': 'SUBCONTRACT',
          'openItemKind': 'PAYABLE',
          'sourceDocType': 'SUBCONTRACT_RECEIPT',
          'sourceDocNo': 'SWI-001',
          'supplierCode': 'V60001',
          'supplierName': '精密加工厂',
          'billDate': '2026-08-20',
          'dueDate': '2026-08-31',
          'settlementMethodName': '月结',
          'currencyCode': '001',
          'currencyName': '人民币',
          'grossOriginal': '10000.00',
          'grossLocal': '10000.00',
          'paidOriginal': '4000.00',
          'paidLocal': '4000.00',
          'offsetOriginal': '800.00',
          'offsetLocal': '800.00',
          'outstandingOriginal': '5200.00',
          'outstandingLocal': '5200.00',
          'status': 'OVERDUE',
          'overdueDays': 7,
        },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
    };
  }
}
