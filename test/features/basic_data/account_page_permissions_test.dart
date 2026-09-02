import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/pages/account_detail_page.dart';
import 'package:uten_imp/features/basic_data/pages/account_page.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets(
    'without balance permission does not request summary or build money column',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake();
      final currencies = _CurrencyRepositoryFake();
      final styles = _PaymentStyleRepositoryFake();

      await _pumpPage(
        tester,
        repository,
        {Perm.accountView},
        currencyRepository: currencies,
        paymentStyleRepository: styles,
      );

      expect(repository.summaryCalls, 0);
      expect(currencies.dictCalls, 0);
      expect(styles.treeCalls, 0);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(currencies.dictCalls, 0);
      expect(styles.treeCalls, 0);
      final table = tester.widget<MasterDataTableView<AccountListItem>>(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<AccountListItem>,
        ),
      );
      expect(
        table.columns.map((column) => column.key),
        isNot(contains('balanceCurrent')),
      );
      expect(table.facets['accountType']!.single.display, '银行');
      expect(table.facets['currencyId']!.single.display, '人民币');
      expect(
        find.byKey(const ValueKey('account-balance-reconcile')),
        findsNothing,
      );
      expect(find.text('打开选中账户'), findsOneWidget);
      expect(find.textContaining('当前仅展示非敏感账户数量'), findsOneWidget);
      expect(find.text('99999999999999.1234'), findsNothing);
      final menu = table.rowMenuBuilder!(repository.item);
      final menuItems = menu.whereType<UtenMenuItem>().toList();
      expect(menuItems.map((item) => item.label), [
        '查看详情',
        '编辑账户',
        '余额校准',
        '停用账户',
        '删除账户',
      ]);
      expect(menuItems.first.enabled, isTrue);
      expect(menuItems.skip(1).every((item) => !item.enabled), isTrue);
    },
  );

  testWidgets(
    'removes status overview tiles and expands disabled accounts on demand',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake();
      final disabledCompleter = Completer<PagedResult<AccountListItem>>();
      repository.disabledCompleter = disabledCompleter;

      await _pumpPage(tester, repository, {Perm.accountView});

      expect(find.text('账户总数'), findsOneWidget);
      expect(find.text('使用中'), findsNothing);
      expect(find.text('已禁用'), findsNothing);

      final table = tester.widget<MasterDataTableView<AccountListItem>>(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<AccountListItem>,
        ),
      );
      expect(table.items, [repository.item]);
      expect(table.leadingGroups, isNotNull);
      expect(table.leadingGroups, hasLength(1));
      final disabledGroup = table.leadingGroups!.single;
      expect(disabledGroup.id, 'disabled');
      expect(disabledGroup.items, isEmpty);
      expect(repository.disabledListCalls, 0);

      final groupHeader = find.text('禁用账户(1)');
      expect(groupHeader, findsOneWidget);
      final collapsedSemantics = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .singleWhere((widget) => widget.properties.label == '禁用账户(1)，已折叠');
      expect(collapsedSemantics.properties.button, isTrue);
      expect(collapsedSemantics.properties.expanded, isFalse);
      expect(find.text('备用账户'), findsNothing);

      await tester.tap(groupHeader);
      await tester.pump();
      expect(repository.disabledListCalls, 1);
      expect(find.text('正在加载'), findsOneWidget);
      disabledCompleter.complete(repository.disabledPage());
      await tester.pumpAndSettle();
      final expandedSemantics = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .singleWhere((widget) => widget.properties.label == '禁用账户(1)，已展开');
      expect(expandedSemantics.properties.expanded, isTrue);
      expect(find.text('备用账户'), findsOneWidget);

      await tester.tap(groupHeader);
      await tester.pumpAndSettle();
      expect(find.text('备用账户'), findsNothing);

      await tester.tap(groupHeader);
      await tester.pumpAndSettle();
      expect(find.text('备用账户'), findsOneWidget);
      expect(repository.disabledListCalls, 1);

      await tester.tap(groupHeader);
      await tester.pumpAndSettle();

      table.onFilterChanged('status', '禁用');
      await tester.pumpAndSettle();
      final disabledOnlyTable = tester
          .widget<MasterDataTableView<AccountListItem>>(
            find.byWidgetPredicate(
              (widget) => widget is MasterDataTableView<AccountListItem>,
            ),
          );
      expect(disabledOnlyTable.items, [repository.disabledItem]);
      expect(disabledOnlyTable.leadingGroups, isEmpty);
      expect(find.text('备用账户'), findsOneWidget);

      disabledOnlyTable.onFilterChanged('status', null);
      await tester.pumpAndSettle();
      expect(find.text('备用账户'), findsNothing);

      final searchBar = tester.widget<UtenSearchBar>(
        find.byType(UtenSearchBar),
      );
      searchBar.onChanged!('备用');
      await tester.pumpAndSettle();
      final searchTable = tester.widget<MasterDataTableView<AccountListItem>>(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<AccountListItem>,
        ),
      );
      expect(searchTable.leadingGroups, isEmpty);
      expect(searchTable.items, contains(repository.disabledItem));
      expect(find.text('备用账户'), findsOneWidget);
    },
  );

  testWidgets('disabled group exposes inline error and retries in place', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _AccountRepositoryFake()..disabledFailuresRemaining = 1;

    await _pumpPage(tester, repository, {Perm.accountView});

    await tester.tap(find.text('禁用账户(1)'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败，重试'), findsOneWidget);
    expect(repository.disabledListCalls, 1);

    await tester.tap(find.text('加载失败，重试'));
    await tester.pumpAndSettle();
    expect(repository.disabledListCalls, 2);
    expect(find.text('备用账户'), findsOneWidget);
  });

  testWidgets('create loads currency and account styles only when requested', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _AccountRepositoryFake();
    final currencies = _CurrencyRepositoryFake();
    final styles = _PaymentStyleRepositoryFake();

    await _pumpPage(
      tester,
      repository,
      {Perm.accountView, Perm.accountCreate},
      currencyRepository: currencies,
      paymentStyleRepository: styles,
    );
    expect(currencies.dictCalls, 0);
    expect(styles.treeCalls, 0);

    await tester.tap(find.text('添加账户'));
    await tester.pumpAndSettle();

    expect(currencies.dictCalls, 1);
    expect(styles.treeCalls, 1);
    expect(find.text('新增账户'), findsOneWidget);
  });

  testWidgets('editing detail then back pops and refreshes the account row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _AccountRepositoryFake();

    await _pumpRoutedPage(tester, repository);
    expect(repository.activeListCalls, 1);

    final table = tester.widget<MasterDataTableView<AccountListItem>>(
      find.byType(MasterDataTableView<AccountListItem>),
    );
    table.onRowTap!(repository.item);
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailPage), findsOneWidget);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '基本户',
      ),
      '修改后基本户',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repository.updateCalls, 1);

    await tester.tap(find.byType(UtenBackButton));
    await tester.pumpAndSettle();

    expect(repository.activeListCalls, 2);
    expect(find.text('修改后基本户'), findsWidgets);
  });

  testWidgets(
    'balance permissions load per-currency summary and expose reconciliation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake();

      await _pumpPage(tester, repository, {
        Perm.accountView,
        Perm.accountBalanceView,
        Perm.accountBalanceAdjust,
      });

      expect(repository.summaryCalls, 1);
      final table = tester.widget<MasterDataTableView<AccountListItem>>(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<AccountListItem>,
        ),
      );
      expect(
        table.columns.map((column) => column.key),
        contains('balanceCurrent'),
      );
      expect(
        find.byKey(const ValueKey('account-balance-reconcile')),
        findsOneWidget,
      );
      final balanceMenu = table.rowMenuBuilder!(repository.item)
          .whereType<UtenMenuItem>()
          .singleWhere((item) => item.label == '余额校准');
      expect(balanceMenu.enabled, isTrue);
      expect(find.text('99999999999999.1234'), findsWidgets);
      expect(find.textContaining('不跨币种相加'), findsOneWidget);
      expect(find.textContaining('仅统计 1 个使用中账户'), findsOneWidget);
      expect(find.textContaining('美元'), findsNothing);
      expect(find.text('含负余额 1 个'), findsOneWidget);
      final warningIcon = tester.widget<Icon>(
        find.byIcon(Icons.warning_amber_rounded),
      );
      expect(
        warningIcon.color,
        Theme.of(tester.element(find.byIcon(Icons.warning_amber_rounded)))
            .colorScheme
            .error,
      );
    },
  );

  testWidgets(
    'compact workspace reaches fullscreen reconciliation without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake();

      await _pumpPage(tester, repository, {
        Perm.accountView,
        Perm.accountBalanceView,
        Perm.accountBalanceAdjust,
      });

      final reconcile = find.byKey(
        const ValueKey('account-balance-reconcile-compact'),
      );
      await tester.ensureVisible(reconcile);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(reconcile);
      await tester.pumpAndSettle();
      expect(find.text('账户余额核对'), findsOneWidget);
      expect(find.text('全部活动账户'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpPage(
  WidgetTester tester,
  _AccountRepositoryFake repository,
  Set<String> permissions, {
  _CurrencyRepositoryFake? currencyRepository,
  _PaymentStyleRepositoryFake? paymentStyleRepository,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        accountRepositoryProvider.overrideWithValue(repository),
        currencyRepositoryProvider.overrideWithValue(
          currencyRepository ?? _CurrencyRepositoryFake(),
        ),
        paymentStyleRepositoryProvider.overrideWithValue(
          paymentStyleRepository ?? _PaymentStyleRepositoryFake(),
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: const MaterialApp(home: AccountPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpRoutedPage(
  WidgetTester tester,
  _AccountRepositoryFake repository,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/basicinfo/account',
    routes: [
      GoRoute(
        path: '/basicinfo/account',
        builder: (_, _) => const AccountPage(),
      ),
      GoRoute(
        path: '/basicinfo/account/:id',
        builder: (_, state) =>
            AccountDetailPage(accountId: state.pathParameters['id']!),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue({
          Perm.accountView,
          Perm.accountEdit,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        accountRepositoryProvider.overrideWithValue(repository),
        currencyRepositoryProvider.overrideWithValue(_CurrencyRepositoryFake()),
        paymentStyleRepositoryProvider.overrideWithValue(
          _PaymentStyleRepositoryFake(),
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

class _AccountRepositoryFake implements AccountRepository {
  int summaryCalls = 0;
  int activeListCalls = 0;
  int disabledListCalls = 0;
  int updateCalls = 0;
  int disabledFailuresRemaining = 0;
  Completer<PagedResult<AccountListItem>>? disabledCompleter;
  final listFilters = <Map<String, String?>>[];

  AccountListItem item = const AccountListItem(
    id: 'account-1',
    code: 'ZH000001',
    name: '基本户',
    bankAccountNo: '6222',
    accountType: 'BANK',
    currencyId: 'currency-cny',
    balanceCurrent: 99999999999999.12,
    balanceCurrentText: '99999999999999.1234',
    status: '使用',
  );

  final disabledItem = const AccountListItem(
    id: 'account-disabled',
    code: 'ZH000002',
    name: '备用账户',
    bankAccountNo: '6333',
    accountType: 'BANK',
    currencyId: 'currency-cny',
    balanceCurrent: 0,
    balanceCurrentText: '0',
    status: '禁用',
  );

  @override
  Future<PagedResult<AccountListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    listFilters.add(Map<String, String?>.from(filters));
    if (filters['status'] == '使用') activeListCalls++;
    if (filters['status'] == '禁用') {
      disabledListCalls++;
      if (disabledFailuresRemaining > 0) {
        disabledFailuresRemaining--;
        throw Exception('temporary disabled group failure');
      }
      final pending = disabledCompleter;
      if (pending != null) {
        disabledCompleter = null;
        return pending.future;
      }
    }
    final items = switch (filters['status']) {
      '使用' => [item],
      '禁用' => [disabledItem],
      _ => [item, disabledItem],
    };
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }

  PagedResult<AccountListItem> disabledPage() => PagedResult(
    items: [disabledItem],
    page: 1,
    size: 100,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<AccountFacets> facets() async => const AccountFacets(
    fields: {
      'accountType': [MasterFacetBucket(value: 'BANK', count: 2)],
      'currencyId': [
        MasterFacetBucket(value: 'currency-cny', count: 2, label: 'CNY · 人民币'),
      ],
      'status': [
        MasterFacetBucket(value: '使用', count: 1),
        MasterFacetBucket(value: '禁用', count: 1),
      ],
    },
    nullCounts: {},
  );

  @override
  Future<AccountSummary> summary() async {
    summaryCalls++;
    return const AccountSummary(
      totalAccounts: 2,
      activeAccounts: 1,
      disabledAccounts: 1,
      warningAccounts: 0,
      negativeAccounts: 1,
      currencies: [
        AccountCurrencySummary(
          currencyId: 'currency-cny',
          currencyCode: 'CNY',
          currencyName: '人民币',
          accountCount: 2,
          activeAccountCount: 1,
          balanceTotal: 99999999999999.12,
          balanceTotalText: '99999999999999.1234',
          warningCount: 0,
          negativeCount: 0,
        ),
        AccountCurrencySummary(
          currencyId: 'currency-usd',
          currencyCode: 'USD',
          currencyName: '美元',
          accountCount: 1,
          activeAccountCount: 0,
          balanceTotal: 0,
          balanceTotalText: '0',
          warningCount: 0,
          negativeCount: 0,
        ),
      ],
    );
  }

  @override
  Future<List<AccountListItem>> dict() async => [item];

  @override
  Future<AccountDetail> detail(String id) async => AccountDetail(
    id: item.id,
    code: item.code,
    name: item.name,
    bankAccountNo: item.bankAccountNo,
    accountType: item.accountType,
    currencyId: item.currencyId,
    currencyCode: 'CNY',
    currencyName: '人民币',
    styleId: 'style-bank',
    balanceCurrent: item.balanceCurrent,
    balanceCurrentText: item.balanceCurrentText,
    status: item.status,
  );

  @override
  Future<AccountDetail> update(String id, Map<String, dynamic> body) async {
    updateCalls++;
    final name = body['name'] as String? ?? item.name;
    item = AccountListItem(
      id: item.id,
      code: body['code'] as String? ?? item.code,
      name: name,
      bankAccountNo: body['bankAccountNo'] as String? ?? item.bankAccountNo,
      accountType: body['accountType'] as String? ?? item.accountType,
      currencyId: body['currencyId'] as String? ?? item.currencyId,
      currencyCode: 'CNY',
      currencyName: '人民币',
      balanceCurrent: item.balanceCurrent,
      balanceCurrentText: item.balanceCurrentText,
      status: body['status'] as String? ?? item.status,
    );
    return detail(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CurrencyRepositoryFake implements CurrencyRepository {
  int dictCalls = 0;

  @override
  Future<List<CurrencyListItem>> dict() async {
    dictCalls++;
    return const [
      CurrencyListItem(
        id: 'currency-cny',
        code: 'CNY',
        name: '人民币',
        exchangeRate: 0,
        exchangeRateText: '0',
        status: '使用',
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PaymentStyleRepositoryFake implements PaymentStyleRepository {
  int treeCalls = 0;

  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async {
    treeCalls++;
    return [
      PaymentStyleNode(
        id: 'style-bank',
        code: '10201',
        name: '基本户',
        category: 'ACCOUNT',
        status: '使用',
        children: const [],
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
