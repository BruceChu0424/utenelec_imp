import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/todo_badge_registry.dart';
import 'quality_inspection_pending_badge.dart';

/// 工作台卡片通过枚举声明数据源，由共享组件统一取数和渲染。
enum WorkbenchBadgeKind {
  visitorHost, // 我的访客（被访人待确认）
  visitorApproval, // 访客审批（HR 待审批）
  hrReview, // 信息变更审核
  hrTask, // HR 任务中心（今日转正/逾期转正/今日生日/今日周年）
  production, // 生产管理（待排产）
  productionWorkshop, // 我的车间任务（仅当前可行动执行段）
  rdTask, // 任务中心
  warehouse, // 仓库管理（三张任务中心卡角标之和：出库+入库+领料+品质结果）
  purchase, // 采购管理（待分解 + 待采购完成）
  finance, // 钱流管理（订货审批 + 销售订单财务确认 + 超量到货审批）
  subcontract, // 委外管理（待退回供应商）
  sales, // 销售管理（财务驳回待修正 + 订单完工提醒）
  qualityInspection, // 品质任务中心（IQC 待检收货单 + FQC 待检行）
  serverStatus, // 服务器状态（磁盘/内存/数据库/备份越过警告或危急阈值的条数）
  none, // 暂无角标数据源（预留：以后接入时新增枚举值）
}

/// 导航「工作台」Tab 角标：全部模块卡角标（按种类去重）之和。
///
/// 与卡片/分组徽标同源同口径（单个来源加载中/失败按 0 计，不放大成异常态，
/// 与通知 Tab 的未读角标同款红圆数字）。常驻 provider 被外壳导航 watch 后，
/// autoDispose 计数源随之保持存活，由 refreshGlobalBadges（返回工作台 /
/// 新通知到达）与各 60s 轮询 notifier 驱动更新。
final workbenchTotalTodoCountProvider = Provider<int>(
  // 2026-09-11：Tab 总数与各模块卡走同一张待办注册表（lib/shared/badges/
  // todo_badge_registry.dart），杜绝「外层写 1、内层合计 5」。浏览型计数
  //（草稿/历史/报表）按口径不进累加。
  (ref) => ref.watch(todoTotalCountProvider),
);

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
  // 计数源与累加口径统一登记在 todo_badge_registry；本函数只做
  // WorkbenchBadgeKind → 注册表入口/模块的映射。
  switch (kind) {
    case WorkbenchBadgeKind.visitorHost:
      return todoEntryCount(TodoEntry.visitorHostConfirm, watch);
    case WorkbenchBadgeKind.visitorApproval:
      return todoEntryCount(TodoEntry.visitorApproval, watch);
    case WorkbenchBadgeKind.hrReview:
      return todoEntryCount(TodoEntry.hrProfileReview, watch);
    case WorkbenchBadgeKind.hrTask:
      return todoEntryCount(TodoEntry.hrTaskCenter, watch);
    // 「生产管理」卡 = 生产模块入口之和**减去车间任务**（它在工作台另有一张
    // 「车间生产任务」卡，算进来就双计）。2026-09-11 起含生产草稿。
    case WorkbenchBadgeKind.production:
      return sumTodoEntries(const [
        TodoEntry.productionSchedule,
        TodoEntry.productionDrafts,
      ], watch);
    case WorkbenchBadgeKind.productionWorkshop:
      return todoEntryCount(TodoEntry.productionWorkshop, watch);
    case WorkbenchBadgeKind.rdTask:
      return todoEntryCount(TodoEntry.rdTaskCenter, watch);
    // 「销售管理」是销售模块在工作台的唯一一张卡，所以取整模块累计。
    // 2026-09-11 修：此前写死成单个入口 salesAttention，销售草稿因此
    // 永远进不了工作台——用户原话「工作台 销售管理没有显示」。
    case WorkbenchBadgeKind.sales:
      return todoModuleCount(TodoModule.sales, watch);
    // 模块卡 = 该模块全部待办入口之和（采购/委外新含「待退回供应商」，
    // 钱流新含 IQC 驳回——此前这些入口在 hub 里有徽章却不进模块卡）。
    case WorkbenchBadgeKind.warehouse:
      return todoModuleCount(TodoModule.warehouse, watch);
    case WorkbenchBadgeKind.finance:
      return todoModuleCount(TodoModule.finance, watch);
    case WorkbenchBadgeKind.purchase:
      return todoModuleCount(TodoModule.purchase, watch);
    case WorkbenchBadgeKind.subcontract:
      return todoModuleCount(TodoModule.subcontract, watch);
    case WorkbenchBadgeKind.qualityInspection:
      return todoModuleCount(TodoModule.quality, watch);
    // 系统管理「服务器状态」卡：当前告警条数（磁盘/内存/数据库/备份越线）。
    case WorkbenchBadgeKind.serverStatus:
      return todoEntryCount(TodoEntry.serverStatusAlert, watch);
    case WorkbenchBadgeKind.none:
      return 0;
  }
}
