import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/account_balance_reconciliation_dialog.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';

const _balancePermissions = {
  Perm.accountView,
  Perm.accountBalanceView,
  Perm.accountBalanceAdjust,
};

final _editorPermissions = StateProvider<Set<String>>(
  (ref) => _balancePermissions,
);
final _editorIdentity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'balance-editor'),
);

Finder _targetFields() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(
        'account-target-balance-',
      ),
);

UtenFieldHintIcon _localDeltaHint(WidgetTester tester) =>
    tester.widget<UtenFieldHintIcon>(
      find.descendant(
        of: find.byKey(
          const ValueKey('account-local-delta-account-usd'),
          skipOffstage: false,
        ),
        matching: find.byType(UtenFieldHintIcon, skipOffstage: false),
        skipOffstage: false,
      ),
    );

void main() {
  testWidgets(
    'balance search matches words across visible currency and account data and ranks names without changing scope',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _AccountRepositoryFake(
        accountItems: const [
          AccountListItem(
            id: 'code',
            code: 'MAIN',
            name: '别的账户',
            accountType: 'BANK',
            currencyId: 'currency-cny',
            currencyCode: 'CNY',
            currencyName: '人民币',
            status: '使用',
          ),
          AccountListItem(
            id: 'prefix',
            code: 'A',
            name: 'MAIN备用户',
            accountType: 'BANK',
            currencyId: 'currency-cny',
            currencyCode: 'CNY',
            currencyName: '人民币',
            status: '使用',
          ),
          AccountListItem(
            id: 'exact',
            code: 'Z',
            name: 'MAIN',
            accountType: 'BANK',
            currencyId: 'currency-cny',
            currencyCode: 'CNY',
            currencyName: '人民币',
            status: '使用',
          ),
          AccountListItem(
            id: 'disabled',
            code: 'X',
            name: 'MAIN禁用户',
            accountType: 'BANK',
            currencyId: 'currency-cny',
            status: '禁用',
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'balance-editor'),
            ),
            apiClientProvider.overrideWithValue(ApiClient(Dio())),
            currentPermissionsProvider.overrideWithValue(_balancePermissions),
            isSuperAdminProvider.overrideWithValue(false),
            accountRepositoryProvider.overrideWithValue(repository),
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
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == '搜索账户名称、编号、银行账号或币种',
      );
      await tester.enterText(search, 'MAIN');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('MAIN · Z')).dy,
        lessThan(tester.getTopLeft(find.text('MAIN备用户 · A')).dy),
      );
      expect(find.textContaining('MAIN禁用户'), findsNothing);
      await tester.enterText(search, 'MAIN CNY');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('MAIN备用户 · A'), findsOneWidget);
      expect(repository.inputs, isEmpty);
    },
  );

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
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'balance-editor'),
            ),
            apiClientProvider.overrideWithValue(ApiClient(Dio())),
            currentPermissionsProvider.overrideWithValue(_balancePermissions),
            isSuperAdminProvider.overrideWithValue(false),
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

      final target = _targetFields();
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
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'balance-editor'),
            ),
            apiClientProvider.overrideWithValue(ApiClient(Dio())),
            currentPermissionsProvider.overrideWithValue(_balancePermissions),
            isSuperAdminProvider.overrideWithValue(false),
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

      final target = _targetFields();
      final reason = find.byKey(const ValueKey('account-balance-reason'));
      await tester.enterText(target, '101.0000');
      await tester.pump();

      final localDelta = find.byKey(
        const ValueKey('account-local-delta-account-usd'),
      );
      expect(localDelta, findsOneWidget);
      // 说明收进标签旁 ⓘ 悬停提示（fieldLabel 约定）。
      final initialHint = _localDeltaHint(tester);
      expect(initialHint.info?.split('\n\n'), contains('只用于总账，不改变账户原币余额'));
      expect(initialHint.errorMessage, isNull);

      await tester.enterText(reason, '美元账户上线余额复核');
      await tester.tap(find.text('提交核对（1）'));
      await tester.pump();
      expect(find.text('外币余额变化时必须填写本位币调账额'), findsNothing);
      final requiredHint = _localDeltaHint(tester);
      expect(requiredHint.errorMessage, '外币余额变化时必须填写本位币调账额');
      expect(requiredHint.info?.split('\n\n'), contains('只用于总账，不改变账户原币余额'));

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
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'balance-editor'),
            ),
            apiClientProvider.overrideWithValue(ApiClient(Dio())),
            currentPermissionsProvider.overrideWithValue(_balancePermissions),
            isSuperAdminProvider.overrideWithValue(false),
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

      final targets = _targetFields();
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
      expect(find.text('外币余额变化时必须填写本位币调账额'), findsNothing);
      final requiredHint = _localDeltaHint(tester);
      expect(requiredHint.errorMessage, '外币余额变化时必须填写本位币调账额');
      expect(requiredHint.info?.split('\n\n'), contains('只用于总账，不改变账户原币余额'));

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

  testWidgets(
    'single balance edit loads one fresh account and preserves four-decimal target',
    (tester) async {
      final repository = _AccountRepositoryFake();
      await _pumpSingle(
        tester,
        repository,
        initialTarget: '99999999999999.1235',
      );
      expect(repository.detailCalls, 1);
      expect(repository.dictCalls, 0);
      expect(_targetFields(), findsOneWidget);
      expect(find.text('全部使用中账户目标填 0'), findsNothing);
      expect(find.text('仅选定账户'), findsNothing);
      expect(
        tester.widget<TextField>(_targetFields()).controller!.text,
        '99999999999999.1235',
      );
      await _enterSingleReason(tester, '上线账户盘点');
      await _saveSingle(tester);
      expect(repository.scope, AccountBalanceAdjustmentScope.selected);
      expect(repository.inputs.single.expectedBalance, '99999999999999.1234');
      expect(repository.inputs.single.targetBalance, '99999999999999.1235');
      expect(find.text('修改当前余额'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown balance submission freezes payload and retries the original command',
    (tester) async {
      final repository = _AccountRepositoryFake()
        ..nextError = NetworkTimeoutException();
      await _pumpSingle(tester, repository);
      await tester.enterText(_targetFields(), '12.3456');
      await _enterSingleReason(tester, '现金实盘');
      await _saveSingle(tester);
      expect(repository.attempts, hasLength(1));
      expect(tester.widget<TextField>(_targetFields()).enabled, isFalse);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('account-balance-reason')),
            )
            .enabled,
        isFalse,
      );
      expect(find.textContaining('提交结果待确认'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('修改当前余额'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('修改当前余额'), findsOneWidget);
      await tester.tap(find.text('重试确认结果'));
      await tester.pumpAndSettle();
      expect(repository.attempts, hasLength(2));
      expect(repository.attempts[1].key, repository.attempts[0].key);
      expect(repository.attempts[1].date, repository.attempts[0].date);
      expect(repository.attempts[1].reason, repository.attempts[0].reason);
      expect(
        repository.attempts[1].items.single.toJson(),
        repository.attempts[0].items.single.toJson(),
      );
      expect(find.text('修改当前余额'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'definite balance conflict keeps inputs and requires a fresh expected balance',
    (tester) async {
      final repository = _AccountRepositoryFake()
        ..nextError = ApiException(
          'CONFLICT',
          '账户余额已变化',
          httpStatus: 409,
          hasResponseCode: true,
        );
      await _pumpSingle(tester, repository);
      await tester.enterText(_targetFields(), '12.3456');
      await _enterSingleReason(tester, '现金实盘');
      await _saveSingle(tester);
      expect(find.text('刷新当前余额'), findsOneWidget);
      expect(
        tester.widget<TextField>(_targetFields()).controller!.text,
        '12.3456',
      );
      repository.refreshedBalance = '10.0000';
      final failedRefresh = Completer<AccountDetail>();
      repository.pendingDetail = failedRefresh;
      await tester.ensureVisible(find.text('刷新当前余额'));
      await tester.pump();
      await tester.tap(find.text('刷新当前余额'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(find.text('正在加载账户余额'), findsOneWidget);
      expect(repository.attempts, hasLength(1));
      failedRefresh.completeError(ApiException('READ_FAILED', '余额读取暂时失败'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('余额读取暂时失败'), findsOneWidget);

      final refreshedDetail = Completer<AccountDetail>();
      repository.pendingDetail = refreshedDetail;
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(find.text('正在加载账户余额'), findsOneWidget);
      refreshedDetail.complete(
        const AccountDetail(
          id: 'account-1',
          name: '人民币基本户',
          baseCurrency: true,
          balanceCurrentText: '10.0000',
          status: '使用',
        ),
      );
      repository.pendingDetail = null;
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 3);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        tester.widget<TextField>(_targetFields()).controller!.text,
        '12.3456',
      );
      await _saveSingle(tester);
      expect(repository.attempts, hasLength(2));
      expect(repository.attempts[1].key, isNot(repository.attempts[0].key));
      expect(repository.attempts[1].items.single.expectedBalance, '10.0000');
      expect(repository.attempts[1].items.single.targetBalance, '12.3456');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('discard confirmation protects unsaved single balance input', (
    tester,
  ) async {
    final repository = _AccountRepositoryFake();
    await _pumpSingle(tester, repository);
    await tester.enterText(_targetFields(), '12.3456');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的余额修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_targetFields()).controller!.text,
      '12.3456',
    );
    expect(repository.attempts, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('修改当前余额'), findsNothing);
  });

  testWidgets(
    'permission revocation closes confirmation and cannot send an old edit',
    (tester) async {
      final repository = _AccountRepositoryFake();
      final container = await _pumpSingle(tester, repository);
      await tester.enterText(_targetFields(), '12.3456');
      await _enterSingleReason(tester, '现金实盘');
      await tester.tap(find.text('保存余额'));
      await tester.pumpAndSettle();
      expect(find.text('确认修改当前余额'), findsOneWidget);
      container.read(_editorPermissions.notifier).state = {
        Perm.accountView,
        Perm.accountBalanceView,
      };
      await tester.pumpAndSettle();
      container.read(_editorPermissions.notifier).state = _balancePermissions;
      await tester.pumpAndSettle();
      expect(find.text('确认修改当前余额'), findsNothing);
      expect(find.text('修改当前余额'), findsNothing);
      expect(repository.attempts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account A-B-A while detail loads never publishes the old account',
    (tester) async {
      final repository = _AccountRepositoryFake()
        ..pendingDetail = Completer<AccountDetail>();
      final container = await _pumpSingle(tester, repository, settle: false);
      container.read(_editorIdentity.notifier).state = const AuthenticatedScope(
        userId: 'other-editor',
      );
      await tester.pump();
      container.read(_editorIdentity.notifier).state = const AuthenticatedScope(
        userId: 'balance-editor',
      );
      await tester.pump();
      repository.pendingDetail!.complete(
        const AccountDetail(
          id: 'account-1',
          name: '旧身份账户',
          status: '使用',
          baseCurrency: true,
          balanceCurrentText: '500.0000',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('旧身份账户'), findsNothing);
      expect(find.text('修改当前余额'), findsNothing);
      expect(repository.attempts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary account edit permission cannot load or change a balance',
    (tester) async {
      final repository = _AccountRepositoryFake();
      await _pumpSingle(
        tester,
        repository,
        permissions: {
          Perm.accountView,
          Perm.accountEdit,
          Perm.accountBalanceView,
        },
      );
      expect(repository.detailCalls, 0);
      expect(_targetFields(), findsNothing);
      expect(find.textContaining('没有修改账户余额的权限'), findsOneWidget);
      expect(repository.attempts, isEmpty);
    },
  );

  testWidgets(
    'rapid confirmation sends once and late result cannot escape an identity change',
    (tester) async {
      final repository = _AccountRepositoryFake()
        ..pendingSubmit = Completer<AccountBalanceAdjustmentBatchResult>();
      final container = await _pumpSingle(tester, repository);
      await tester.enterText(_targetFields(), '12.3456');
      await _enterSingleReason(tester, '现金实盘');
      await tester.tap(find.text('保存余额'));
      await tester.pumpAndSettle();
      final confirm = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '确认提交'),
      );
      confirm.onPressed!();
      confirm.onPressed!();
      for (var turn = 0; turn < 20 && repository.attempts.isEmpty; turn++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(repository.attempts, hasLength(1));
      expect(find.text('修改当前余额'), findsOneWidget);
      container.read(_editorIdentity.notifier).state = const AuthenticatedScope(
        userId: 'other-editor',
      );
      await tester.pump();
      container.read(_editorIdentity.notifier).state = const AuthenticatedScope(
        userId: 'balance-editor',
      );
      await tester.pump();
      repository.pendingSubmit!.complete(
        const AccountBalanceAdjustmentBatchResult(
          id: 'old-batch',
          scope: 'SELECTED',
          effectiveDate: '2026-11-03',
          reason: '现金实盘',
          itemCount: 1,
          changedCount: 1,
          items: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.attempts, hasLength(1));
      expect(find.text('修改当前余额'), findsNothing);
      expect(find.text('打开单账户编辑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ProviderContainer> _pumpSingle(
  WidgetTester tester,
  _AccountRepositoryFake repository, {
  String? initialTarget,
  bool settle = true,
  Set<String> permissions = _balancePermissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authenticatedScopeProvider.overrideWith(
          (ref) => ref.watch(_editorIdentity),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_editorPermissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        accountRepositoryProvider.overrideWithValue(repository),
        currencyRepositoryProvider.overrideWithValue(_CurrencyRepositoryFake()),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        home: _OpenSingleDialogHost(initialTarget: initialTarget),
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(_OpenSingleDialogHost)),
  );
  container.read(_editorPermissions.notifier).state = permissions;
  await tester.tap(find.text('打开单账户编辑'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  return container;
}

Future<void> _saveSingle(WidgetTester tester) async {
  await tester.tap(find.text('保存余额'));
  await tester.pumpAndSettle();
  expect(find.text('确认修改当前余额'), findsOneWidget);
  await tester.tap(find.text('确认提交'));
  await tester.pumpAndSettle();
}

Future<void> _enterSingleReason(WidgetTester tester, String reason) async {
  final field = find.byKey(const ValueKey('account-balance-reason'));
  await tester.ensureVisible(field);
  await tester.pump();
  await tester.enterText(field, reason);
}

class _OpenSingleDialogHost extends StatelessWidget {
  const _OpenSingleDialogHost({this.initialTarget});
  final String? initialTarget;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(
        onPressed: () => showAccountBalanceEditDialog(
          context,
          accountId: 'account-1',
          initialTargetBalance: initialTarget,
        ),
        child: const Text('打开单账户编辑'),
      ),
    ),
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
  int detailCalls = 0;
  int dictCalls = 0;
  String? refreshedBalance;
  Object? nextError;
  Completer<AccountBalanceAdjustmentBatchResult>? pendingSubmit;
  Completer<AccountDetail>? pendingDetail;
  final attempts =
      <
        ({
          String key,
          String date,
          String reason,
          List<AccountBalanceAdjustmentInput> items,
        })
      >[];

  @override
  Future<List<AccountListItem>> dict() async {
    dictCalls++;
    return _items;
  }

  List<AccountListItem> get _items {
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
  Future<AccountDetail> detail(String id) async {
    detailCalls++;
    if (pendingDetail != null) return pendingDetail!.future;
    final row = _items.singleWhere((item) => item.id == id);
    return AccountDetail(
      id: row.id,
      code: row.code,
      name: row.name,
      accountType: row.accountType,
      currencyId: row.currencyId,
      currencyCode: row.currencyCode,
      currencyName: row.currencyName,
      baseCurrency: row.baseCurrency,
      balanceCurrentText: refreshedBalance ?? row.balanceCurrentText,
      status: row.status,
    );
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
    attempts.add((
      key: idempotencyKey,
      date: effectiveDate,
      reason: reason,
      items: items,
    ));
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
    if (pendingSubmit != null) return pendingSubmit!.future;
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
