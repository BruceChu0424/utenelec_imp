import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/account_balance_reconciliation_dialog.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'forces CNY re-entry without consulting the currency reference rate',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final accountRepository = _AccountRepositoryFake();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(accountRepository),
            currencyRepositoryProvider.overrideWithValue(
              _CurrencyRepositoryFake(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(home: _OpenDialogHost()),
        ),
      );
      await tester.tap(find.text('打开余额核对'));
      await tester.pumpAndSettle();

      final target = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '重新输入',
      );
      final reason = find.byKey(const ValueKey('account-balance-reason'));
      expect(target, findsOneWidget);
      expect((tester.widget<TextField>(target).controller?.text), isEmpty);

      await tester.enterText(target, '99999999999999.1235');
      await tester.enterText(reason, '新系统上线余额复核');
      await tester.tap(find.text('提交核对（1）'));
      await tester.pumpAndSettle();

      expect(find.text('确认提交余额核对'), findsOneWidget);
      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();

      final input = accountRepository.inputs.single;
      expect(input.expectedBalance, '99999999999999.1234');
      expect(input.targetBalance, '99999999999999.1235');
      expect(input.localDelta, isNull);
      expect(find.textContaining('参考汇率'), findsNothing);
      expect(
        accountRepository.idempotencyKey,
        matches(RegExp(r'^[0-9a-f-]{36}$')),
      );
    },
  );

  testWidgets(
    'foreign UUID requires local GL delta even when editable labels pretend CNY',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final accountRepository = _AccountRepositoryFake(foreign: true);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(accountRepository),
            currencyRepositoryProvider.overrideWithValue(
              _CurrencyRepositoryFake(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(home: _OpenDialogHost()),
        ),
      );
      await tester.tap(find.text('打开余额核对'));
      await tester.pumpAndSettle();

      expect(find.textContaining('参考汇率'), findsNothing);
      expect(find.textContaining('账户币种：'), findsOneWidget);
      expect(find.textContaining('人民币'), findsWidgets);

      final target = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '重新输入',
      );
      final reason = find.byKey(const ValueKey('account-balance-reason'));
      await tester.enterText(target, '101.0000');
      await tester.pump();

      final localDelta = find.byKey(
        const ValueKey('account-local-delta-account-usd'),
      );
      expect(localDelta, findsOneWidget);
      // 说明收进标签旁 ⓘ 悬停提示（fieldLabel 约定）。
      expect(find.byTooltip('只用于总账，不改变账户原币余额'), findsOneWidget);

      await tester.enterText(reason, '美元账户上线余额复核');
      await tester.tap(find.text('提交核对（1）'));
      await tester.pump();
      expect(find.text('外币余额变化时必须填写本位币调账额'), findsOneWidget);

      await tester.enterText(localDelta, '7.2000');
      await tester.tap(find.text('提交核对（1）'));
      await tester.pumpAndSettle();
      expect(find.text('确认提交余额核对'), findsOneWidget);
      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();

      final input = accountRepository.inputs.single;
      expect(input.expectedBalance, '100.0000');
      expect(input.targetBalance, '101.0000');
      expect(input.localDelta, '7.2000');
    },
  );

  testWidgets(
    'fill all active targets with zero confirms overwrite, supports undo, and keeps foreign GL explicit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final accountRepository = _AccountRepositoryFake(
        accountItems: const [
          AccountListItem(
            id: 'account-cny',
            code: 'ZH000001',
            name: '人民币基本户',
            accountType: 'BANK',
            currencyId: 'currency-cny',
            currencyCode: 'CNY',
            currencyName: '人民币',
            baseCurrency: true,
            balanceCurrent: 50,
            balanceCurrentText: '50.0000',
            status: '使用',
          ),
          AccountListItem(
            id: 'account-usd',
            code: 'ZH000002',
            name: '美元账户',
            accountType: 'OFFSHORE',
            currencyId: 'currency-usd',
            currencyCode: 'USD',
            currencyName: '美元',
            balanceCurrent: 100,
            balanceCurrentText: '100.0000',
            status: '使用',
          ),
          AccountListItem(
            id: 'account-disabled',
            code: 'ZH000003',
            name: '已禁用旧账户',
            accountType: 'BANK',
            currencyId: 'currency-cny',
            currencyCode: 'CNY',
            currencyName: '人民币',
            baseCurrency: true,
            balanceCurrent: 999,
            balanceCurrentText: '999.0000',
            status: '禁用',
          ),
        ],
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(accountRepository),
            currencyRepositoryProvider.overrideWithValue(
              _CurrencyRepositoryFake(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(home: _OpenDialogHost()),
        ),
      );
      await tester.tap(find.text('打开余额核对'));
      await tester.pumpAndSettle();

      final targets = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '重新输入',
      );
      expect(targets, findsNWidgets(2));
      expect(find.text('已禁用旧账户'), findsNothing);

      await tester.enterText(targets.first, '12.0000');
      await tester.tap(find.text('全部使用中账户目标填 0'));
      await tester.pumpAndSettle();
      expect(find.text('覆盖现有金额输入？'), findsOneWidget);

      await tester.tap(find.text('覆盖并填 0'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(targets.at(0)).controller?.text, '0');
      expect(tester.widget<TextField>(targets.at(1)).controller?.text, '0');
      expect(find.text('已填 0，尚未提交'), findsOneWidget);
      expect(find.text('撤销填 0'), findsOneWidget);

      await tester.tap(find.text('撤销填 0'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(targets.at(0)).controller?.text,
        '12.0000',
      );
      expect(tester.widget<TextField>(targets.at(1)).controller?.text, isEmpty);
      expect(find.text('已填 0，尚未提交'), findsNothing);

      await tester.enterText(targets.at(0), '');
      await tester.tap(find.text('全部使用中账户目标填 0'));
      await tester.pumpAndSettle();
      expect(find.text('覆盖现有金额输入？'), findsNothing);

      final reason = find.byKey(
        const ValueKey('account-balance-reason'),
        skipOffstage: false,
      );
      await tester.ensureVisible(reason);
      await tester.pump();
      await tester.enterText(reason, '新系统启用前使用中账户当前余额归零');
      await tester.tap(find.text('提交核对（2）'));
      await tester.pump();
      expect(find.text('外币余额变化时必须填写本位币调账额'), findsOneWidget);

      final localDelta = find.byKey(
        const ValueKey('account-local-delta-account-usd'),
        skipOffstage: false,
      );
      await tester.ensureVisible(localDelta);
      await tester.pump();
      await tester.enterText(localDelta, '-700.0000');
      await tester.tap(find.text('提交核对（2）'));
      await tester.pumpAndSettle();

      expect(find.text('确认提交余额核对'), findsOneWidget);
      expect(find.textContaining('禁用账户不参与'), findsOneWidget);
      expect(find.textContaining('既有流水和总账历史均保留'), findsOneWidget);
      await tester.tap(find.text('确认归零并提交'));
      await tester.pumpAndSettle();

      expect(accountRepository.scope, AccountBalanceAdjustmentScope.full);
      expect(accountRepository.inputs.map((item) => item.accountId), [
        'account-cny',
        'account-usd',
      ]);
      expect(accountRepository.inputs[0].targetBalance, '0.0000');
      expect(accountRepository.inputs[0].localDelta, isNull);
      expect(accountRepository.inputs[1].targetBalance, '0.0000');
      expect(accountRepository.inputs[1].localDelta, '-700.0000');
    },
  );
}

class _OpenDialogHost extends StatelessWidget {
  const _OpenDialogHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => showAccountBalanceReconciliationDialog(context),
          child: const Text('打开余额核对'),
        ),
      ),
    );
  }
}

class _AccountRepositoryFake implements AccountRepository {
  _AccountRepositoryFake({this.foreign = false, this.accountItems});

  final bool foreign;
  final List<AccountListItem>? accountItems;
  List<AccountBalanceAdjustmentInput> inputs = const [];
  String? idempotencyKey;
  AccountBalanceAdjustmentScope? scope;

  @override
  Future<List<AccountListItem>> dict() async {
    if (accountItems != null) return accountItems!;
    return foreign
        ? const [
            AccountListItem(
              id: 'account-usd',
              code: 'ZH000002',
              name: '美金账户',
              accountType: 'BANK',
              currencyId: 'currency-usd',
              currencyCode: 'CNY',
              currencyName: '人民币',
              exchangeRate: 0,
              exchangeRateText: '0',
              balanceCurrent: 100,
              balanceCurrentText: '100.0000',
              status: '使用',
            ),
          ]
        : const [
            AccountListItem(
              id: 'account-1',
              code: 'ZH000001',
              name: '人民币基本户',
              accountType: 'BANK',
              currencyId: 'currency-cny',
              currencyCode: 'USD',
              currencyName: '美金',
              baseCurrency: true,
              balanceCurrent: 99999999999999.12,
              balanceCurrentText: '99999999999999.1234',
              status: '使用',
            ),
          ];
  }

  @override
  Future<AccountBalanceAdjustmentBatchResult> adjustBalances({
    required AccountBalanceAdjustmentScope scope,
    required String effectiveDate,
    required String reason,
    required String idempotencyKey,
    required List<AccountBalanceAdjustmentInput> items,
  }) async {
    inputs = items;
    this.idempotencyKey = idempotencyKey;
    this.scope = scope;
    return AccountBalanceAdjustmentBatchResult(
      id: 'batch-1',
      batchNo: 'AB260001',
      scope: 'FULL',
      effectiveDate: '2026-08-27',
      reason: '新系统上线余额复核',
      itemCount: items.length,
      changedCount: items.length,
      items: const [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CurrencyRepositoryFake implements CurrencyRepository {
  @override
  Future<List<CurrencyListItem>> dict() async => const [
    CurrencyListItem(
      id: 'currency-cny',
      code: 'CNY',
      name: '人民币',
      exchangeRate: 0,
      exchangeRateText: '0',
      baseCurrency: true,
      status: '使用',
    ),
    CurrencyListItem(
      id: 'currency-usd',
      code: 'USD',
      name: '美金',
      exchangeRate: 0,
      exchangeRateText: '0',
      status: '使用',
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
