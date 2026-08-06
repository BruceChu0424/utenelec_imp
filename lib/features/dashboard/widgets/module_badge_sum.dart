import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/auth/pending_review_provider.dart';
import '../../finance/providers/finance_procurement_approval_count_provider.dart';
import '../../hr_task/providers/hr_task_count_provider.dart';
import '../../production/providers/production_pending_provider.dart';
import '../../purchase/providers/purchase_task_count_provider.dart';
import '../../rd_task/providers/rd_task_count_provider.dart';
import '../../subcontract/providers/subcontract_task_count_provider.dart';
import '../../visitor_approval/providers/visitor_pending_count_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../sales/providers/sales_completion_count_provider.dart';

/// 工作台模块卡片角标种类。每张工作台卡片声明一种（[WorkbenchBadgeKind.none] = 无角标），
/// 由 [WorkbenchCardBadge] 统一渲染成**同一款红色数字药丸**——样式天然一致。
///
/// 设计原因：工作台卡片列表 `_allGroups` 是 const，provider 引用是运行时 final 变量、
/// 不能进 const 字面量；而枚举值是 const。故用「枚举值挂在卡片上 + 统一组件按枚举取数」
/// 的方式，既保 const 又集中渲染。后续给新模块接角标，只需新增一个枚举值并在
/// [_resolveCount] 接上对应 provider。
enum WorkbenchBadgeKind {
  visitorHost, // 我的访客（被访人待确认）
  visitorApproval, // 访客审批（HR 待审批）
  hrReview, // 信息变更审核
  hrTask, // HR 任务中心（今日转正/逾期转正/今日生日/今日周年）
  production, // 生产管理（待排产）
  rdTask, // 任务中心
  warehouse, // 仓库管理（预计到货 + 到货异常）
  purchase, // 采购管理（待分解 + 待采购完成）
  finance, // 钱流管理（订货审批 + 超量到货审批）
  subcontract, // 委外管理（待退回供应商）
  sales, // 销售管理（订单完工提醒）
  none, // 暂无角标数据源（预留：以后接入时新增枚举值）
}

/// 工作台卡片统一角标：红色数字药丸（count<=0 自动不显示）。
///
/// 应放在 [UtenLazyMount] 内使用——首帧不 watch 计数 provider、不发请求/启动轮询，
/// 首帧绘制后再并行拉取（见 workbench_module_area.dart 的 _ModuleTile）。
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

/// 分组标题综合徽标：组内所有模块角标之和（count<=0 自动不显示）。
/// 应放在 [UtenLazyMount] 内使用——与 [WorkbenchCardBadge] 一致，首帧不 watch
/// 计数 provider，首帧绘制后再并行拉取（见 workbench_module_area.dart 的 _buildSection）。
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
        financeArrivalExceptionCountProvider,
      ]);
    case WorkbenchBadgeKind.subcontract:
      // 委外对齐采购：卡片徽标 = 委外任务台待办数（非到货退回数）。
      return ref.watch(subcontractTaskCountProvider);
    case WorkbenchBadgeKind.sales:
      return ref.watch(salesCompletionCountProvider).valueOrNull ?? 0;
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
