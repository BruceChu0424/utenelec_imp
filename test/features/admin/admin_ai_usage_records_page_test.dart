import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/admin/models/ai_provider_models.dart';
import 'package:uten_imp/features/admin/models/ai_usage_audit_models.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/admin/pages/admin_ai_usage_records_page.dart';
import 'package:uten_imp/features/admin/repositories/ai_provider_repository.dart';
import 'package:uten_imp/features/admin/repositories/ai_usage_audit_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../ai_visual/ai_visual_support.dart';

void main() {
  testWidgets(
    'record headers send full-range combined conditions and reset page without filtering the accepted rows locally',
    (tester) async {
      final repository = _HeaderRepository()..data = _data(total: 41);
      await _pump(tester, repository);
      MasterDataTableView<AiUsageAuditRecord> table() =>
          tester.widget(find.byKey(const Key('ai-records-table')));
      await table().onPageChange!(2);
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .byKey(const ValueKey('master-column-filter-question'))
            .hitTestable()
            .first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '库存',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final queried = repository.headerReads
          .where((q) => (q['filters'] as Map)['search.question'] == '库存')
          .toList();
      expect(queried, isNotEmpty);
      expect(queried.first['page'], 0);
      expect(
        table().items,
        isNotEmpty,
        reason:
            'The server response owns the complete result, not a local page predicate',
      );
      await tester.tap(
        find
            .byKey(const ValueKey('master-column-filter-status'))
            .hitTestable()
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .text(
              AppLocalizations.of(
                tester.element(find.byKey(const Key('ai-records-table'))),
              ).aiAuditFailed,
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(repository.headerReads.last['filters'], {
        'search.question': '库存',
        'status': 'FAILED',
      });
      expect(table().currentPage, 1);
      expect(tester.takeException(), isNull);
      final l10n = AppLocalizations.of(
        tester.element(find.byKey(const Key('ai-records-table'))),
      );
      await tester.tap(find.text(l10n.aiRecordsViewByPerson).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-records-clear-columns')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai-records-clear-columns')));
      await tester.pumpAndSettle();
      expect(repository.headerReads.last['filters'], isEmpty);
      expect(find.byKey(const Key('ai-records-clear-columns')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    },
  );
  testWidgets(
    'record pages prepare ahead, reuse both directions and preserve exact event fields',
    (tester) async {
      final repository = _Repository()
        ..pages = {
          for (var page = 0; page < 3; page++)
            page: {
              ..._data(question: '第$page页问题', total: 41),
              'records': [
                {
                  'id': 'event-$page',
                  'userId': 'employee-$page',
                  'name': '员工$page',
                  'code': 'E$page',
                  'question': '第$page页问题',
                  'intent': 'inventory_lookup',
                  'kind': 'ERP_CHAT',
                  'status': 'SUCCEEDED',
                  'createdAt': '2026-10-26T01:02:03.123456Z',
                  'inputTokens': 9007199254740991,
                  'outputTokens': null,
                  'calls': 2,
                  'providerNames': ['服务$page'],
                  'models': ['模型$page'],
                  'costs': [
                    {
                      'basis': 'ACTUAL',
                      'currency': 'EUR',
                      'amount': '999999999999.000000001',
                    },
                  ],
                },
              ],
            },
        };
      await _pump(tester, repository);
      MasterDataTableView<AiUsageAuditRecord> table() =>
          tester.widget(find.byKey(const Key('ai-records-table')));
      expect(repository.reads.map((query) => query['page']), [0, 1, 2]);
      expect(table().currentPage, 1);
      expect(table().items.single.id, 'event-0');
      await table().onPageChange!(2);
      await tester.pumpAndSettle();
      expect(table().currentPage, 2);
      expect(repository.reads.map((query) => query['page']), [0, 1, 2]);
      final second = table().items.single;
      expect(second.id, 'event-1');
      expect(second.inputTokens, 9007199254740991);
      expect(second.outputTokens, isNull);
      expect(second.createdAt, '2026-10-26T01:02:03.123456Z');
      expect(second.metrics.costs.single.amount, '999999999999.000000001');
      expect(second.providerNames, ['服务1']);
      await table().onPageChange!(1);
      await tester.pumpAndSettle();
      expect(table().items.single.id, 'event-0');
      expect(repository.reads.map((query) => query['page']), [0, 1, 2]);
      await tester.tap(find.byTooltip('刷新记录'));
      await tester.pumpAndSettle();
      expect(
        repository.reads.where((query) => query['page'] == 0),
        hasLength(2),
      );
    },
  );

  testWidgets(
    'record foreground adopts prefetch while retaining the accepted page indicator',
    (tester) async {
      final second = Completer<Map<String, dynamic>>();
      final repository = _Repository()
        ..pendingReads.add(Future.value(_data(question: '第一页', total: 21)))
        ..pendingReads.add(second.future);
      addTearDown(() {
        if (!second.isCompleted) second.complete(_data(total: 21));
      });
      await _pump(tester, repository);
      MasterDataTableView<AiUsageAuditRecord> table() =>
          tester.widget(find.byKey(const Key('ai-records-table')));
      expect(repository.reads.map((query) => query['page']), [0, 1]);
      expect(table().currentPage, 1);
      expect(table().loadingMore, isFalse);
      final navigation = table().onPageChange!(2);
      await tester.pump();
      expect(table().currentPage, 1);
      expect(table().loadingMore, isTrue);
      expect(repository.reads, hasLength(2));
      second.complete(_data(question: '第二页', total: 21));
      await navigation;
      await tester.pumpAndSettle();
      expect(table().currentPage, 2);
      expect(table().items.single.question, '第二页');
      expect(repository.reads, hasLength(2));
    },
  );

  testWidgets(
    'record prefetch rejection clears records, users and billing providers without reread',
    (tester) async {
      final rejected = Completer<Map<String, dynamic>>();
      final repository = _Repository()
        ..pendingReads.add(Future.value(_data(total: 21)))
        ..pendingReads.add(rejected.future);
      await _pump(tester, repository);
      rejected.completeError(
        ApiException('FORBIDDEN', '记录读取权限已撤销', httpStatus: 403),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-records-denied')), findsOneWidget);
      expect(find.text('原账号问题内容'), findsNothing);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('ai-records-billing-open')),
            )
            .onPressed,
        isNull,
      );
      expect(repository.reads, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  test('route inherits the system-administration guard', () {
    expect(requiredAnyPermFor(RouteName.adminAiUsageRecords), const [
      Perm.authorizationManage,
    ]);
    expect(requiredAllPermsFor(RouteName.adminAiUsageRecords), isEmpty);
  });

  testWidgets('billing save closes and refreshes the audit data', (
    tester,
  ) async {
    final providers = _Providers();
    final repository = _Repository()
      ..afterSave = (values) =>
          providers.version = (values['version'] as int) + 1;
    await _pump(tester, repository, providers: providers);
    final readsBefore = repository.reads.length;
    await _openBilling(tester);
    await _save(tester);
    await _closeBilling(tester);
    expect(repository.reads.length, readsBefore + 1);
    expect(providers.reads, greaterThanOrEqualTo(1));
  });

  testWidgets('idle billing outside cancellation does not save or refresh', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    final reads = repository.reads.length;
    await _openBilling(tester);
    await tester.tapAt(const Offset(8, 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-billing-provider')), findsNothing);
    expect(repository.saved, isEmpty);
    expect(repository.reads, hasLength(reads));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'held billing save survives outside dismissal and back until saved close refreshes host',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final repository = _Repository()..pendingSave = pending;
      addTearDown(() {
        if (!pending.isCompleted) {
          pending.complete({...repository.billingValue, 'version': 8});
        }
      });
      await _pump(tester, repository);
      final reads = repository.reads.length;
      await _openBilling(tester);
      final save = find.byKey(const ValueKey('ai-billing-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.tapAt(const Offset(8, 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(save, findsOneWidget);
      await Navigator.of(tester.element(save)).maybePop();
      await tester.pump();
      expect(save, findsOneWidget);
      expect(repository.saved, hasLength(1));
      expect(repository.reads, hasLength(reads));
      pending.complete({...repository.billingValue, 'version': 8});
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(8, 500));
      await tester.pumpAndSettle();
      expect(save, findsNothing);
      expect(repository.reads, hasLength(reads + 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a read-only billing load can still be cancelled outside', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final repository = _Repository()..pendingBilling = pending;
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete(Map.of(repository.billingValue));
      }
    });
    await _pump(tester, repository);
    await _openBilling(tester);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tapAt(const Offset(8, 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-billing-provider')), findsNothing);
    expect(repository.saved, isEmpty);
    pending.complete(Map.of(repository.billingValue));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider list failure keeps records readable and billing off', (
    tester,
  ) async {
    final providers = _Providers()..listError = NetworkException();
    await _pump(tester, _Repository(), providers: providers);
    expect(find.text('原账号问题内容'), findsOneWidget);
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const ValueKey('ai-records-billing-open')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('usage timestamps follow the platform Beijing display', (
    tester,
  ) async {
    await _pump(tester, _Repository());
    expect(find.textContaining('2026-10-03 20:00(北京)'), findsOneWidget);
    expect(find.textContaining('12:00:00Z'), findsNothing);
  });

  test('repository preserves filters and optimistic billing version', () async {
    final api = _Api();
    final repository = DioAiUsageAuditRepository(api);
    await repository.read(
      days: 90,
      page: 2,
      userId: 'employee-1',
      providerId: _providerId,
    );
    expect(api.path, '/admin/ai/usage-audit');
    expect(api.query, {
      'days': 90,
      'page': 2,
      'size': 20,
      'userId': 'employee-1',
      'providerId': _providerId,
    });
    await repository.billing(_providerId);
    expect(api.path, '/admin/ai/providers/$_providerId/billing');
    await repository.saveBilling(_providerId, {
      'version': 7,
      'billingMode': 'SUBSCRIPTION',
      'currency': null,
    });
    expect(api.path, '/admin/ai/providers/$_providerId/billing');
    expect(api.body, {
      'version': 7,
      'billingMode': 'SUBSCRIPTION',
      'currency': null,
    });
  });

  testWidgets('unknown cost stays unknown and currencies are never combined', (
    tester,
  ) async {
    final zh = lookupAppLocalizations(const Locale('zh'));
    final repository = _Repository()
      ..data = _data(
        costs: [
          {'basis': 'ACTUAL', 'currency': 'CNY', 'amount': '1.23'},
          {'basis': 'ESTIMATE', 'currency': 'USD', 'amount': '0.45'},
        ],
        unknown: 2,
      );
    await _pump(tester, repository);
    // 汇总卡分别显示实际/估算的币种+金额, 不做跨币种合并。
    expect(find.text('CNY 1.23'), findsOneWidget);
    expect(find.text('USD 0.45'), findsOneWidget);
    expect(find.text(zh.aiRecordsStatUnknownFooter(2)), findsOneWidget);
    expect(find.textContaining('1.68'), findsNothing);
    expect(find.textContaining('0.00'), findsNothing);
    repository.data = _data(costs: [], unknown: 3);
    await tester.tap(find.byTooltip('刷新记录'));
    await tester.pumpAndSettle();
    expect(find.text(zh.aiRecordsStatUnknownFooter(3)), findsOneWidget);
    expect(find.textContaining('CNY'), findsNothing);
    expect(find.textContaining('0.00'), findsNothing);
  });

  testWidgets(
    'known query and document purposes have human labels and pending status',
    (tester) async {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      final cases = {
        'query_goods_cost': l10n.aiAuditPurposeCost,
        'inventory_lookup': l10n.aiAuditPurposeStock,
        'query_client_credit': l10n.aiAuditPurposeCredit,
        'SALES_ORDER': l10n.aiAuditPurposeOrder,
        'SALES_QUOTE': l10n.aiAuditPurposeQuote,
        'EXPENSE_CLAIM': l10n.aiAuditPurposeExpense,
        'feature_directory': l10n.aiAuditPurposeDirectory,
        'my_access': l10n.aiAuditPurposeAccess,
        'sales_order_progress': l10n.aiAuditPurposeSalesOrder,
        'purchase_order_status': l10n.aiAuditPurposePurchaseOrder,
        'subcontract_order_status': l10n.aiAuditPurposeSubcontract,
        'unknown_internal_code': l10n.aiAuditKindChat,
      };
      final repository = _Repository()..data = _data();
      repository.data['records'] = [
        for (final entry in cases.entries)
          {
            'id': entry.key,
            'question': '',
            'kind': 'ERP_CHAT',
            'intent': entry.key,
            'status': 'PENDING',
          },
      ];
      await _pump(tester, repository);
      for (final entry in cases.entries) {
        expect(
          find.text(l10n.aiAuditQuestionMissing(entry.value)),
          findsOneWidget,
        );
        expect(find.textContaining(entry.key), findsNothing);
      }
      expect(
        find.textContaining(l10n.aiAuditQueued),
        findsNWidgets(cases.length),
      );
    },
  );

  testWidgets(
    'record detail shows the historical provider and model snapshot',
    (tester) async {
      final repository = _Repository();
      final record = (repository.data['records'] as List).single as Map;
      record['providerNames'] = ['历史服务 A', '历史服务 B'];
      record['models'] = ['previous-model-1', 'previous-model-2'];
      await _pump(tester, repository);
      await tester.tap(find.text('原账号问题内容'));
      await tester.pumpAndSettle();
      final detail = find.byKey(const ValueKey('ai-records-detail'));
      expect(
        find.descendant(of: detail, matching: find.text('历史服务 A / 历史服务 B')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: detail,
          matching: find.text('previous-model-1 / previous-model-2'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('关闭'), findsOneWidget);
    },
  );

  testWidgets(
    'paging and filter changes use the selected scope and reset to page zero',
    (tester) async {
      final repository = _Repository()
        ..data = _data(total: 41)
        ..pages = {
          for (var page = 0; page < 3; page++)
            page: {
              ..._data(total: 41),
              'records': [
                {
                  ...((_data()['records'] as List).single
                      as Map<String, dynamic>),
                  'id': 'paging-job-$page',
                },
              ],
            },
        };
      await _pump(tester, repository);
      final next = find.byKey(const ValueKey('master-table-page-next'));
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<AiUsageAuditRecord>>(
        find.byKey(const Key('ai-records-table')),
      );
      expect(table.rowsController!.pagination.value?.currentPage, 2);
      expect(
        repository.reads.where((query) => query['page'] == 1),
        hasLength(1),
      );
      await _select(tester, '时间', '近 7 天');
      expect(repository.reads.last['days'], 7);
      expect(
        repository.reads.lastWhere((query) => query['page'] == 0)['days'],
        7,
      );
      await _select(tester, '使用人', '示例员工（E001）');
      expect(repository.reads.last['userId'], 'employee-1');
      expect(
        repository.reads.lastWhere((query) => query['page'] == 0)['userId'],
        'employee-1',
      );
      await _select(tester, 'AI 服务', '测试 AI 服务');
      expect(repository.reads.last['providerId'], _providerId);
      expect(repository.reads.last['userId'], 'employee-1');
      await _select(tester, '使用人', '全部员工');
      expect(repository.reads.last['userId'], isNull);
      expect(repository.reads.last['providerId'], _providerId);
    },
  );

  testWidgets('billing is manual and uses each returned optimistic version', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    expect(repository.saved, isEmpty);
    await _openBilling(tester);
    expect(repository.saved, isEmpty);
    await _enter(tester, '每百万输入 token 单价', '1.2500000001');
    await _enter(tester, '每百万输出 token 单价', '2.50');
    await _save(tester);
    expect(repository.saved.single.$1, _providerId);
    expect(repository.saved.single.$2, {
      'version': 7,
      'billingMode': 'METERED',
      'currency': 'CNY',
      'inputPerMillion': '1.2500000001',
      'outputPerMillion': '2.50',
      'quota5h': null,
      'quotaWeekly': null,
    });
    await _save(tester);
    expect(repository.saved.last.$2['version'], 8);
    repository.saveError = ApiException(
      'CONFLICT',
      '计费设置已被其他管理员修改',
      httpStatus: 409,
    );
    await _save(tester);
    expect(repository.saved.last.$2['version'], 9);
    expect(find.text('计费设置已被其他管理员修改'), findsOneWidget);
    expect(repository.saved, hasLength(3));
    repository.saveError = null;
    repository.billingValue['version'] = 41;
    await tester.ensureVisible(find.byTooltip('重新读取计费设置'));
    await tester.tap(find.byTooltip('重新读取计费设置'));
    await tester.pumpAndSettle();
    await _save(tester);
    expect(repository.saved.last.$2['version'], 41);
  });

  testWidgets('billing rejects malformed prices without dispatching a write', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    await _openBilling(tester);
    for (final price in [
      '-1',
      '1e3',
      '1.12345678901',
      '1000000.0000000001',
      '9999999',
      '',
    ]) {
      await _enter(tester, '每百万输入 token 单价', price);
      await _save(tester);
      expect(repository.saved, isEmpty, reason: price);
    }
    expect(find.text('请填写有效的输入、输出单价。'), findsOneWidget);
    await _enter(tester, '每百万输入 token 单价', '1000000.0000000000');
    await _save(tester);
    expect(repository.saved.single.$2['inputPerMillion'], '1000000.0000000000');
  });

  testWidgets(
    'subscription quota meters use logged usage and save configured quotas',
    (tester) async {
      final zh = lookupAppLocalizations(const Locale('zh'));
      final repository = _Repository();
      repository.billingValue
        ..['billingMode'] = 'SUBSCRIPTION'
        ..['currency'] = null
        ..['inputPerMillion'] = null
        ..['outputPerMillion'] = null
        ..['quota5h'] = 120
        ..['quotaWeekly'] = 600
        ..['quota'] = {
          'status': 'LOGGED',
          'message': null,
          'windows': [
            {'key': 'FIVE_HOURS', 'used': 3, 'quota': 120},
            {'key': 'WEEKLY', 'used': 5, 'quota': 600},
          ],
        };
      await _pump(tester, repository);
      await _openBilling(tester);
      expect(find.text(zh.aiAuditQuota5hUsed(3, '120')), findsOneWidget);
      expect(find.text(zh.aiAuditQuotaWeeklyUsed(5, '600')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
      await _enter(tester, zh.aiAuditFiveHourQuota, '200');
      await _save(tester);
      expect(repository.saved.single.$2['billingMode'], 'SUBSCRIPTION');
      expect(repository.saved.single.$2['quota5h'], 200);
      expect(repository.saved.single.$2['quotaWeekly'], 600);
    },
  );

  for (final status in [401, 403]) {
    testWidgets('server $status hides the audit data and the filters', (
      tester,
    ) async {
      final repository = _Repository();
      await _pump(tester, repository);
      final pending = Completer<Map<String, dynamic>>();
      repository.pendingReads.add(pending.future);
      await tester.tap(find.byTooltip('刷新记录'));
      await tester.pump();
      pending.completeError(
        ApiException('FORBIDDEN', '当前账号不能读取记录', httpStatus: status),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前账号不能读取记录'), findsOneWidget);
      expect(find.text('原账号问题内容'), findsNothing);
      expect(find.byType(UtenDropdownField), findsNothing);
      expect(repository.saved, isEmpty);
    });
  }

  testWidgets('billing denial also hides previously visible audit data', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    await _openBilling(tester);
    repository.saveError = ApiException(
      'FORBIDDEN',
      '当前账号不能修改计费',
      httpStatus: 403,
    );
    await _save(tester);
    expect(find.text('当前账号不能修改计费'), findsOneWidget);
    expect(find.text('原账号问题内容'), findsNothing);
    expect(find.byType(UtenDropdownField), findsNothing);
    expect(find.widgetWithText(FilledButton, '保存计费设置'), findsNothing);
  });

  testWidgets('an initial billing read failure has an explicit retry', (
    tester,
  ) async {
    final repository = _Repository()..billingError = NetworkException();
    await _pump(tester, repository);
    await _openBilling(tester);
    expect(find.widgetWithText(FilledButton, '保存计费设置'), findsNothing);
    repository.billingError = null;
    await tester.ensureVisible(find.byTooltip('重新读取计费设置'));
    await tester.tap(find.byTooltip('重新读取计费设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '保存计费设置'), findsOneWidget);
    expect(repository.saved, isEmpty);
  });

  testWidgets(
    'billing denial invalidates an audit read that was already in flight',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      final pendingRead = Completer<Map<String, dynamic>>();
      repository.pendingReads.add(pendingRead.future);
      await tester.tap(find.byTooltip('刷新记录'));
      await tester.pump();
      await _openBilling(tester);
      final pendingSave = Completer<Map<String, dynamic>>();
      repository.pendingSave = pendingSave;
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.tap(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      pendingSave.completeError(
        ApiException('FORBIDDEN', '不可继续读取费用', httpStatus: 403),
      );
      // The refresh still owns pendingRead: its spinner correctly remains
      // active after billing closes, until the stale read itself completes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      pendingRead.complete(_data(question: '拒绝后的迟到内容'));
      await tester.pumpAndSettle();
      expect(find.text('拒绝后的迟到内容'), findsNothing);
      expect(find.byType(UtenDropdownField), findsNothing);
      expect(
        tester
            .widget<UtenAppBarActionButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is UtenAppBarActionButton &&
                    widget.tooltip == '刷新记录',
              ),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  for (final locale in ['en', 'ko']) {
    testWidgets('$locale records and billing use localized labels', (
      tester,
    ) async {
      final repository = _Repository();
      await _pump(
        tester,
        repository,
        width: 390,
        height: 1100,
        locale: Locale(locale),
      );
      final l10n = lookupAppLocalizations(Locale(locale));
      expect(find.text(l10n.aiAuditTitle), findsOneWidget);
      expect(find.text(l10n.aiRecordsStatUnknownFooter(1)), findsOneWidget);
      expect(find.text('使用记录与费用'), findsNothing);
      await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(l10n.aiRecordsBillingOpen));
      await tester.tap(find.text(l10n.aiRecordsBillingOpen));
      await tester.pumpAndSettle();
      for (final entry in {
        l10n.aiAuditInputPrice: '1.0',
        l10n.aiAuditOutputPrice: '2.0',
      }.entries) {
        final field = find.byWidgetPredicate(
          (widget) => widget is UtenInput && widget.label == entry.key,
        );
        expect(field, findsOneWidget);
        final input = tester.widget<TextField>(
          find.descendant(of: field, matching: find.byType(TextField)),
        );
        expect(input.controller!.text, entry.value);
        expect(input.decoration!.hintText, entry.key);
      }
      expect(find.text(l10n.aiAuditSaveBilling), findsOneWidget);
      expect(find.byTooltip('关闭操作面板'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final boundary in [
    'account',
    'permission',
    'server',
    'snapshot',
    'readonly',
    'actor',
    'admin',
  ]) {
    testWidgets(
      '$boundary change hides existing questions and rejects a late read',
      (tester) async {
        final repository = _Repository();
        final harness = await _pump(tester, repository);
        expect(find.text('原账号问题内容'), findsOneWidget);
        final pending = Completer<Map<String, dynamic>>();
        repository.pendingReads.add(pending.future);
        await tester.tap(find.byTooltip('刷新记录'));
        await tester.pump();
        repository.data = _data(question: '新账号记录');
        harness.change(boundary);
        await tester.pumpAndSettle();
        expect(find.text('原账号问题内容'), findsNothing);
        pending.complete(_data(question: '旧请求迟到的私密问题'));
        await tester.pumpAndSettle();
        expect(find.text('旧请求迟到的私密问题'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'stale billing callback cannot send old values after a server switch',
    (tester) async {
      final repository = _Repository();
      final harness = await _pump(tester, repository);
      await _openBilling(tester);
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存计费设置'))
          .onPressed!;
      harness.change('server');
      // A retained callback must be fenced even before the scheduled rebuild.
      save();
      await tester.pumpAndSettle();
      expect(repository.saved, isEmpty);
    },
  );

  testWidgets(
    'late billing save does not refresh another account or show success',
    (tester) async {
      final repository = _Repository();
      final harness = await _pump(tester, repository);
      await _openBilling(tester);
      final pending = Completer<Map<String, dynamic>>();
      repository.pendingSave = pending;
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.tap(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.pump();
      expect(repository.saved, hasLength(1));
      final readCount = repository.reads.length;
      harness.change('account');
      // 保存仍在途(抽屉转圈): 固定泵帧, 不能 settle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      pending.complete({
        'version': 8,
        'billingMode': 'METERED',
        'model': 'old-private-model',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已保存，仅影响后续调用。'), findsNothing);
      expect(find.textContaining('old-private-model'), findsNothing);
      await _closeBilling(tester);
      await tester.pumpAndSettle();
      // 换账号后页面整体重建(owner 变化), 新会话只允许这一次全新读取;
      // 旧会话的收尾回调不允许再读, 也不显示旧账号的成功提示。
      expect(repository.reads, hasLength(readCount + 1));
    },
  );

  testWidgets('390 wide records and billing render without overflow', (
    tester,
  ) async {
    await setCaptureView(tester, const Size(390, 1100));
    final repository = _Repository()
      ..data = _data(
        costs: [
          {'basis': 'ESTIMATE', 'currency': 'CNY', 'amount': '1.23'},
          {'basis': 'ACTUAL', 'currency': 'USD', 'amount': '0.45'},
        ],
        unknown: 2,
      );
    await _pump(tester, repository, width: 390, height: 1100, screenshot: true);
    await capture(tester, 'usage-records-390');
    await _openBilling(tester);
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存计费设置'));
    await tester.pumpAndSettle();
    await capture(tester, 'usage-records-billing-390');
    expect(tester.takeException(), isNull);
  }, skip: !kCaptureUi);
}

const _providerId = '11111111-1111-4111-8111-111111111111';
const _originalScope = AuthenticatedScope(userId: 'admin-a');
final _scope = StateProvider<AuthenticatedScope?>((ref) => _originalScope);
final _server = StateProvider<String>((ref) => 'https://one.invalid/api');
final _permissions = StateProvider<Set<String>>(
  (ref) => {Perm.authorizationManage},
);
final _session = StateProvider<SessionState>((ref) => _admin());

SessionState _admin({String id = 'admin-a', bool superAdmin = true}) =>
    SessionState(
      status: AuthStatus.authenticated,
      user: AppUser(
        id: id,
        code: id,
        name: id,
        superAdmin: superAdmin,
        permissions: const [Perm.authorizationManage],
      ),
    );

class _Session extends SessionNotifier {
  @override
  SessionState build() => ref.watch(_session);
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);
  void expire() => state = const AsyncLoading();
}

class _Harness {
  _Harness(this.container);
  final ProviderContainer container;
  void change(String boundary) {
    switch (boundary) {
      case 'account':
        container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'admin-b',
        );
        container.read(_session.notifier).state = _admin(id: 'admin-b');
      case 'permission':
        container.read(_permissions.notifier).state = {};
      case 'server':
        container.read(_server.notifier).state = 'https://two.invalid/api';
      case 'snapshot':
        (container.read(sessionSnapshotProvider.notifier) as _Snapshot)
            .expire();
      case 'readonly':
        container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'admin-a',
          readOnly: true,
        );
      case 'actor':
        container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'admin-a',
          actorId: 'actor',
        );
      case 'admin':
        container.read(_session.notifier).state = _admin(superAdmin: false);
    }
  }
}

Future<_Harness> _pump(
  WidgetTester tester,
  _Repository repository, {
  double width = 1000,
  double height = 1200,
  bool screenshot = false,
  Locale locale = const Locale('zh'),
  _Providers? providers,
}) async {
  await setCaptureView(tester, Size(width, height));
  var koreanFontLoaded = false;
  if (kCaptureUi && locale.languageCode == 'ko') {
    // Widget tests do not load the app's Windows Korean fallback by default.
    // This is test-only: no system font is added to the application assets.
    await tester.runAsync(() async {
      final font = File('C:/Windows/Fonts/malgun.ttf');
      if (await font.exists()) {
        final bytes = ByteData.sublistView(await font.readAsBytes());
        await (FontLoader('AuditKorean')..addFont(Future.value(bytes))).load();
        koreanFontLoaded = true;
      }
    });
  }
  final container = ProviderContainer(
    overrides: [
      ...await baseOverrides(),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      aiUsageAuditRepositoryProvider.overrideWithValue(repository),
      aiProviderRepositoryProvider.overrideWithValue(providers ?? _Providers()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: screenshot ? captureBoundary : null,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: _auditTheme(korean: koreanFontLoaded),
          home: const AdminAiUsageRecordsPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container);
}

ThemeData _auditTheme({required bool korean}) {
  final base = captureTheme();
  if (!korean) return base;
  TextStyle font(TextStyle? style) => (style ?? const TextStyle()).copyWith(
    fontFamily: 'AuditKorean',
    fontFamilyFallback: const ['NotoSansSC'],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: 'AuditKorean',
      fontFamilyFallback: const ['NotoSansSC'],
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: 'AuditKorean',
      fontFamilyFallback: const ['NotoSansSC'],
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: font(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: font(base.listTileTheme.subtitleTextStyle),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      labelStyle: font(
        base.inputDecorationTheme.labelStyle ?? base.textTheme.bodySmall,
      ),
      floatingLabelStyle: font(
        base.inputDecorationTheme.floatingLabelStyle ??
            base.textTheme.bodySmall,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(
          font(base.filledButtonTheme.style?.textStyle?.resolve({})),
        ),
      ),
    ),
  );
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == label,
);

Future<void> _select(WidgetTester tester, String label, String choice) async {
  final target = _field(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  await tester.tap(find.text(choice).last);
  await tester.pumpAndSettle();
}

/// 计费抽屉只有一个服务商时自动选中, 打开即出表单。
/// 用固定时长泵帧: 页面可能在途读取(不确定进度条), pumpAndSettle 永不落定。
Future<void> _openBilling(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('ai-records-billing-open'));
  if (!tester.any(button)) {
    await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _closeBilling(WidgetTester tester) async {
  await tester.tap(find.byTooltip('关闭'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final field = find.byWidgetPredicate(
    (widget) => widget is UtenInput && widget.label == label,
  );
  await tester.ensureVisible(field);
  await tester.enterText(
    find.descendant(of: field, matching: find.byType(EditableText)),
    value,
  );
  await tester.pump();
}

Future<void> _save(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, '保存计费设置');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _data({
  String question = '原账号问题内容',
  int total = 1,
  List<Map<String, dynamic>> costs = const [],
  int unknown = 1,
}) => {
  'summary': {
    'uses': 3,
    'calls': 3,
    'costs': costs,
    'unknownCostCalls': unknown,
  },
  'users': [
    {
      'userId': 'employee-1',
      'name': '示例员工',
      'code': 'E001',
      'uses': 3,
      'calls': 3,
      'costs': <Map<String, dynamic>>[],
      'unknownCostCalls': 1,
    },
  ],
  'records': [
    {
      'id': 'job-1',
      'name': '示例员工',
      'code': 'E001',
      'question': question,
      'status': 'SUCCEEDED',
      'kind': 'ERP_CHAT',
      'createdAt': '2026-10-03T12:00:00Z',
      'calls': 1,
      'inputTokens': null,
      'outputTokens': null,
      'costs': <Map<String, dynamic>>[],
      'unknownCostCalls': 1,
    },
  ],
  'total': total,
};

class _HeaderRepository extends _Repository
    implements AiUsageAuditHeaderRepository {
  final headerReads = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> readWithHeaders({
    int days = 30,
    int page = 0,
    int size = 20,
    String? userId,
    String? providerId,
    Map<String, String?> filters = const {},
    String? sort,
    bool ascending = true,
  }) {
    headerReads.add({
      'page': page,
      'filters': Map.of(filters),
      'sort': sort,
      'ascending': ascending,
    });
    return super.read(
      days: days,
      page: page,
      size: size,
      userId: userId,
      providerId: providerId,
    );
  }
}

class _Repository implements AiUsageAuditRepository {
  Map<String, dynamic> data = _data();
  Map<int, Map<String, dynamic>>? pages;
  final reads = <Map<String, dynamic>>[];
  final pendingReads = Queue<Future<Map<String, dynamic>>>();
  final saved = <(String, Map<String, dynamic>)>[];
  Object? saveError;
  Object? billingError;
  void Function(Map<String, dynamic>)? afterSave;
  Completer<Map<String, dynamic>>? pendingSave;
  Completer<Map<String, dynamic>>? pendingBilling;
  final billingValue = <String, dynamic>{
    'version': 7,
    'billingMode': 'METERED',
    'currency': 'CNY',
    'inputPerMillion': '1.0',
    'outputPerMillion': '2.0',
    'model': 'fixture-model',
  };
  @override
  Future<Map<String, dynamic>> read({
    int days = 30,
    int page = 0,
    int size = 20,
    String? userId,
    String? providerId,
  }) {
    reads.add({
      'days': days,
      'page': page,
      'size': size,
      'userId': userId,
      'providerId': providerId,
    });
    return pendingReads.isEmpty
        ? Future.value(pages?[page] ?? data)
        : pendingReads.removeFirst();
  }

  @override
  Future<Map<String, dynamic>> billing(String providerId) async {
    if (billingError case final error?) throw error;
    if (pendingBilling case final pending?) return pending.future;
    return Map.of(billingValue);
  }

  @override
  Future<Map<String, dynamic>> saveBilling(
    String providerId,
    Map<String, dynamic> values,
  ) async {
    saved.add((providerId, Map.of(values)));
    if (saveError case final error?) throw error;
    if (pendingSave case final pending?) return pending.future;
    afterSave?.call(values);
    return {
      ...values,
      'version': (values['version'] as int) + 1,
      'model': 'fixture-model',
    };
  }
}

class _Providers implements AiProviderRepository {
  int version = 7, reads = 0;
  String name = '测试 AI 服务';
  final enabledVersions = <int?>[];
  final pending = Queue<Future<List<AiProviderConfig>>>();
  Object? listError, usageError;
  @override
  Future<List<AiProviderConfig>> list() async {
    reads++;
    if (listError case final error?) throw error;
    if (pending.isNotEmpty) return pending.removeFirst();
    return [
      AiProviderConfig.fromJson({
        'id': _providerId,
        'name': name,
        'version': version,
        'model': 'fixture-model',
        'enabled': true,
      }),
    ];
  }

  @override
  Future<AiPresetCatalog> presets() async => AiPresetCatalog.empty;
  @override
  Future<AiUsageSummary> usage({int days = 30}) async {
    if (usageError case final error?) throw error;
    return AiUsageSummary(days: days, providers: const []);
  }

  @override
  Future<void> setEnabled(
    String id, {
    required bool enabled,
    int? version,
  }) async => enabledVersions.add(version);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected provider operation ${invocation.memberName}',
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  String? path;
  Map<String, dynamic>? query;
  Object? body;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.query = query;
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    this.path = path;
    this.body = body;
    return {};
  }
}
