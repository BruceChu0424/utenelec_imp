import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/auth/pending_review_provider.dart';
import '../../finance/providers/finance_procurement_approval_count_provider.dart';
import '../../finance/providers/sales_order_finance_confirmation_count_provider.dart';
import '../../hr_task/providers/hr_task_count_provider.dart';
import '../../production/providers/production_pending_provider.dart';
import '../../purchase/providers/purchase_task_count_provider.dart';
import '../../rd_task/providers/rd_task_count_provider.dart';
import '../../subcontract/providers/subcontract_task_count_provider.dart';
import '../../visitor_approval/providers/visitor_pending_count_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../../warehouse/providers/production_draw_count_provider.dart';
import '../../warehouse/providers/warehouse_sales_outbound_count_provider.dart';
import '../../warehouse/providers/warehouse_quality_result_count_provider.dart';
import '../../warehouse/repositories/warehouse_subcontract_outbound_repository.dart'
    show warehouseSubcontractOutboundCountProvider;
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import 'quality_inspection_pending_badge.dart';
import '../../sales/providers/sales_completion_count_provider.dart';

/// 工作台卡片通过枚举声明数据源，由共享组件统一取数和渲染。
enum WorkbenchBadgeKind {
  visitorHost, // 我的访客（被访人待确认）
  visitorApproval, // 访客审批（HR 待审批）
  hrReview, // 信息变更审核
  hrTask, // HR 任务中心（今日转正/逾期转正/今日生日/今日周年）
  production, // 生产管理（待排产）
  rdTask, // 任务中心
  warehouse, // 仓库管理（三张任务中心卡角标之和：出库+入库+领料+品质结果）
  purchase, // 采购管理（待分解 + 待采购完成）
  finance, // 钱流管理（订货审批 + 销售订单财务确认 + 超量到货审批）
  subcontract, // 委外管理（待退回供应商）
  sales, // 销售管理（财务驳回待修正 + 订单完工提醒）
  qualityInspection, // 品质任务中心（IQC 待检收货单 + FQC 待检行）
  none, // 暂无角标数据源（预留：以后接入时新增枚举值）
}

/// 导航「工作台」Tab 角标：全部模块卡角标（按种类去重）之和。
///
/// 与卡片/分组徽标同源同口径（单个来源加载中/失败按 0 计，不放大成异常态，
/// 与通知 Tab 的未读角标同款红圆数字）。常驻 provider 被外壳导航 watch 后，
/// autoDispose 计数源随之保持存活，由 refreshGlobalBadges（返回工作台 /
/// 新通知到达）与各 60s 轮询 notifier 驱动更新。
final workbenchTotalTodoCountProvider = Provider<int>((ref) {
  var total = 0;
  for (final kind in WorkbenchBadgeKind.values) {
    if (kind == WorkbenchBadgeKind.none) continue;
    total += _resolveCount(kind, ref.watch);
  }
  return total;
});

/// 工作台卡片角标；应放在 [UtenLazyMount] 内，避免首帧启动计数请求。
class WorkbenchCardBadge extends ConsumerWidget {
  const WorkbenchCardBadge({
    super.key,
    required this.kind,
    this.size = 20,
    this.showLabel = true,
  });

  final WorkbenchBadgeKind kind;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kind == WorkbenchBadgeKind.qualityInspection) {
      return QualityInspectionPendingBadge(size: size, showLabel: showLabel);
    }
    return UtenNotificationBadge(
      count: _resolveCount(kind, ref.watch),
      size: size,
      showLabel: showLabel,
    );
  }
}

/// 汇总组内全部模块角标；应放在 [UtenLazyMount] 内延后取数。
class WorkbenchGroupBadge extends ConsumerWidget {
  const WorkbenchGroupBadge({
    super.key,
    required this.kinds,
    this.size = 20,
    this.showLabel = true,
  });

  /// 组内各模块的角标种类（[WorkbenchBadgeKind.none] 不应出现，调用方已过滤）。
  final List<WorkbenchBadgeKind> kinds;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kinds.length == 1 &&
        kinds.single == WorkbenchBadgeKind.qualityInspection) {
      return QualityInspectionPendingBadge(size: size, showLabel: showLabel);
    }
    var total = 0;
    for (final kind in kinds) {
      total += _resolveCount(kind, ref.watch);
    }
    return UtenNotificationBadge(
      count: total,
      size: size,
      showLabel: showLabel,
    );
  }
}

int _resolveCount(
  WorkbenchBadgeKind kind,
  T Function<T>(ProviderListenable<T> listenable) watch,
) {
  switch (kind) {
    case WorkbenchBadgeKind.visitorHost:
      return watch(visitorHostPendingCountProvider);
    case WorkbenchBadgeKind.visitorApproval:
      return watch(visitorPendingCountProvider);
    case WorkbenchBadgeKind.hrReview:
      return watch(pendingReviewCountProvider);
    case WorkbenchBadgeKind.hrTask:
      return watch(hrTaskCountProvider);
    case WorkbenchBadgeKind.production:
      return watch(productionPendingCountProvider).count;
    case WorkbenchBadgeKind.rdTask:
      return watch(rdTaskCountProvider);
    case WorkbenchBadgeKind.purchase:
      return watch(purchaseTaskCountProvider);
    case WorkbenchBadgeKind.warehouse:
      // 仓库管理角标 = 三张任务中心卡角标之和（与 hub 任务中心同口径；
      // 草稿不计入待办数）：出库（销售待出库 + 委外出仓）+ 入库（预计到货 +
      // 到货异常 + 产成品待点收）+ 领料（待领任务）+ 品质部检查结果未完结任务数。
      return _sum(watch, [
        warehouseSalesOutboundPendingCountProvider,
        warehouseSubcontractOutboundCountProvider,
        warehouseInboundExpectationCountProvider,
        warehouseArrivalExceptionCountProvider,
        warehouseProductionDrawPendingCountProvider,
        warehouseProductionFinishedInboundPendingCountProvider,
        warehouseQualityResultPendingCountProvider,
      ]);
    case WorkbenchBadgeKind.finance:
      return _sum(watch, [
        financeProcurementApprovalCountProvider,
        salesOrderFinanceConfirmationCountProvider,
        financeArrivalExceptionCountProvider,
      ]);
    case WorkbenchBadgeKind.subcontract:
      // 委外对齐采购：卡片徽标 = 委外任务台待办数（非到货退回数）。
      return watch(subcontractTaskCountProvider);
    case WorkbenchBadgeKind.sales:
      return watch(salesAttentionCountProvider).valueOrNull ?? 0;
    case WorkbenchBadgeKind.qualityInspection:
      return _sum(watch, [
        procurementInspectionPendingCountProvider,
        productionFqcPendingCountProvider,
      ]);
    case WorkbenchBadgeKind.none:
      return 0;
  }
}

int _sum(
  T Function<T>(ProviderListenable<T> listenable) watch,
  List<ProviderListenable<AsyncValue<int>>> providers,
) {
  var total = 0;
  for (final provider in providers) {
    total += watch(provider)
        .when(data: (value) => value, error: (_, _) => 0, loading: () => 0);
  }
  return total;
}
