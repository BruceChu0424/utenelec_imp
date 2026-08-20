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
import '../../sales/providers/sales_completion_count_provider.dart';

/// 工作台卡片通过枚举声明数据源，由共享组件统一取数和渲染。
enum WorkbenchBadgeKind {
  visitorHost, // 我的访客（被访人待确认）
  visitorApproval, // 访客审批（HR 待审批）
  hrReview, // 信息变更审核
  hrTask, // HR 任务中心（今日转正/逾期转正/今日生日/今日周年）
  production, // 生产管理（待排产）
  rdTask, // 任务中心
  warehouse, // 仓库管理（预计到货 + 到货异常）
  purchase, // 采购管理（待分解 + 待采购完成）
  finance, // 钱流管理（订货审批 + 销售订单财务确认 + 超量到货审批）
  subcontract, // 委外管理（待退回供应商）
  sales, // 销售管理（订单完工提醒）
  qualityInspection, // 品质任务中心（待检处置：待检收货单张数）
  none, // 暂无角标数据源（预留：以后接入时新增枚举值）
}

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
    return UtenNotificationBadge(
      count: _resolveCount(kind, ref),
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
    var total = 0;
    for (final kind in kinds) {
      total += _resolveCount(kind, ref);
    }
    return UtenNotificationBadge(
      count: total,
      size: size,
      showLabel: showLabel,
    );
  }
}

int _resolveCount(WorkbenchBadgeKind kind, WidgetRef ref) {
  switch (kind) {
    case WorkbenchBadgeKind.visitorHost:
      return ref.watch(visitorHostPendingCountProvider);
    case WorkbenchBadgeKind.visitorApproval:
      return ref.watch(visitorPendingCountProvider);
    case WorkbenchBadgeKind.hrReview:
      return ref.watch(pendingReviewCountProvider);
    case WorkbenchBadgeKind.hrTask:
      return ref.watch(hrTaskCountProvider);
    case WorkbenchBadgeKind.production:
      return ref.watch(productionPendingCountProvider).count;
    case WorkbenchBadgeKind.rdTask:
      return ref.watch(rdTaskCountProvider);
    case WorkbenchBadgeKind.purchase:
      return ref.watch(purchaseTaskCountProvider);
    case WorkbenchBadgeKind.warehouse:
      return _sum(ref, [
        warehouseInboundExpectationCountProvider,
        warehouseArrivalExceptionCountProvider,
      ]);
    case WorkbenchBadgeKind.finance:
      return _sum(ref, [
        financeProcurementApprovalCountProvider,
        salesOrderFinanceConfirmationCountProvider,
        financeArrivalExceptionCountProvider,
      ]);
    case WorkbenchBadgeKind.subcontract:
      // 委外对齐采购：卡片徽标 = 委外任务台待办数（非到货退回数）。
      return ref.watch(subcontractTaskCountProvider);
    case WorkbenchBadgeKind.sales:
      return ref.watch(salesCompletionCountProvider).valueOrNull ?? 0;
    case WorkbenchBadgeKind.qualityInspection:
      return ref.watch(procurementInspectionPendingCountProvider).valueOrNull ??
          0;
    case WorkbenchBadgeKind.none:
      return 0;
  }
}

int _sum(WidgetRef ref, List<ProviderListenable<AsyncValue<int>>> providers) {
  var total = 0;
  for (final provider in providers) {
    total += ref
        .watch(provider)
        .when(data: (value) => value, error: (_, _) => 0, loading: () => 0);
  }
  return total;
}
