import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_names.dart';
import 'config/production_report_config.dart';
import 'models/production_material_analysis.dart';
import 'pages/production_analysis_sales_order_page.dart';
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
import 'pages/production_overproduction_rate_pages.dart';
import 'pages/production_material_increment_pages.dart';
import 'pages/production_actual_output_supplement_page.dart';
import 'repositories/production_actual_output_supplement_repository.dart';
import 'pages/production_draw_request_page.dart';
import 'pages/production_execution_batch_page.dart';

/// 生产模块公开路由清单。
///
/// 静态路径必须排在带 `:id` 的参数路径前，避免 Web 深链误匹配。
final List<RouteBase> productionRoutes = [
  GoRoute(
    path: RouteName.productionMaterialIncrementRequests,
    builder: (_, _) => const ProductionMaterialIncrementListPage(),
  ),
  GoRoute(
    path: '/production/material-increment-requests/new',
    builder: (_, state) => ProductionMaterialIncrementCreatePage(
      segmentId: state.uri.queryParameters['segmentId'] ?? '',
    ),
  ),
  GoRoute(
    path: '/production/material-increment-requests/:id',
    builder: (_, state) => ProductionMaterialIncrementDetailPage(
      id: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/production/actual-output-supplements/:id',
    builder: (_, state) => ProductionActualOutputSupplementPage(
      id: state.pathParameters['id']!,
      returnToReport: state.extra == 'return-to-report',
    ),
  ),
  GoRoute(
    path: RouteName.productionOverproductionRateRequests,
    builder: (_, _) => const ProductionOverproductionRateListPage(),
  ),
  GoRoute(
    path: '/production/overproduction-rate-requests/:id',
    builder: (_, state) =>
        ProductionOverproductionRateDetailPage(id: state.pathParameters['id']!),
  ),
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
    path: RouteName.productionBatchDraw,
    name: 'production-batch-draw',
    builder: (_, state) => ProductionExecutionBatchPage(
      segmentId: state.uri.queryParameters['segmentId'] ?? '',
      expectedVersion: int.tryParse(state.uri.queryParameters['version'] ?? ''),
    ),
  ),
  GoRoute(
    path: RouteName.productionDrawRequest,
    name: 'production-draw-request',
    builder: (_, state) {
      final ids =
          state.uri.queryParameters['segmentIds']?.split(',') ??
          const <String>[];
      final versions =
          state.uri.queryParameters['versions']?.split(',') ?? const <String>[];
      return ProductionDrawRequestPage(
        segmentIds: ids,
        expectedVersions: {
          for (var i = 0; i < ids.length && i < versions.length; i++)
            ids[i]: ?int.tryParse(versions[i]),
        },
      );
    },
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
    // 旧「section=subcontract-preparations」深链：委外准备中心已退役
    // （2026-09-05），一律改写到委外管理 hub；查询参数不再传递。
    redirect: (_, state) {
      if (state.uri.queryParameters['section'] != 'subcontract-preparations') {
        return null;
      }
      return RouteName.subcontract;
    },
    builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(),
  ),
  // 关联销售订货单只读货品清单(ADR-088)。静态段 summary 在前，
  // 本路由的第三段是固定字面量 sales-orders，两条互不遮挡。
  GoRoute(
    path: '/production/material-analyses/:id/sales-orders/:orderId',
    name: 'production-analysis-sales-order',
    builder: (_, state) => ProductionAnalysisSalesOrderPage(
      key: ValueKey(
        '${state.pathParameters['id']}/${state.pathParameters['orderId']}',
      ),
      analysisId: state.pathParameters['id']!,
      orderId: state.pathParameters['orderId']!,
    ),
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
    // ?status=draft：新建页「草稿(N)」按钮深链，直接落在草稿段。
    builder: (_, state) => ProductionPlanListPage(
      initialStatus: state.uri.queryParameters['status'],
    ),
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
        id: state.extra is ProductionOutputSupplementView
            ? (state.extra as ProductionOutputSupplementView).excludedReportId
            : null,
        initialSupplement: state.extra is ProductionOutputSupplementView
            ? state.extra as ProductionOutputSupplementView
            : null,
        initialExecutionSegmentId:
            state.uri.queryParameters['executionSegmentId'],
        initialExecutionSegmentIds: batch ?? const [],
        // 保存后的落点：从车间任务 push 进来（from=workshop-tasks）保存成功
        // pop 回任务页（列表+徽章随之刷新）；其余入口照旧 replace 成详情页。
        returnToWorkshopTasks:
            state.uri.queryParameters['from'] == 'workshop-tasks',
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
    builder: (_, state) => ProductionDailyReportListPage(
      initialStatus: state.uri.queryParameters['status'],
    ),
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
