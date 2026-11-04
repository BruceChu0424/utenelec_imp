// 2026-11-04 我的申请改版：报销并入申请记录分类栏的契约测试。
// · hub 页不再有独立「我的报销」卡；
// · 申请记录页分类栏新增「报销申请」段（红黄徽章 = 原 hub 卡同口径），
//   选中后嵌入报销列表，不向业务申请接口发请求、不把 EXPENSE 当 kind 下发；
// · 无 expenseApply 权限不显示该段；?kind=EXPENSE 直达报销视图。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/pages/business_application_list_page.dart';
import 'package:uten_imp/features/applications/pages/my_applications_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'applicant',
      employeeId: 'applicant-employee',
      code: 'E001',
      name: '申请员工',
      department: '综合营销部',
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final queries = <({String path, Map<String, dynamic> query})>[];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async => [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add((path: path, query: Map.of(query ?? {})));
    if (path == '/business-applications/counts') {
      return {
        'mineDraftCount': 0,
        'mineRejectedCount': 0,
        'mineProcessingCount': 0,
        'mineByKind': const <String, dynamic>{},
        'pendingByScopeKind': const <String, dynamic>{},
      };
    }
    if (path == '/business-applications/mine') {
      return {
        'page': 1,
        'size': 24,
        'total': 1,
        'totalPages': 1,
        'items': [
          {
            'id': 'application-1',
            'applicationNo': 'SQ20261104000001',
            'kind': 'TRAVEL',
            'title': '客户现场出差申请',
            'amount': '1200.00',
            'status': 'SUBMITTED',
            'approvalStage': 'DEPARTMENT',
            'approvalStageLabel': '部门负责人审核',
            'canApprove': false,
            'applicantId': 'applicant',
            'applicantName': '申请员工',
            'departmentName': '综合营销部',
            'fields': <String, dynamic>{},
            'createdAt': '2026-11-04T09:00:00+08:00',
          },
        ],
      };
    }
    if (path == '/expense-claims/mine') {
      return {
        'page': 1,
        'size': 24,
        'total': 1,
        'totalPages': 1,
        'items': [_expenseClaim],
      };
    }
    if (path == '/expense-claims/facets') {
      return const <String, dynamic>{};
    }
    return <String, dynamic>{};
  }
}

const _expenseClaim = {
  'id': 'expense-1',
  'claimNo': 'BX20261104000001',
  'title': '客户现场差旅报销',
  'applicantId': 'applicant-employee',
  'applicantName': '申请员工',
  'departmentName': '综合营销部',
  'totalAmount': 2386.50,
  'expenseKind': 'TRAVEL',
  'status': 'SUBMITTED',
  'approvalRound': 1,
  'version': 3,
  'approvalStage': 'FINANCE_INITIAL',
  'canApprove': false,
  'createdAt': '2026-11-04T09:00:00+08:00',
  'items': <Map<String, dynamic>>[],
};

Future<GoRouter> _pump(
  WidgetTester tester,
  _Api api,
  String route, {
  Set<String>? permissions,
}) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: route,
    routes: [
      GoRoute(
        path: '/applications/mine',
        builder: (_, state) => BusinessApplicationListPage(
          key: ValueKey(state.uri.queryParameters['kind']),
          kind: state.uri.queryParameters['kind'],
        ),
      ),
      GoRoute(
        path: '/applications',
        builder: (_, _) => const MyApplicationsPage(),
      ),
      GoRoute(
        path: '/expense/new',
        builder: (_, _) => const Scaffold(body: Center(child: Text('报销编辑'))),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://applications.test/api'),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        currentPermissionsProvider.overrideWithValue(
          permissions ??
              const {
                Perm.expenseApply,
                Perm.applicationApply,
                Perm.attachmentView,
              },
        ),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            entries: {
              BadgeEntry.expenseMine: (2, 1),
              BadgeEntry.applicationMine: (3, 2),
            },
          ),
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

UtenFilterToolbar<String> _kindToolbar(WidgetTester tester) =>
    tester.widget<UtenFilterToolbar<String>>(
      find.byWidgetPredicate(
        (value) =>
            value is UtenFilterToolbar<String> &&
            value.segmentsKey == const Key('application-kind-filter'),
      ),
    );

void main() {
  testWidgets('hub keeps application records only, expense card removed', (
    tester,
  ) async {
    await _pump(tester, _Api(), '/applications');
    expect(find.text('申请记录'), findsOneWidget);
    // 2026-11-04 改版：报销并入申请记录分类栏，不再单独设卡。
    expect(find.text('我的报销'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expense segment embeds expense list without application reads', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api, '/applications/mine');
    expect(
      find.byType(MasterDataTableView<BusinessApplication>),
      findsOneWidget,
    );
    final mineReads = api.queries
        .where((q) => q.path == '/business-applications/mine')
        .length;

    final kinds = _kindToolbar(tester);
    final expense = kinds.segments.singleWhere(
      (value) => value.value == 'EXPENSE',
    );
    expect(expense.label, '报销申请');
    // 红黄徽章沿用原 hub「我的报销」卡口径（徽章汇总单一数据源）。
    expect(expense.count, 2);
    expect(expense.inProgressCount, 1);

    kinds.onSelectionChanged!('EXPENSE');
    await tester.pumpAndSettle();

    expect(find.byType(MasterDataTableView<ExpenseClaim>), findsOneWidget);
    expect(find.byType(MasterDataTableView<BusinessApplication>), findsNothing);
    // 申请状态栏让位给报销自己的分段。
    expect(
      find.byWidgetPredicate(
        (value) =>
            value is UtenFilterToolbar<String> &&
            value.segmentsKey == const Key('application-status-filter'),
      ),
      findsNothing,
    );
    // 报销列表已就绪；不追加业务申请读取。
    expect(
      api.queries.where((q) => q.path == '/business-applications/mine').length,
      mineReads,
    );
    expect(api.queries.any((q) => q.query['kind'] == 'EXPENSE'), isFalse);
    // 非草稿分段由页面悬浮按钮提供「新建报销」。
    expect(find.text('新建报销'), findsOneWidget);

    // 切回申请分类：申请表格与状态栏恢复，分页从第 1 页重新读取。
    _kindToolbar(tester).onSelectionChanged!('ALL');
    await tester.pumpAndSettle();
    expect(
      find.byType(MasterDataTableView<BusinessApplication>),
      findsOneWidget,
    );
    expect(find.byType(MasterDataTableView<ExpenseClaim>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('kind=EXPENSE deep link opens expense view directly', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api, '/applications/mine?kind=EXPENSE');
    expect(find.byType(MasterDataTableView<ExpenseClaim>), findsOneWidget);
    // 与其它 kind 深链一致：分类栏不显示，业务申请接口零请求。
    expect(
      find.byWidgetPredicate(
        (value) =>
            value is UtenFilterToolbar<String> &&
            value.segmentsKey == const Key('application-kind-filter'),
      ),
      findsNothing,
    );
    expect(
      api.queries.where((q) => q.path == '/business-applications/mine'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('expense segment hidden without expense apply grant', (
    tester,
  ) async {
    await _pump(
      tester,
      _Api(),
      '/applications/mine',
      permissions: const {Perm.applicationApply, Perm.attachmentView},
    );
    expect(find.text('报销申请'), findsNothing);
    expect(
      _kindToolbar(tester).segments.any((value) => value.value == 'EXPENSE'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
