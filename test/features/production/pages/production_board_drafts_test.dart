// 生产任务中心（production_board_page）「草稿」段回归（2026-09-26 全站草稿口径）：
// 此前该段是 module=production 的本地草稿列表——没有登记的表单来源，恒空恒 0
// （死段）。现在显示服务端草稿：生产计划草稿（plan status=draft，内嵌计划列表页
// 草稿段）+ 生产日报草稿（status=0，内嵌日报列表页草稿段），计数与 hub 任务中心
// 卡红数同源（drafts.productionPlan + drafts.productionDailyReport），行可跳详情。
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
import 'package:uten_imp/shared/auth/permissions.dart';
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
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
            Perm.productionDailyReportView,
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

    // 子分段：生产计划草稿(2) / 生产日报草稿(1)，默认落计划草稿段。
    expect(find.text('生产计划草稿'), findsOneWidget);
    expect(find.text('生产日报草稿'), findsOneWidget);
    final planSegment = find.byWidgetPredicate(
      (widget) => widget is UtenSegmentBadgeLabel && widget.label == '生产计划草稿',
    );
    expect(
      tester
          .widget<UtenNotificationBadge>(
            find.descendant(
              of: planSegment,
              matching: find.byType(UtenNotificationBadge),
            ),
          )
          .count,
      2,
    );
    // 内嵌计划列表页：深链预选草稿段（status=0 请求），行可见。
    expect(api.lastPlansQuery?['status'], 0);
    expect(find.text('SC26080001'), findsOneWidget);

    // 行可跳计划详情。
    await tester.tap(find.text('SC26080001'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('SC26080001'));
    await tester.pumpAndSettle();
    expect(find.text('计划详情 plan-1'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    // 切到日报草稿段：status=0 请求、行可见、可跳日报详情。
    await tester.tap(find.text('生产日报草稿'));
    await tester.pumpAndSettle();
    expect(api.lastReportsQuery?['status'], 0);
    expect(find.text('SR26090001'), findsOneWidget);
    await tester.tap(find.text('SR26090001'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('SR26090001'));
    await tester.pumpAndSettle();
    expect(find.text('日报详情 report-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans') {
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
