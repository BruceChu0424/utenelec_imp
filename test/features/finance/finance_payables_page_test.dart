import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/repositories/finance_payables_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final scenario in [
    (
      name: 'positive',
      amount: '12.0000',
      currency: 'currency-1',
      allowed: true,
    ),
    (
      name: 'negative',
      amount: '-12.0000',
      currency: 'currency-1',
      allowed: false,
    ),
    (name: 'zero', amount: '0.0000', currency: 'currency-1', allowed: false),
    (
      name: 'unknown original',
      amount: null,
      currency: 'currency-1',
      allowed: false,
    ),
    (
      name: 'unknown currency',
      amount: '12.0000',
      currency: null,
      allowed: false,
    ),
  ]) {
    testWidgets('legacy payable ${scenario.name} payment eligibility', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final api = _PageApi(
        itemOverrides: {
          'businessType': 'DIRECT',
          'sourceDocType': 'LEGACY_OPENING',
          'openItemKind': 'LEGACY_UNVERIFIED',
          'outstandingOriginal': scenario.amount,
          'currencyId': scenario.currency,
        },
      );
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
              Perm.financePaymentCreate,
            }),
          ],
          child: const MaterialApp(home: FinancePayablesPage()),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<FinancePayableItem>>(
        find.byType(MasterDataTableView<FinancePayableItem>),
      );
      final item = table.items.single;
      expect(item.openItemKindLabel, '历史往来余额');
      expect(item.sourceTypeLabel, '历史期初（原单来源待核实）');
      expect(item.businessTypeLabel, '其他往来');
      table.onFilterChanged('businessType', 'DIRECT');
      await tester.pumpAndSettle();
      expect(api.lastQuery?['businessType'], 'DIRECT');
      table.onSelectedIdsChanged!({'ap-1'});
      await tester.pump();
      final button = tester.widget<UtenButton>(
        find.byKey(const ValueKey('finance-payables-create-payment')),
      );
      expect(button.onPressed != null, scenario.allowed);
      expect(tester.takeException(), isNull);
    });
  }

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

    // 2026-09-16 币种表头筛选：currencies/dict 桶回传 currencyId。
    expect(table.facets.keys, contains('currencyCode'));
    expect(table.facets['currencyCode']?.single.value, 'currency-1');
    table.onFilterChanged('currencyCode', 'currency-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['currencyId'], 'currency-1');
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
    expect(
      find.byKey(const ValueKey('finance-payables-open-filters')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('finance-payables-open-filters')),
    );
    await tester.pumpAndSettle();
    expect(find.text('筛选应付记录'), findsOneWidget);
    expect(find.text('业务类型'), findsWidgets);
    expect(find.text('结算状态'), findsWidgets);

    await tester.tap(find.text('采购'));
    await tester.pumpAndSettle();
    expect(api.lastQuery?['businessType'], 'PURCHASE');

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('筛选(1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide scroll collapses summary before table body takes over', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _PageApi(itemCount: 60);
    tester.view.physicalSize = const Size(1440, 760);
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

    final nestedFinder = find.byType(NestedScrollView);
    final summaryFinder = find.byKey(
      const ValueKey('finance-payables-summary-panel'),
    );
    final tableFinder = find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<FinancePayableItem>,
    );
    final table = tester.widget<MasterDataTableView<FinancePayableItem>>(
      tableFinder,
    );
    final nestedState = tester.state<NestedScrollViewState>(nestedFinder);
    final pointer = TestPointer(7, PointerDeviceKind.mouse);
    final tableCenter = tester.getCenter(tableFinder);

    expect(table.primary, isTrue);
    expect(
      find.byKey(const ValueKey('finance-payables-table-toolbar')),
      findsOneWidget,
    );
    expect(nestedState.innerController.offset, 0);
    final summaryTopBefore = tester.getTopLeft(summaryFinder).dy;

    await tester.sendEventToBinding(pointer.hover(tableCenter));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 80)));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(summaryFinder).dy, lessThan(summaryTopBefore));
    expect(nestedState.innerController.offset, closeTo(0, 0.5));

    final outer = nestedState.outerController;
    final remainingHeader =
        outer.position.maxScrollExtent - outer.position.pixels;
    await tester.sendEventToBinding(pointer.scroll(Offset(0, remainingHeader)));
    await tester.pumpAndSettle();

    expect(outer.position.pixels, closeTo(outer.position.maxScrollExtent, 0.5));
    expect(nestedState.innerController.offset, closeTo(0, 0.5));

    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();

    expect(nestedState.innerController.offset, greaterThan(0));
    final innerOffset = nestedState.innerController.offset;

    await tester.sendEventToBinding(pointer.scroll(Offset(0, -innerOffset)));
    await tester.pumpAndSettle();

    expect(nestedState.innerController.offset, closeTo(0, 0.5));
    expect(outer.position.pixels, closeTo(outer.position.maxScrollExtent, 0.5));

    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -80)));
    await tester.pumpAndSettle();

    expect(outer.position.pixels, lessThan(outer.position.maxScrollExtent));
    expect(summaryFinder, findsOneWidget);
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
  _PageApi({this.itemCount = 1, this.itemOverrides = const {}}) : super(Dio());

  final int itemCount;
  final Map<String, dynamic> itemOverrides;
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
        for (var index = 1; index <= itemCount; index++)
          <String, dynamic>{
            'id': 'ap-$index',
            'businessType': 'SUBCONTRACT',
            'openItemKind': 'PAYABLE',
            'sourceDocType': 'SUBCONTRACT_RECEIPT',
            'sourceDocNo': 'SWI-$index',
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
            ...itemOverrides,
          },
      ],
      'page': 1,
      'size': itemCount,
      'total': itemCount,
      'totalPages': 1,
    };
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
    return const [];
  }
}
