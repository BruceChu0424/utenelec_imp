import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/pages/account_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('without balance permission never requests or renders money', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _AccountRepositoryFake();
    final currencies = _CurrencyRepositoryFake();
    final styles = _PaymentStyleRepositoryFake();

    await _pumpDetail(
      tester,
      repository,
      {Perm.accountView, Perm.accountWarningManage},
      currencyRepository: currencies,
      paymentStyleRepository: styles,
    );

    expect(repository.statementCalls, 0);
    expect(currencies.dictCalls, 0);
    expect(styles.treeCalls, 0);
    expect(find.textContaining('未获授权查看余额与流水金额'), findsOneWidget);
    expect(find.text('99999999999999.1234'), findsNothing);
    expect(find.text('设置警戒线'), findsNothing);
  });

  testWidgets(
    'flow permission loads statement and exposes search/date filters',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake();

      await _pumpDetail(tester, repository, {
        Perm.accountView,
        Perm.accountBalanceView,
        Perm.accountFlowView,
      });

      expect(repository.statementCalls, 1);
      expect(find.text('搜索单号、对方单位或摘要'), findsOneWidget);
      // 2026-09-11 撤掉「查询」按钮（全站同改）：改日期即查、搜索防抖/回车即查。
      expect(find.text('查询'), findsNothing);
      expect(find.text('清除'), findsOneWidget);
      expect(find.textContaining('起 20'), findsOneWidget);
      expect(find.textContaining('止 20'), findsOneWidget);
    },
  );

  testWidgets('edit lazily loads references and uses PUT response in place', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _AccountRepositoryFake();
    final currencies = _CurrencyRepositoryFake();
    final styles = _PaymentStyleRepositoryFake();

    await _pumpDetail(
      tester,
      repository,
      {Perm.accountView, Perm.accountEdit},
      currencyRepository: currencies,
      paymentStyleRepository: styles,
    );
    expect(repository.detailCalls, 1);
    expect(currencies.dictCalls, 0);
    expect(styles.treeCalls, 0);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(currencies.dictCalls, 1);
    expect(styles.treeCalls, 1);

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '人民币基本户',
      ),
      '修改后账户',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repository.updateCalls, 1);
    expect(repository.detailCalls, 1);
    expect(currencies.dictCalls, 1);
    expect(styles.treeCalls, 1);
    expect(find.text('修改后账户'), findsWidgets);
  });
}

Future<void> _pumpDetail(
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
        sharedPreferencesProvider.overrideWithValue(preferences),
        accountRepositoryProvider.overrideWithValue(repository),
        currencyRepositoryProvider.overrideWithValue(
          currencyRepository ?? _CurrencyRepositoryFake(),
        ),
        paymentStyleRepositoryProvider.overrideWithValue(
          paymentStyleRepository ?? _PaymentStyleRepositoryFake(),
        ),
      ],
      child: const MaterialApp(home: AccountDetailPage(accountId: 'account-1')),
    ),
  );
  await tester.pumpAndSettle();
}

class _AccountRepositoryFake implements AccountRepository {
  int detailCalls = 0;
  int statementCalls = 0;
  int updateCalls = 0;

  @override
  Future<AccountDetail> detail(String id) async {
    detailCalls++;
    return _detail();
  }

  @override
  Future<AccountDetail> update(String id, Map<String, dynamic> body) async {
    updateCalls++;
    return _detail(name: body['name'] as String? ?? '人民币基本户');
  }

  AccountDetail _detail({String name = '人民币基本户'}) => AccountDetail(
    id: 'account-1',
    code: 'ZH000001',
    name: name,
    bankAccountNo: '6222',
    accountType: 'BANK',
    currencyId: 'currency-cny',
    currencyCode: 'CNY',
    currencyName: '人民币',
    styleId: 'style-bank',
    initBalance: 99999999999999.12,
    initBalanceText: '99999999999999.1234',
    balanceCurrent: 99999999999999.12,
    balanceCurrentText: '99999999999999.1234',
    status: '使用',
  );

  @override
  Future<AccountStatementPage> statement({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    String? keyword,
    int page = 1,
    int size = 50,
  }) async {
    statementCalls++;
    return AccountStatementPage(
      rows: const [],
      page: page,
      size: size,
      total: 0,
      totalPages: 1,
    );
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
