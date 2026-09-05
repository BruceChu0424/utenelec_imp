import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_names.dart';
import 'config/production_report_config.dart';
import 'models/production_material_analysis.dart';
import 'pages/production_board_page.dart';
import 'pages/production_chain_health_page.dart';
import 'pages/production_daily_report_detail_page.dart';
import 'pages/production_daily_report_edit_page.dart';
import 'pages/production_daily_report_list_page.dart';
import 'pages/production_hub_page.dart';
import 'pages/production_material_analysis_page.dart';
import 'pages/production_material_analysis_history_page.dart';
import 'pages/production_plan_detail_page.dart';
import 'pages/production_plan_edit_page.dart';
import 'pages/production_plan_list_page.dart';
import 'pages/production_plan_summary_sheet_page.dart';
import 'pages/production_report_page.dart';
import 'pages/where_used_report_page.dart';
import 'pages/production_workshop_tasks_page.dart';

/// 生产模块公开路由清单。
///
/// 静态路径必须排在带 `:id` 的参数路径前，避免 Web 深链误匹配。
final List<RouteBase> productionRoutes = [
  GoRoute(
    path: RouteName.production,
    name: 'production-hub',
    builder: (_, _) => const ProductionHubPage(),
  ),
  GoRoute(
    path: RouteName.productionSchedule,
    name: 'production-schedule',
    // 深链预选「待排产」大类段（2026-09-03 分类范式：默认不选，路由偏好例外）。
    builder: (_, _) => const ProductionBoardPage(initialTab: 0),
  ),
  GoRoute(
    path: RouteName.productionProgress,
    name: 'production-progress',
    builder: (_, _) => const ProductionBoardPage(initialTab: 1),
  ),
  GoRoute(
    path: RouteName.productionWorkshopTasks,
    name: 'production-workshop-tasks',
    builder: (_, _) => const ProductionWorkshopTasksPage(),
  ),
  GoRoute(
    path: RouteName.productionMaterialAnalysis,
    name: 'production-material-analysis',
    builder: (_, state) => ProductionMaterialAnalysisPage(
      seed: state.extra is ProductionMaterialAnalysisSeed
          ? state.extra! as ProductionMaterialAnalysisSeed
          : const ProductionMaterialAnalysisSeed(),
    ),
  ),
  GoRoute(
    path: RouteName.productionMaterialAnalysisHistory,
    name: 'production-material-analysis-history',
    // 旧「section=subcontract-preparations」深链兼容：一律改写到委外准备中心。
    redirect: (_, state) {
      if (state.uri.queryParameters['section'] != 'subcontract-preparations') {
        return null;
      }
      return RoutePath.productionSubcontractPreparations(
        planItemId: state.uri.queryParameters['planItemId'],
        sourceAnalysisId: state.uri.queryParameters['sourceAnalysisId'],
        sourceMaterialLineId: state.uri.queryParameters['sourceMaterialLineId'],
      );
    },
    builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(),
  ),
  GoRoute(
    path: '/production/material-analyses/:id/summary',
    name: 'production-material-analysis-summary',
    builder: (_, state) {
      final initialAnalysis = state.extra is ProductionMaterialAnalysisView
          ? state.extra! as ProductionMaterialAnalysisView
          : null;
      return ProductionPlanSummarySheetPage(
        analysisId: state.pathParameters['id']!,
        initialAnalysis: initialAnalysis,
      );
    },
  ),
  GoRoute(
    path: '/production/plans/new',
    name: 'production-plan-new',
    redirect: (_, _) => RouteName.productionMaterialAnalysis,
  ),
  GoRoute(
    path: '/production/plans/:id/edit',
    name: 'production-plan-edit',
    builder: (_, state) =>
        ProductionPlanEditPage(id: state.pathParameters['id']),
  ),
  GoRoute(
    path: '/production/plans/:id',
    name: 'production-plan-detail',
    builder: (_, state) {
      final id = state.pathParameters['id']!;
      return ProductionPlanDetailPage(
        key: ValueKey(id),
        id: id,
        initialExecutionSegmentId:
            state.uri.queryParameters['executionSegmentId'],
      );
    },
  ),
  GoRoute(
    path: RouteName.productionPlanList,
    name: 'production-plan-list',
    builder: (_, _) => const ProductionPlanListPage(),
  ),
  GoRoute(
    path: '/production/daily-reports/new',
    name: 'production-daily-report-new',
    builder: (_, state) {
      final batch = state.uri.queryParameters['executionSegmentIds']
          ?.split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .take(100)
          .toList(growable: false);
      return ProductionDailyReportEditPage(
        initialExecutionSegmentId:
            state.uri.queryParameters['executionSegmentId'],
        initialExecutionSegmentIds: batch ?? const [],
      );
    },
  ),
  GoRoute(
    path: '/production/daily-reports/:id/edit',
    name: 'production-daily-report-edit',
    builder: (_, state) =>
        ProductionDailyReportEditPage(id: state.pathParameters['id']),
  ),
  GoRoute(
    path: '/production/daily-reports/:id',
    name: 'production-daily-report-detail',
    builder: (_, state) =>
        ProductionDailyReportDetailPage(id: state.pathParameters['id']!),
  ),
  GoRoute(
    path: RouteName.productionDailyReportList,
    name: 'production-daily-report-list',
    builder: (_, _) => const ProductionDailyReportListPage(),
  ),
  GoRoute(
    path: RoutePath.productionReport('plan-detail'),
    name: 'production-report-plan-detail',
    builder: (_, _) =>
        const ProductionReportPage(kind: ProductionReportKind.detail),
  ),
  GoRoute(
    path: RoutePath.productionReport('plan-summary'),
    name: 'production-report-plan-summary',
    builder: (_, _) =>
        const ProductionReportPage(kind: ProductionReportKind.summary),
  ),
  GoRoute(
    path: RouteName.productionWhereUsed,
    name: 'production-where-used',
    builder: (_, _) => const WhereUsedReportPage(),
  ),
  GoRoute(
    path: RouteName.productionChainHealth,
    name: 'production-chain-health',
    builder: (_, _) => const ProductionChainHealthPage(),
  ),
];
