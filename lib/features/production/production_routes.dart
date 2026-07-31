import 'package:go_router/go_router.dart';

import '../../core/router/route_names.dart';
import 'config/production_report_config.dart';
import 'pages/production_board_page.dart';
import 'pages/production_daily_report_detail_page.dart';
import 'pages/production_daily_report_edit_page.dart';
import 'pages/production_daily_report_list_page.dart';
import 'pages/production_hub_page.dart';
import 'pages/production_plan_detail_page.dart';
import 'pages/production_plan_edit_page.dart';
import 'pages/production_plan_list_page.dart';
import 'pages/production_report_page.dart';
import 'pages/where_used_report_page.dart';

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
    builder: (_, _) => const ProductionBoardPage(),
  ),
  GoRoute(
    path: RouteName.productionProgress,
    name: 'production-progress',
    builder: (_, _) => const ProductionBoardPage(initialTab: 1),
  ),
  GoRoute(
    path: '/production/plans/new',
    name: 'production-plan-new',
    builder: (_, _) => const ProductionPlanEditPage(),
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
    builder: (_, state) =>
        ProductionPlanDetailPage(id: state.pathParameters['id']!),
  ),
  GoRoute(
    path: RouteName.productionPlanList,
    name: 'production-plan-list',
    builder: (_, _) => const ProductionPlanListPage(),
  ),
  GoRoute(
    path: '/production/daily-reports/new',
    name: 'production-daily-report-new',
    builder: (_, state) => ProductionDailyReportEditPage(
      initialExecutionSegmentId:
          state.uri.queryParameters['executionSegmentId'],
    ),
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
];
