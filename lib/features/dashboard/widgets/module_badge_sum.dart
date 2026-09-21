import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/badges/in_progress_badge_registry.dart';
import '../../../shared/badges/todo_badge_registry.dart';
import 'quality_inspection_pending_badge.dart';

/// 工作台卡片通过枚举声明数据源，由共享组件统一取数和渲染。
///
/// 一个种类同时决定**两个**数字：红色待办([_resolveCount] → todo_badge_registry)
/// 与黄色进行中([_resolveInProgressCount] → in_progress_badge_registry)。
/// 下面注释里写的是红色那一份；黄色那一份见 [_resolveInProgressCount]。
enum WorkbenchBadgeKind {
  expenseMine,
  visitorHost, // 我的访客（被访人待确认）
  visitorApproval, // 访客审批（HR 待审批）
  hrReview, // 信息变更审核
  hrTask, // HR 任务中心（今日转正/逾期转正/今日生日/今日周年）
  production, // 生产管理（待排产）
  productionWorkshop, // 我的车间任务(红=等待物料；黄=生产中。ADR-100 起红不再含生产中)
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
  //（历史/报表）按口径不进累加，待提交草稿沿注册表计入待办。
  (ref) => ref.watch(todoTotalCountProvider),
);

/// 导航「工作台」Tab 的**黄色**总数：全部模块卡「进行中」之和。
///
/// 与红色那枚同构、同源、同降级规则，只是读另一张注册表
/// (lib/shared/badges/in_progress_badge_registry.dart)。两条链互不相干：
/// 红回答「我还欠多少活」，黄回答「我手上还有多少在跑」(ADR-100)。
final workbenchTotalInProgressCountProvider = Provider<int>(
  (ref) => ref.watch(inProgressTotalCountProvider),
);

/// 工作台卡片角标：**黄(进行中) 在左、红(待办) 在右**，应放在 [UtenLazyMount] 内，
/// 避免首帧启动计数请求。
///
/// 两枚都是 count<=0 自己返回 SizedBox.shrink，所以只有一枚有数时另一枚不占宽，
/// 中间的间距也跟着塌掉——单徽章的卡不会被顶偏。
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
    // 品质任务中心的红数字有自己的权限分支组件(IQC/FQC 分别按权限计)，
    // 不能换成裸 UtenNotificationBadge；黄色那枚照常并排。
    final todo = kind == WorkbenchBadgeKind.qualityInspection
        ? QualityInspectionPendingBadge(size: size, showLabel: showLabel)
        : UtenNotificationBadge(
            count: _resolveCount(kind, ref.watch),
            size: size,
            showLabel: showLabel,
          );
    return _BadgePair(
      inProgress: UtenInProgressBadge(
        count: _resolveInProgressCount(kind, ref.watch),
        size: size,
        showLabel: showLabel,
      ),
      todo: todo,
    );
  }
}

/// 汇总组内全部模块角标(黄左红右)；应放在 [UtenLazyMount] 内延后取数。
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
    var inProgressTotal = 0;
    for (final kind in kinds) {
      inProgressTotal += _resolveInProgressCount(kind, ref.watch);
    }
    final inProgress = UtenInProgressBadge(
      count: inProgressTotal,
      size: size,
      showLabel: showLabel,
    );
    if (kinds.length == 1 &&
        kinds.single == WorkbenchBadgeKind.qualityInspection) {
      return _BadgePair(
        inProgress: inProgress,
        todo: QualityInspectionPendingBadge(size: size, showLabel: showLabel),
      );
    }
    var total = 0;
    for (final kind in kinds) {
      total += _resolveCount(kind, ref.watch);
    }
    return _BadgePair(
      inProgress: inProgress,
      todo: UtenNotificationBadge(
        count: total,
        size: size,
        showLabel: showLabel,
      ),
    );
  }
}

/// 「黄左红右」的并排容器(hub 卡右上角同款顺序，见 UtenHubCard.progressBadge)。
class _BadgePair extends StatelessWidget {
  const _BadgePair({required this.inProgress, required this.todo});

  final Widget inProgress;
  final Widget todo;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        inProgress,
        const SizedBox(width: UtenSpacing.s4),
        todo,
      ],
    );
  }
}

/// 卡片种类 → 黄色「进行中」数；映射登记在 in_progress_badge_registry。
///
/// 返回 0 = 该卡按 ADR-100 刻意不挂黄色(报表/主档/纯动作入口，或它的在途量
/// 已由同模块另一张卡计过一次，再数一遍就是链内双计)。
int _resolveInProgressCount(
  WorkbenchBadgeKind kind,
  T Function<T>(ProviderListenable<T> listenable) watch,
) {
  switch (kind) {
    case WorkbenchBadgeKind.expenseMine:
      return inProgressEntryCount(InProgressEntry.expenseMineProcessing, watch);
    case WorkbenchBadgeKind.visitorHost:
      return inProgressEntryCount(InProgressEntry.visitorHostOngoing, watch);
    case WorkbenchBadgeKind.visitorApproval:
      return inProgressEntryCount(
        InProgressEntry.visitorApprovalOngoing,
        watch,
      );
    // 「生产管理」卡 = 进行中的分析/根计划批次；车间任务在工作台另有一张卡，
    // 算进来就成了「批次 + 它名下的工单段」重复喊一遍。
    case WorkbenchBadgeKind.production:
      return inProgressEntryCount(InProgressEntry.productionBatches, watch);
    case WorkbenchBadgeKind.productionWorkshop:
      return inProgressEntryCount(InProgressEntry.productionWorkshop, watch);
    case WorkbenchBadgeKind.rdTask:
      return inProgressEntryCount(InProgressEntry.rdTaskCenter, watch);
    // 下面几个模块在工作台只有一张卡 → 取整模块累计(规矩同红色那条链)。
    case WorkbenchBadgeKind.warehouse:
      return inProgressModuleCount(BadgeModule.warehouse, watch);
    case WorkbenchBadgeKind.purchase:
      return inProgressModuleCount(BadgeModule.purchase, watch);
    case WorkbenchBadgeKind.subcontract:
      return inProgressModuleCount(BadgeModule.subcontract, watch);
    case WorkbenchBadgeKind.sales:
      return inProgressModuleCount(BadgeModule.sales, watch);
    // 以下刻意恒 0，理由见 in_progress_badge_registry 末尾「已知重叠」：
    //  · 钱流：球一旦离开财务就落在采购/仓库/销售那几张卡上，这里再数是跨卡双计；
    //  · 品质任务中心：IQC/FQC 只有待检与已出结论两档，没有在办态；
    //  · HR 任务中心/信息变更审核：今日到期事项与纯审批队列，同样没有在办态；
    //  · 服务器状态：告警只有「还在报」与「已恢复」，不是流程。
    case WorkbenchBadgeKind.finance:
    case WorkbenchBadgeKind.qualityInspection:
    case WorkbenchBadgeKind.hrReview:
    case WorkbenchBadgeKind.hrTask:
    case WorkbenchBadgeKind.serverStatus:
    case WorkbenchBadgeKind.none:
      return 0;
  }
}

int _resolveCount(
  WorkbenchBadgeKind kind,
  T Function<T>(ProviderListenable<T> listenable) watch,
) {
  // 计数源与累加口径统一登记在 todo_badge_registry；本函数只做
  // WorkbenchBadgeKind → 注册表入口/模块的映射。
  switch (kind) {
    case WorkbenchBadgeKind.expenseMine:
      return todoEntryCount(TodoEntry.expenseMine, watch);
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
      return todoModuleCount(BadgeModule.sales, watch);
    // 模块卡 = 该模块全部待办入口之和（采购/委外新含「待退回供应商」，
    // 钱流新含 IQC 驳回——此前这些入口在 hub 里有徽章却不进模块卡）。
    case WorkbenchBadgeKind.warehouse:
      return todoModuleCount(BadgeModule.warehouse, watch);
    case WorkbenchBadgeKind.finance:
      return todoModuleCount(BadgeModule.finance, watch);
    case WorkbenchBadgeKind.purchase:
      return todoModuleCount(BadgeModule.purchase, watch);
    case WorkbenchBadgeKind.subcontract:
      return todoModuleCount(BadgeModule.subcontract, watch);
    case WorkbenchBadgeKind.qualityInspection:
      return todoModuleCount(BadgeModule.quality, watch);
    // 系统管理「服务器状态」卡：当前告警条数（磁盘/内存/数据库/备份越线）。
    case WorkbenchBadgeKind.serverStatus:
      return todoEntryCount(TodoEntry.serverStatusAlert, watch);
    case WorkbenchBadgeKind.none:
      return 0;
  }
}
