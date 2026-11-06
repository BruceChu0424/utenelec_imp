import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/components/buttons/uten_date_range_selection_button.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/utils/date_range_defaults.dart';
import 'package:uten_imp/features/basic_data/repositories/master_status_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'dart:async';
import '../../support/pump_until.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/pages/account_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_read_only_fields.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

final _testAccountServer = StateProvider<String>(
  (ref) => 'https://account-a.fixture/api',
);

void main() {
  testWidgets(
    'account statement fetches bill candidates only on the first real header opening',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _AccountFacetApi();
      final repository = _AccountRepositoryFake();
      await _pumpDetail(tester, repository, {
        Perm.accountView,
        Perm.accountBalanceView,
        Perm.accountFlowView,
      }, api: api);
      expect(repository.statementFacetCalls, 0);
      expect(api.bodies, isEmpty);
      final table = tester.widget<MasterDataTableView<AccountStatementRow>>(
        find.byType(MasterDataTableView<AccountStatementRow>),
      );
      expect(table.onLoadMore, isNull);
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      expect(repository.statementSizes.every((size) => size == 100), true);
      await tester.pumpAndSettle();
      expect(repository.statementFacetCalls, 0);
      expect(api.bodies, isEmpty);
      await tester.ensureVisible(find.text('单号').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('单号').first);
      await tester.pumpAndSettle();
      expect(api.bodies, hasLength(1));
      expect(api.bodies.single['accountId'], 'account-1');
      expect(api.bodies.single['dateFrom'], repository.statementDateFrom);
      expect(api.bodies.single['dateTo'], repository.statementDateTo);
      expect(api.bodies.single['__facetField'], 'billNo');
      expect(api.bodies.single['__facetPage'], 1);
      expect(api.bodies.single.containsKey('billNo'), false);
      expect(find.textContaining('ONLY-REMOTE'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'editing other account fields preserves a historical posting UUID outside the new candidate scope',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake();
      final styles = _PaymentStyleRepositoryFake()
        ..pending = (Completer<List<PaymentStyleNode>>()..complete([]));
      await _pumpDetail(
        tester,
        repository,
        {Perm.accountView, Perm.accountEdit},
        paymentStyleRepository: styles,
        startEditing: true,
      );
      expect(find.text('10201 · 基本户（保留原关联）'), findsOneWidget);
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.controller?.text == '人民币基本户',
        ),
        '保留原科目的账户名称',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repository.lastUpdate?['styleId'], 'style-bank');
      expect(repository.lastUpdate?['name'], '保留原科目的账户名称');
      expect(repository.updateCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  for (final stale in [false, true]) {
    testWidgets('账户详情字典预读显示等待且${stale ? '原地址ABA后不再打开旧编辑器' : '不等流水并正常打开编辑器'}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final currencies = _CurrencyRepositoryFake()
        ..pending = Completer<List<CurrencyListItem>>();
      final styles = _PaymentStyleRepositoryFake()
        ..pending = Completer<List<PaymentStyleNode>>();
      await _pumpDetail(
        tester,
        _AccountRepositoryFake(),
        {Perm.accountView, Perm.accountEdit},
        currencyRepository: currencies,
        paymentStyleRepository: styles,
        trackOwner: true,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AccountDetailPage)),
      );
      await tester.tap(find.byKey(const ValueKey('hierarchy-detail-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('正在读取币种和会计科目'), findsOneWidget);
      expect(currencies.dictCalls, 1);
      expect(styles.treeCalls, 1);
      if (stale) {
        container.read(_testAccountServer.notifier).state =
            'https://account-b.fixture/api';
        await tester.pump();
        container.read(_testAccountServer.notifier).state =
            'https://account-a.fixture/api';
        await tester.pumpAndSettle();
        expect(find.text('正在读取币种和会计科目'), findsNothing);
      }
      currencies.pending!.complete(currencies.values);
      styles.pending!.complete(styles.values);
      await tester.pumpAndSettle();
      expect(
        find.byType(MasterEditForm),
        stale ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final action in ['停用账户', '删除账户']) {
    for (final stale in [false, true]) {
      testWidgets('账户详情$action显示公共等待且${stale ? '旧范围回执不通知或返回新页面' : '完成后正常收尾'}', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = _AccountRepositoryFake()
          ..pendingDelete = Completer<void>();
        final statuses = _MasterStatusFake();
        await _pumpDetail(
          tester,
          repository,
          {Perm.accountView, Perm.accountStatus, Perm.accountDelete},
          statusRepository: statuses,
          trackOwner: true,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(AccountDetailPage)),
        );
        await tester.tap(find.byKey(const ValueKey('hierarchy-detail-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, action == '删除账户' ? '删除' : '确认'),
        );
        await tester.pump();
        for (
          var attempt = 0;
          attempt < 20 &&
              (action == '删除账户' ? repository.deleteCalls : statuses.calls) == 0;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pump();
        expect(
          find.text(action == '删除账户' ? '正在删除账户' : '正在停用账户'),
          findsOneWidget,
        );
        expect(action == '删除账户' ? repository.deleteCalls : statuses.calls, 1);
        if (stale) {
          container.read(readScopeRevisionProvider.notifier).state++;
          await tester.pumpAndSettle();
          expect(
            find.text(action == '删除账户' ? '正在删除账户' : '正在停用账户'),
            findsNothing,
          );
          container.read(appNotificationProvider.notifier).clear();
        }
        if (action == '删除账户') {
          repository.pendingDelete!.complete();
        } else {
          statuses.pending.complete();
        }
        await tester.pumpAndSettle();
        expect(action == '删除账户' ? repository.deleteCalls : statuses.calls, 1);
        if (stale) {
          expect(find.byType(AccountDetailPage), findsOneWidget);
          expect(container.read(appNotificationProvider), isEmpty);
        } else if (action == '停用账户') {
          expect(repository.detailCalls, 2);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'flow headers query the server and retain fixed running-balance order',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake();
      await _pumpDetail(tester, repository, {
        Perm.accountView,
        Perm.accountBalanceView,
        Perm.accountFlowView,
      });
      final summary = find.byKey(
        const ValueKey('master-column-filter-summary'),
      );
      await tester.ensureVisible(summary);
      await tester.tap(summary);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '调整_%',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.statementColumnQueries.last['search.summary'], '调整_%');
      final kind = find.byKey(const ValueKey('master-column-filter-entryKind'));
      await tester.ensureVisible(kind);
      await tester.tap(kind);
      await tester.pumpAndSettle();
      await tester.tap(find.text('反向流水').last);
      await tester.pumpAndSettle();
      expect(repository.statementColumnQueries.last['entryKind'], 'REVERSAL');
      expect(repository.statementColumnQueries.last['search.summary'], '调整_%');
      final table = tester.widget<MasterDataTableView<AccountStatementRow>>(
        find.byType(MasterDataTableView<AccountStatementRow>),
      );
      expect(table.columns.every((column) => !column.sortable), isTrue);
      expect(repository.statementPages.last, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening account edit does not wait for slow history or reset input',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final statement = Completer<AccountStatementPage>();
      final repository = _AccountRepositoryFake()..pendingStatement = statement;
      await _pumpDetail(
        tester,
        repository,
        {
          Perm.accountView,
          Perm.accountEdit,
          Perm.accountBalanceView,
          Perm.accountFlowView,
        },
        startEditing: true,
        settle: false,
      );
      await pumpUntil(
        tester,
        () => find.byType(MasterEditForm).evaluate().isNotEmpty,
        reason:
            'The editor must open while the intentionally held history remains unresolved',
      );
      await tester.pump();
      expect(repository.statementCalls, 1);
      expect(statement.isCompleted, isFalse);
      expect(find.byType(MasterEditForm), findsOneWidget);
      final name = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '人民币基本户',
      );
      await tester.enterText(name, '正在编辑的名称');
      statement.complete(
        const AccountStatementPage(
          rows: [],
          page: 1,
          size: 50,
          total: 0,
          totalPages: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('正在编辑的名称'), findsOneWidget);
      expect(repository.detailCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text('10201 · 基本户'), findsOneWidget);
    final basics = tester.widget<MasterReadOnlyFields>(
      find.byKey(const Key('account-basic-fields')),
    );
    expect(basics.fields.map((field) => field.key), [
      'name',
      'code',
      'bankAccountNo',
      'accountType',
      'currencyId',
      'styleId',
      'status',
    ]);
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
      // 2026-11-04 用户口径：日期筛选 = 单按钮弹窗；本页范围恒有值、无清除入口，
      // 也不再有并排的「清除」文字按钮。
      expect(
        find.descendant(
          of: find.byType(UtenDateRangeSelectionButton),
          matching: find.byIcon(Icons.close_rounded),
        ),
        findsNothing,
      );
      expect(find.byType(UtenDateRangeSelectionButton), findsOneWidget);
      expect(find.text('近1个月'), findsOneWidget);
      final expected = recentMonthDateRange();
      expect(
        repository.statementDateFrom,
        ChinaDateTime.formatDate(expected.start),
      );
      expect(
        repository.statementDateTo,
        ChinaDateTime.formatDate(expected.end),
      );
    },
  );

  testWidgets('账户流水业务详情返回清高亮，保留流水原金额和查询结果', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const row = AccountStatementRow(
      entryId: 'entry-1',
      billNo: 'FLOW-001',
      summary: '原始流水',
      inAmountText: '123456789012345.6789',
      balanceText: '987654321.1234',
    );
    final repository = _AccountRepositoryFake()..statementRows = [row];
    await _pumpDetail(tester, repository, {
      Perm.accountView,
      Perm.accountBalanceView,
      Perm.accountFlowView,
    });
    MasterDataTableView<AccountStatementRow> table() =>
        tester.widget(find.byType(MasterDataTableView<AccountStatementRow>));
    final state = tester.state(
      find.byType(MasterDataTableView<AccountStatementRow>),
    );
    table().onSelectionChanged!(row);
    await tester.pump();
    expect(table().isSelected!(row), isTrue);
    table().onRowTap!(row);
    await tester.pumpAndSettle();
    expect(find.text('滚动余额'), findsOneWidget);
    expect(table().isSelected!(row), isFalse);
    Navigator.of(
      tester.element(find.byType(AccountDetailPage)),
      rootNavigator: true,
    ).pop();
    await tester.pumpAndSettle();
    expect(table().isSelected!(row), isFalse);
    expect(table().items.single, same(row));
    expect(table().items.single.inAmountText, '123456789012345.6789');
    expect(
      tester.state(find.byType(MasterDataTableView<AccountStatementRow>)),
      same(state),
    );
    expect(repository.statementCalls, 1);
    expect(tester.takeException(), isNull);
  });

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

    await tester.tap(find.byKey(const ValueKey('hierarchy-detail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(currencies.dictCalls, 1);
    expect(styles.treeCalls, 1);
    final viewer = tester.widget<MasterReadOnlyFields>(
      find.byKey(const Key('account-basic-fields')),
    );
    final editor = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
    expect(
      editor.fields.map((field) => field.key),
      viewer.fields.map((field) => field.key),
    );

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

  for (final deleted in [false, true]) {
    testWidgets('account subject label remains readable for deleted=$deleted', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(720, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _AccountRepositoryFake(styleDeleted: deleted);
      final styles = _PaymentStyleRepositoryFake();
      await _pumpDetail(tester, repository, {
        Perm.accountView,
      }, paymentStyleRepository: styles);
      expect(
        find.text(deleted ? '10201 · 基本户（已删除）' : '10201 · 基本户'),
        findsOneWidget,
      );
      expect(styles.treeCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('account basic fields reflow using the shared editor grid', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    await _pumpDetail(tester, _AccountRepositoryFake(), {Perm.accountView});
    final scope = find.byKey(const Key('account-basic-fields'));
    Finder label(String name) =>
        find.descendant(of: scope, matching: find.text(name));
    final wideName = tester.getRect(label('账户名称'));
    final wideCode = tester.getRect(label('账户编号'));
    final wideBank = tester.getRect(label('银行账号'));
    expect(wideCode.top, wideName.top);
    expect(wideBank.top, wideName.top);
    expect(wideCode.left, greaterThan(wideName.left));
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(label('账户编号')).top,
      greaterThan(tester.getRect(label('账户名称')).bottom),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDetail(
  WidgetTester tester,
  _AccountRepositoryFake repository,
  Set<String> permissions, {
  _CurrencyRepositoryFake? currencyRepository,
  _PaymentStyleRepositoryFake? paymentStyleRepository,
  bool startEditing = false,
  bool settle = true,
  bool trackOwner = false,
  _MasterStatusFake? statusRepository,
  ApiClient? api,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final page = AccountDetailPage(
    accountId: 'account-1',
    startEditing: startEditing,
  );
  final router = trackOwner
      ? GoRouter(
          initialLocation: '/account/account-1',
          routes: [
            GoRoute(path: '/account/account-1', builder: (_, _) => page),
            GoRoute(
              path: '/basicinfo/account',
              builder: (_, _) => const Scaffold(body: Text('账户列表')),
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  final app = router == null
      ? MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: page,
        )
      : MaterialApp.router(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api ?? ApiClient(Dio())),
        if (trackOwner) ...[
          apiBaseUrlProvider.overrideWith(
            (ref) => ref.watch(_testAccountServer),
          ),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'account-reader'),
          ),
        ],
        masterStatusRepositoryProvider.overrideWithValue(
          statusRepository ?? _MasterStatusFake(),
        ),
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
        accountPostingStylesReaderProvider.overrideWithValue(
          () async => [
            for (final style in activeAccountStyleLeaves(
              await (paymentStyleRepository ?? _PaymentStyleRepositoryFake())
                  .tree(category: 'ACCOUNT'),
            ))
              AccountPostingStyle(
                id: style.id,
                code: style.code,
                name: style.name,
              ),
          ],
        ),
      ],
      child: app,
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

class _AccountFacetApi extends ApiClient {
  _AccountFacetApi() : super(Dio());
  final bodies = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> postForm(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    expect(path, '/finance/reports/account/statement/facets');
    bodies.add({...?body});
    return {
      'field': 'billNo',
      'page': body?['__facetPage'],
      'size': 100,
      'hasMore': false,
      'readScopeVersion': 'account-facet-authority-v1',
      'readSnapshotRevision': 'account-facet-snapshot-v1',
      'readDataVersion': 'account-facet-data-v1',
      'items': [
        {'value': 'ONLY-REMOTE', 'label': 'ONLY-REMOTE', 'count': 1},
      ],
    };
  }
}

class _AccountRepositoryFake implements AccountRepository {
  int statementFacetCalls = 0;
  List<AccountStatementRow> statementRows = const [];
  final statementColumnQueries = <Map<String, String?>>[];
  final statementPages = <int>[];
  final statementSizes = <int>[];
  _AccountRepositoryFake({this.styleDeleted = false});
  final bool styleDeleted;
  @override
  Future<List<MasterFacetBucket>> statementBillNoFacets({
    required String accountId,
    required String dateFrom,
    required String dateTo,
    String? keyword,
  }) async {
    statementFacetCalls++;
    return const [];
  }

  int detailCalls = 0;
  int statementCalls = 0;
  String? statementDateFrom;
  String? statementDateTo;
  int updateCalls = 0;
  Map<String, dynamic>? lastUpdate;
  int deleteCalls = 0;
  Completer<void>? pendingDelete;
  Completer<AccountStatementPage>? pendingStatement;

  @override
  Future<void> delete(String id) async {
    deleteCalls++;
    await pendingDelete?.future;
  }

  @override
  Future<AccountDetail> detail(String id) async {
    detailCalls++;
    return _detail();
  }

  @override
  Future<AccountDetail> update(String id, Map<String, dynamic> body) async {
    updateCalls++;
    lastUpdate = Map.of(body);
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
    styleCode: '10201',
    styleName: '基本户',
    styleDeleted: styleDeleted,
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
    String? billNo,
    Map<String, String?> columnQuery = const {},
  }) async {
    statementCalls++;
    statementDateFrom = dateFrom;
    statementDateTo = dateTo;
    statementColumnQueries.add(Map.of(columnQuery));
    statementPages.add(page);
    statementSizes.add(size);
    if (pendingStatement case final pending?) return pending.future;
    return AccountStatementPage(
      rows: statementRows,
      page: page,
      size: size,
      total: statementRows.length,
      totalPages: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CurrencyRepositoryFake implements CurrencyRepository {
  int dictCalls = 0;
  Completer<List<CurrencyListItem>>? pending;

  @override
  Future<List<CurrencyListItem>> dict() async {
    dictCalls++;
    return pending?.future ?? values;
  }

  List<CurrencyListItem> get values => const [
    CurrencyListItem(
      id: 'currency-cny',
      code: 'CNY',
      name: '人民币',
      exchangeRate: 0,
      exchangeRateText: '0',
      status: '使用',
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PaymentStyleRepositoryFake implements PaymentStyleRepository {
  int treeCalls = 0;
  Completer<List<PaymentStyleNode>>? pending;

  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async {
    treeCalls++;
    return pending?.future ?? values;
  }

  List<PaymentStyleNode> get values => [
    PaymentStyleNode(
      id: 'style-bank',
      code: '10201',
      name: '基本户',
      category: 'ACCOUNT',
      status: '使用',
      children: const [],
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MasterStatusFake implements MasterStatusRepository {
  final pending = Completer<void>();
  int calls = 0;
  @override
  Future<void> change({
    required String resourcePath,
    required String status,
    int? version,
  }) async {
    calls++;
    await pending.future;
  }
}
