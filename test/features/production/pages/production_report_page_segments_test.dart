// 生产报表页（计划明细/汇总）分段计数与草稿段合并回归（2026-09-26 全站草稿口径）：
// 此前四个状态分段（全部/已审/草稿/红冲）不挂数、草稿段不合并本地草稿——对照
// production_plan_list_page 补齐：草稿红数（含本地「新建生产计划」表单草稿投影）、
// 已审/红冲中性数；草稿段行点击仍跳生产计划详情。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _FixedFormDrafts extends FormDraftsNotifier {
  _FixedFormDrafts(this.initial);
  final List<FormDraft> initial;
  @override
  List<FormDraft> build() => initial;
}

void main() {
  testWidgets('status segments carry counts and draft segment merges rows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    // 本地「新建生产计划」填写草稿 1 份（kind=productionPlan）。
    final localDraft = FormDraft(
      id: 'local-draft-1',
      title: '新建生产计划',
      module: BadgeModule.production,
      draftKind: 'productionPlan',
      route: '/production/plans/new',
      permission: '',
      updatedAt: DateTime.now(),
      data: const {},
    );
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ReportApi();
    final router = GoRouter(
      initialLocation: '/production/reports/plan-detail',
      routes: [
        GoRoute(
          path: '/production/reports/:kind',
          builder: (_, state) => ProductionReportPage(
            kind: state.pathParameters['kind'] == 'plan-summary'
                ? ProductionReportKind.summary
                : ProductionReportKind.detail,
          ),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) =>
              Scaffold(body: Text('计划详情 ${state.pathParameters['id']}')),
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
            Perm.productionReportView,
            Perm.productionPlanView,
          }),
          formDraftsProvider.overrideWith(() => _FixedFormDrafts([localDraft])),
          fixedBadgeSummaryOverride(badgeSummaryFixture()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    int badgeCount(String label) => tester
        .widget<UtenNotificationBadge>(
          find.descendant(
            of: find.byWidgetPredicate(
              (widget) =>
                  widget is UtenSegmentBadgeLabel && widget.label == label,
            ),
            matching: find.byType(UtenNotificationBadge),
          ),
        )
        .count;

    // 分段计数：草稿 = 服务端 2 + 本地计划草稿 1（红）；已审 5（中性括号数）。
    expect(badgeCount('草稿'), 3);
    expect(find.text('(5)'), findsOneWidget, reason: '已审中性括号数');

    // 草稿段：合并本地草稿行 + 服务端行，行点击跳计划详情。
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();
    expect(api.lastQuery?['status'], 0);
    expect(find.text('SC26080001'), findsOneWidget);
    // 本地表单草稿合并在同一张表（单据号列统一投影为「未提交草稿」）。
    expect(find.text('未提交草稿'), findsOneWidget);
    await tester.tap(find.text('SC26080001'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('SC26080001'));
    await tester.pumpAndSettle();
    expect(find.text('计划详情 plan-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 报表行（两张计划草稿）+ 分段计数（草稿 2 / 已审 5 / 红冲 0）的假 API。
class _ReportApi extends ApiClient {
  _ReportApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/reports/plan/')) {
      lastQuery = query == null ? null : Map<String, dynamic>.from(query);
      return {
        'columns': [
          {'key': 'billNo', 'label': '单据号', 'width': 140},
          {'key': 'billDate', 'label': '单据日期', 'type': 'date', 'width': 120},
        ],
        'rows': [
          {
            'billNo': 'SC26080001',
            'billDate': '2026-08-31',
            '__srcId': 'plan-1',
          },
          {
            'billNo': 'SC26080002',
            'billDate': '2026-08-31',
            '__srcId': 'plan-2',
          },
        ],
        'facets': <String, dynamic>{},
        'page': 1,
        'total': 2,
        'totalPages': 1,
      };
    }
    if (path.contains('status-counts')) {
      return const {'DRAFT': 2, 'APPROVED': 5, 'REVERSED': 0};
    }
    return const {};
  }
}
