// Explicit local UI fixture for the real account workspace and detail pages.
// All accounts, amounts, history and mutations are synthetic and in memory.
// No credentials, company services, installer or updater are used.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/pages/account_detail_page.dart';
import 'package:uten_imp/features/basic_data/pages/account_page.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_inline_edit_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = Uri.base.queryParameters['permissions'] ?? 'edit';
  final repository = _Accounts(mode);
  final api = _NoBusinessApi();
  final router = GoRouter(
    initialLocation: '/basicinfo/account',
    routes: [
      GoRoute(
        path: '/basicinfo/account',
        builder: (_, _) => const AccountPage(),
      ),
      GoRoute(
        path: '/basicinfo/account/:id',
        builder: (_, state) => AccountDetailPage(
          accountId: state.pathParameters['id']!,
          startEditing: state.uri.queryParameters['edit'] == 'true',
        ),
      ),
    ],
  );
  runApp(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(
            userId: 'synthetic-finance-operator',
            businessDatasetId: 'synthetic-account-design-only',
          ),
        ),
        currentPermissionsProvider.overrideWithValue(repository.permissions),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://synthetic.invalid/api'),
        accountRepositoryProvider.overrideWithValue(repository),
        currencyRepositoryProvider.overrideWithValue(_Currencies()),
        paymentStyleRepositoryProvider.overrideWithValue(_Styles()),
        masterInlineEditRepositoryProvider.overrideWithValue(
          _InlineRepository(api, repository),
        ),
        sharedPreferencesProvider.overrideWithValue(
          InMemorySharedPreferences(),
        ),
      ],
      child: MaterialApp.router(
        title: '账户资料本地合成验证',
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: Uri.base.queryParameters['theme'] == 'dark'
            ? ThemeMode.dark
            : ThemeMode.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (context, child) {
          final scale = double.tryParse(
            Uri.base.queryParameters['scale'] ?? '',
          );
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale ?? 1)),
            child: Column(
              children: [
                if (Uri.base.queryParameters['chrome'] != '0')
                  _FixtureControls(repository, mode),
                Expanded(child: child!),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _FixtureControls extends StatelessWidget {
  const _FixtureControls(this.repository, this.mode);
  final _Accounts repository;
  final String mode;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: AnimatedBuilder(
      animation: repository,
      builder: (context, _) => SizedBox(
        height: 38,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Text(
                '本地合成数据 / $mode / 调账请求 ${repository.calls.length} / '
                '实际批次 ${repository.results.length}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              TextButton(
                onPressed: () => repository.setDelay(!repository.delayNext),
                child: Text(repository.delayNext ? '已启用下一次延迟' : '下一次延迟'),
              ),
              TextButton(
                onPressed: () => repository.setUnknown(!repository.unknownNext),
                child: Text(repository.unknownNext ? '已启用下一次未知结果' : '下一次未知结果'),
              ),
              TextButton(
                onPressed: repository.conflictBasicAccount,
                child: const Text('模拟基本户并发变动'),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NoBusinessApi extends ApiClient {
  _NoBusinessApi()
    : super(
        Dio(BaseOptions(baseUrl: 'https://synthetic.invalid/api'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) => handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.cancel,
                  error: 'Account design fixture forbids all business HTTP',
                ),
              ),
            ),
          ),
      );
}

class _Accounts extends ChangeNotifier implements AccountRepository {
  _Accounts(String mode)
    : permissions = {
        Perm.accountView,
        Perm.accountBalanceView,
        Perm.accountFlowView,
        if (mode != 'readonly') Perm.accountBalanceAdjust,
        if (mode != 'readonly' && mode != 'adjust-only') Perm.accountEdit,
      } {
    const names = [
      '基本户',
      '现金',
      '农行',
      '建行',
      '邮政',
      '外来支票',
      '工行',
      '工行牡丹卡',
      '招行',
      '交行',
      '信用社',
      '一般账户',
      '兴业银行',
      '美金账户',
      '微信收款',
      '支付宝',
      '备用金',
      '项目资金户',
      '工资户',
      '旧基本户',
      '旧现金账户',
      '旧农行',
      '旧建行',
      '旧邮政',
      '旧工行',
      '旧招行',
      '旧交行',
      '已停用备用户',
    ];
    const amounts = [
      '1286400.50',
      '84250.00',
      '626800.00',
      '38940.90',
      '38200.00',
      '0.00',
      '552.70',
      '0.00',
      '188900.00',
      '42760.25',
      '0.00',
      '12000.00',
      '0.00',
      '67462.28',
      '8290.00',
      '4690.50',
      '12000.00',
      '268000.00',
      '187600.00',
    ];
    for (var i = 0; i < names.length; i++) {
      final usd = i == 13;
      records['account-${i + 1}'] = {
        'id': 'account-${i + 1}',
        'code': 'ZH${(i + 10).toString().padLeft(6, '0')}',
        'name': names[i],
        'bankAccountNo': i == 1
            ? null
            : 'TEST ${(i + 1).toString().padLeft(4, '0')}',
        'accountType': i == 1 ? 'CASH' : (usd ? 'OFFSHORE' : 'BANK'),
        'currencyId': usd ? 'currency-usd' : 'currency-cny',
        'currencyCode': usd ? 'USD' : 'CNY',
        'currencyName': usd ? '美金' : '人民币',
        'baseCurrency': !usd,
        'balanceCurrentText': i < amounts.length ? amounts[i] : '0.00',
        'initBalanceText': i < amounts.length ? amounts[i] : '0.00',
        'receiptsTotalText': '0.00',
        'paymentsTotalText': '0.00',
        'adjustmentsTotalText': '0.00',
        'status': i < 19 ? '使用' : '禁用',
        'styleId': 'style-bank',
        'styleCode': '100201',
        'styleName': '银行存款',
        'flowIntegrity': true,
        'balanceDifferenceText': '0.00',
      };
    }
  }

  final Set<String> permissions;
  final records = <String, Map<String, dynamic>>{};
  final calls = <Map<String, dynamic>>[];
  final results = <String, AccountBalanceAdjustmentBatchResult>{};
  final fingerprints = <String, String>{};
  final flows = <String, List<AccountStatementRow>>{};
  bool delayNext = false, unknownNext = false;

  void setDelay(bool value) {
    delayNext = value;
    notifyListeners();
  }

  void setUnknown(bool value) {
    unknownNext = value;
    notifyListeners();
  }

  void conflictBasicAccount() {
    final row = records['account-1']!;
    row['balanceCurrentText'] = financeExactDecimalFromUnits(
      financeExactDecimalUnits(row['balanceCurrentText'] as String)! +
          BigInt.from(10000),
    );
    notifyListeners();
  }

  Future<void> _readDelay() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  @override
  Future<PagedResult<AccountListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    await _readDelay();
    final found = records.values.where((row) {
      if (keyword != null &&
          keyword.isNotEmpty &&
          ![
            'name',
            'code',
            'bankAccountNo',
          ].any((key) => '${row[key] ?? ''}'.contains(keyword))) {
        return false;
      }
      for (final entry in filters.entries) {
        if (entry.value == null || entry.value!.isEmpty) continue;
        final key = entry.key.replaceFirst('search.', '');
        if (entry.key.startsWith('search.')) {
          if (!'${row[key] ?? ''}'.contains(entry.value!)) return false;
        } else if (row.containsKey(key) && row[key] != entry.value) {
          return false;
        }
      }
      return true;
    }).toList();
    if (sort != null) {
      found.sort((a, b) {
        final cmp = sort == 'balanceCurrent'
            ? financeExactDecimalUnits(
                a['balanceCurrentText'] as String,
              )!.compareTo(
                financeExactDecimalUnits(b['balanceCurrentText'] as String)!,
              )
            : '${a[sort] ?? ''}'.compareTo('${b[sort] ?? ''}');
        return order == 'desc' ? -cmp : cmp;
      });
    }
    return PagedResult(
      items: found
          .skip((page - 1) * size)
          .take(size)
          .map(AccountListItem.fromJson)
          .toList(),
      page: page,
      size: size,
      total: found.length,
      totalPages: (found.length / size).ceil(),
    );
  }

  @override
  Future<AccountFacets> facets() async => AccountFacets(
    fields: {
      for (final key in ['status', 'accountType', 'currencyId'])
        key: [
          for (final value
              in records.values.map((row) => row[key] as String).toSet())
            MasterFacetBucket(
              value: value,
              count: records.values.where((row) => row[key] == value).length,
              label: key == 'currencyId'
                  ? (value == 'currency-cny' ? '人民币' : '美金')
                  : null,
            ),
        ],
    },
    nullCounts: const {},
  );

  @override
  Future<AccountSummary> summary() async => AccountSummary(
    totalAccounts: records.length,
    activeAccounts: records.values.where((row) => row['status'] == '使用').length,
    disabledAccounts: records.values
        .where((row) => row['status'] == '禁用')
        .length,
    warningAccounts: 0,
    negativeAccounts: 0,
    currencies: [
      for (final id in ['currency-cny', 'currency-usd'])
        AccountCurrencySummary(
          currencyId: id,
          currencyCode: id == 'currency-cny' ? 'CNY' : 'USD',
          currencyName: id == 'currency-cny' ? '人民币' : '美金',
          accountCount: records.values
              .where((row) => row['currencyId'] == id)
              .length,
          activeAccountCount: records.values
              .where((row) => row['currencyId'] == id && row['status'] == '使用')
              .length,
          balanceTotalText: financeExactSumTexts(
            records.values
                .where(
                  (row) => row['currencyId'] == id && row['status'] == '使用',
                )
                .map((row) => row['balanceCurrentText'] as String),
          ),
          warningCount: 0,
          negativeCount: 0,
        ),
    ],
  );

  @override
  Future<List<AccountListItem>> dict() async =>
      records.values.map(AccountListItem.fromJson).toList();

  @override
  Future<AccountDetail> detail(String id) async {
    await _readDelay();
    return AccountDetail.fromJson({
      ...records[id]!,
      'flowBalanceText': records[id]!['balanceCurrentText'],
    });
  }

  @override
  Future<AccountDetail> update(String id, Map<String, dynamic> body) async {
    if (!permissions.contains(Perm.accountEdit)) {
      throw ApiException('FORBIDDEN', '无主档编辑权限');
    }
    records[id]!.addAll(body);
    notifyListeners();
    return detail(id);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async =>
      throw ApiException('FORBIDDEN', '本地验证未开放新增');
  @override
  Future<void> delete(String id) async =>
      throw ApiException('FORBIDDEN', '本地验证未开放删除');
  @override
  Future<AccountDetail> updateWarning(
    String id, {
    String? balanceFloor,
  }) async => throw ApiException('FORBIDDEN', '本地验证未开放警戒线维护');

  @override
  Future<AccountStatementPage> statement({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    String? keyword,
    int page = 1,
    int size = 50,
    String? billNo,
    Map<String, String?> columnQuery = const {},
  }) async {
    final rows = flows[accountId] ?? const <AccountStatementRow>[];
    return AccountStatementPage(
      rows: rows,
      page: page,
      size: size,
      total: rows.length,
      totalPages: rows.isEmpty ? 0 : 1,
    );
  }

  @override
  Future<List<MasterFacetBucket>> statementBillNoFacets({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    String? keyword,
  }) async => const [];

  @override
  Future<AccountBalanceAdjustmentBatchResult> adjustBalances({
    required AccountBalanceAdjustmentScope scope,
    required String effectiveDate,
    required String reason,
    required String idempotencyKey,
    required List<AccountBalanceAdjustmentInput> items,
  }) async {
    if (!permissions.contains(Perm.accountBalanceAdjust)) {
      throw ApiException(
        'FORBIDDEN',
        '无余额调整权限',
        httpStatus: 403,
        hasResponseCode: true,
      );
    }
    final payload = {
      'scope': scope.value,
      'effectiveDate': effectiveDate,
      'reason': reason,
      'items': items.map((item) => item.toJson()).toList(),
    };
    calls.add({'idempotencyKey': idempotencyKey, ...payload});
    notifyListeners();
    final delay = delayNext, unknown = unknownNext;
    delayNext = false;
    unknownNext = false;
    await Future<void>.delayed(Duration(milliseconds: delay ? 2500 : 180));
    final fingerprint = jsonEncode(payload);
    final previous = results[idempotencyKey];
    if (previous != null) {
      if (fingerprints[idempotencyKey] != fingerprint) {
        throw ApiException(
          'CONFLICT',
          '同一幂等键不能改变内容',
          httpStatus: 409,
          hasResponseCode: true,
        );
      }
      return previous;
    }
    for (final item in items) {
      final row = records[item.accountId]!;
      if (row['status'] != '使用' ||
          financeExactDecimalUnits(row['balanceCurrentText'] as String) !=
              financeExactDecimalUnits(item.expectedBalance)) {
        throw ApiException(
          'CONFLICT',
          '当前余额已变化，请刷新后核对',
          httpStatus: 409,
          hasResponseCode: true,
        );
      }
      final delta =
          financeExactDecimalUnits(item.targetBalance)! -
          financeExactDecimalUnits(item.expectedBalance)!;
      final local = financeExactDecimalUnits(item.localDelta);
      if (row['baseCurrency'] != true &&
          delta != BigInt.zero &&
          (local == null ||
              local == BigInt.zero ||
              local.isNegative != delta.isNegative)) {
        throw ApiException(
          'VALIDATION_ERROR',
          '外币余额变化须填写同号非零本位币调账额',
          httpStatus: 422,
          hasResponseCode: true,
        );
      }
    }
    var changed = 0;
    for (final item in items) {
      final row = records[item.accountId]!;
      final delta =
          financeExactDecimalUnits(item.targetBalance)! -
          financeExactDecimalUnits(item.expectedBalance)!;
      if (delta != BigInt.zero) changed++;
      row['balanceCurrentText'] = item.targetBalance;
      row['adjustmentsTotalText'] = financeExactDecimalFromUnits(
        financeExactDecimalUnits(row['adjustmentsTotalText'] as String)! +
            delta,
      );
      if (delta != BigInt.zero) {
        flows
            .putIfAbsent(item.accountId, () => [])
            .add(
              AccountStatementRow(
                billDate: effectiveDate,
                billNo: 'AB-SYNTH-${results.length + 1}',
                summary: reason,
                entryKind: 'ADJUSTMENT',
                inAmountText: delta.isNegative
                    ? '0.0000'
                    : financeExactDecimalFromUnits(delta),
                outAmountText: delta.isNegative
                    ? financeExactDecimalFromUnits(-delta)
                    : '0.0000',
                balanceText: item.targetBalance,
              ),
            );
      }
    }
    final result = AccountBalanceAdjustmentBatchResult(
      id: 'synthetic-batch-${results.length + 1}',
      batchNo: 'AB-SYNTH-${results.length + 1}',
      scope: scope.value,
      effectiveDate: effectiveDate,
      reason: reason,
      itemCount: items.length,
      changedCount: changed,
      items: const [],
    );
    fingerprints[idempotencyKey] = fingerprint;
    results[idempotencyKey] = result;
    notifyListeners();
    if (unknown) throw NetworkTimeoutException();
    return result;
  }
}

class _InlineRepository extends MasterInlineEditRepository {
  _InlineRepository(super.api, this.repository);
  final _Accounts repository;
  @override
  Future<void> save(
    String entityType,
    String id, {
    required Map<String, dynamic> changes,
    required Map<String, Object?> expected,
  }) async {
    final row = repository.records[id]!;
    if (expected.entries.any((entry) => row[entry.key] != entry.value)) {
      throw ApiException(
        'CONFLICT',
        '合成资料已变化，请刷新',
        httpStatus: 409,
        hasResponseCode: true,
      );
    }
    await repository.update(id, changes);
  }
}

class _Currencies implements CurrencyRepository {
  @override
  Future<List<CurrencyListItem>> dict() async => const [
    CurrencyListItem(
      id: 'currency-cny',
      code: 'CNY',
      name: '人民币',
      baseCurrency: true,
      status: '使用',
    ),
    CurrencyListItem(id: 'currency-usd', code: 'USD', name: '美金', status: '使用'),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Styles implements PaymentStyleRepository {
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async => [
    PaymentStyleNode(
      id: 'style-bank',
      code: '100201',
      name: '银行存款',
      category: 'ACCOUNT',
      status: '使用',
      children: const [],
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
