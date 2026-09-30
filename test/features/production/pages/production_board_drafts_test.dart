// 生产计划与日报草稿同表：类别表头筛选、页级搜索、刷新和详情路由。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_table.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

void main() {
  testWidgets('drafts segment shows plan and daily report drafts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BoardDraftsApi();
    final router = GoRouter(
      initialLocation: '/production/schedule',
      routes: [
        GoRoute(
          path: '/production/schedule',
          builder: (_, _) => const ProductionBoardPage(),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) =>
              Scaffold(body: Text('计划详情 ${state.pathParameters['id']}')),
        ),
        GoRoute(
          path: '/production/daily-reports/:id',
          builder: (context, state) =>
              Scaffold(body: Text('日报详情 ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'planner-1'),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
            Perm.productionDailyReportView,
            Perm.productionMaterialAnalysisCreate,
            Perm.productionDailyReportCreate,
            Perm.productionPlanApprove,
            Perm.productionPlanDelete,
          }),
          // hub/大类行红数同源：待排产 1 + 计划草稿 2 + 日报草稿 1。
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: {
                'productionSchedule.count': 1,
                'drafts.productionPlan': 2,
                'drafts.productionDailyReport': 1,
              },
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 大类行「草稿」红数 = 计划草稿 2 + 日报草稿 1（不再是恒 0 的死段）。
    final draftsLabel = find.byWidgetPredicate(
      (widget) => widget is UtenSegmentBadgeLabel && widget.label == '草稿',
    );
    expect(draftsLabel, findsOneWidget);
    final draftsBadge = find.descendant(
      of: draftsLabel,
      matching: find.byType(UtenNotificationBadge),
    );
    expect(tester.widget<UtenNotificationBadge>(draftsBadge).count, 3);

    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();

    // 一张表同时显示两种业务草稿，不再嵌套类型、状态和第二个搜索栏。
    expect(find.byType(DraftWorkspaceTable), findsOneWidget);
    expect(find.byKey(const Key('production-board-draft-kinds')), findsNothing);
    expect(find.text('生产计划草稿'), findsNothing);
    expect(find.text('生产日报草稿'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('新建计划'), findsOneWidget);
    expect(find.text('新建日报'), findsOneWidget);
    expect(find.text('超产比例审批'), findsOneWidget);
    expect(find.text('批量审核计划 (0)'), findsOneWidget);
    expect(api.lastPlansQuery?['status'], 0);
    expect(api.lastReportsQuery?['status'], 0);
    expect(find.text('SC26080001'), findsOneWidget);
    expect(find.text('SR26090001'), findsOneWidget);

    await tester.tap(find.text('类别'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生产日报 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('SC26080001'), findsNothing);
    expect(find.text('SR26090001'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有'));
    await tester.pumpAndSettle();

    // 统一的搜索同时作用于计划和日报。
    await tester.enterText(find.byType(TextField), 'SC26080001');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('SR26090001'), findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('SR26090001'), findsOneWidget);

    final readsBeforeRefresh = api.planReads;
    await tester.tap(find.byKey(const Key('production-pending-refresh')));
    await tester.pumpAndSettle();
    expect(api.planReads, greaterThan(readsBeforeRefresh));

    // 行可跳计划详情。
    await tester.tap(find.text('SC26080001'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('SC26080001'));
    await tester.pumpAndSettle();
    expect(find.text('计划详情 plan-1'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    // 同一表中的日报行保留详情路由。
    expect(api.lastReportsQuery?['status'], 0);
    expect(find.text('SR26090001'), findsOneWidget);
    await tester.tap(find.text('SR26090001'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('SR26090001'));
    await tester.pumpAndSettle();
    expect(find.text('日报详情 report-1'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
      find.byType(MasterDataTableView<DraftWorkspaceRow>),
    );
    table.onSelectedIdsChanged!({
      'productionPlan:plan-1',
      'productionPlan:plan-2',
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量删除计划 (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认批量删除'));
    await tester.pumpAndSettle();
    expect(api.batchDeleteRequests, 1);
    expect(api.batchDeletedIds, ['plan-1', 'plan-2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'plan approval uses batch API and keeps selection locked until complete',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final completion = Completer<Map<String, dynamic>>();
      final api = _BoardDraftsApi()..approvalResult = completion;
      final router = GoRouter(
        initialLocation: '/production/schedule',
        routes: [
          GoRoute(
            path: '/production/schedule',
            builder: (_, _) => const ProductionBoardPage(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'planner-1'),
            ),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanView,
              Perm.productionDailyReportView,
              Perm.productionPlanApprove,
            }),
            fixedBadgeSummaryOverride(badgeSummaryFixture()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('草稿'));
      await tester.pumpAndSettle();
      MasterDataTableView<DraftWorkspaceRow> table() =>
          tester.widget(find.byType(MasterDataTableView<DraftWorkspaceRow>));
      final beforeRequest = table();
      beforeRequest.onSelectedIdsChanged!({'productionPlan:plan-1'});
      await tester.pumpAndSettle();
      expect(find.text('批量删除计划 (1)'), findsNothing);
      await tester.tap(find.text('批量审核计划 (1)'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('reviewer-responsibility-notice')),
        findsOneWidget,
      );
      await tester.tap(find.text('确认批量审核'));
      await tester.pumpAndSettle();
      expect(api.batchApproveRequests, 1);
      expect(api.batchApprovedIds, ['plan-1']);
      expect(
        tester
            .widget<DraftWorkspaceTable>(find.byType(DraftWorkspaceTable))
            .selectionLocked,
        isTrue,
      );

      // A retained callback is also fenced while the request is in flight.
      beforeRequest.onSelectedIdsChanged!({'productionPlan:plan-2'});
      table().onClearSelection?.call();
      await tester.pump();
      expect(table().selectedIds, {'productionPlan:plan-1'});

      completion.complete({
        'done': [
          {'id': 'plan-1'},
        ],
        'skipped': [],
      });
      await tester.pumpAndSettle();
      expect(table().selectedIds, isEmpty);
      expect(
        tester
            .widget<DraftWorkspaceTable>(find.byType(DraftWorkspaceTable))
            .selectionLocked,
        isFalse,
      );
      expect(api.batchApproveRequests, 1);
      expect(api.batchDeleteRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drafts segment guides without view permissions', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/production/schedule',
      routes: [
        GoRoute(
          path: '/production/schedule',
          builder: (_, _) => const ProductionBoardPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_BoardDraftsApi()),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('production-board-drafts-no-permission')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

/// 计划草稿 2 张 + 日报草稿 1 张的假 API（记录最近一次列表查询参数）。
class _BoardDraftsApi extends ApiClient {
  _BoardDraftsApi() : super(Dio());

  Map<String, dynamic>? lastPlansQuery;
  Map<String, dynamic>? lastReportsQuery;
  int planReads = 0;
  int batchDeleteRequests = 0;
  List<String> batchDeletedIds = const [];
  int batchApproveRequests = 0;
  List<String> batchApprovedIds = const [];
  Completer<Map<String, dynamic>>? approvalResult;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans/batch-approve') {
      batchApproveRequests++;
      batchApprovedIds = List<String>.from((body! as Map)['ids'] as List);
      return await approvalResult!.future;
    }
    if (path == '/production/plans/batch-delete') {
      batchDeleteRequests++;
      batchDeletedIds = List<String>.from((body! as Map)['ids'] as List);
      return {
        'done': [
          for (final id in batchDeletedIds) {'id': id},
        ],
        'skipped': [],
      };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans') {
      planReads++;
      lastPlansQuery = query == null ? null : Map<String, dynamic>.from(query);
      return {
        'items': [
          {
            'id': 'plan-1',
            'billNo': 'SC26080001',
            'billDate': '2026-08-31',
            'status': 0,
          },
          {
            'id': 'plan-2',
            'billNo': 'SC26080002',
            'billDate': '2026-08-31',
            'status': 0,
          },
        ],
        'page': 1,
        'total': 2,
        'totalPages': 1,
      };
    }
    if (path == '/production/daily-reports') {
      lastReportsQuery = query == null
          ? null
          : Map<String, dynamic>.from(query);
      return {
        'items': [
          {
            'id': 'report-1',
            'billNo': 'SR26090001',
            'billDate': '2026-09-01',
            'workshopName': '装配一车间',
            'status': 0,
          },
        ],
        'page': 1,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path.contains('status-counts')) return const {};
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
