import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../core/theme/uten_tokens.dart';
import 'quality_inspection_pending_badge.dart';
import '../../../shared/badges/badge_registry.dart';

/// 工作台卡片通过枚举声明显示位置，由共享组件按徽章汇总取数和渲染。
///
/// 一个种类同时决定**两个**数字：红色待办与黄色进行中。每个种类要么对应一个徽章入口，
/// 要么对应一个容器(模块卡 = 该容器全部入口之和); 两个数都由服务端徽章目录算好
/// (ADR-108), 这里只做「卡片 → 入口/容器」的映射。
enum WorkbenchBadgeKind {
  expenseMine,
  visitorHost, // 我的访客(被访人待确认 / 在办)
  visitorApproval, // 访客审批(HR 待审批 / 已批准待来访)
  hrReview, // 信息变更审核
  hrTask, // HR 任务中心（今日转正/逾期转正/今日生日/今日周年）
  production, // 生产管理(待排产 + 生产草稿 / 进行中批次)
  productionWorkshop, // 我的车间任务(红=等待物料；黄=生产中)
  rdTask, // 任务中心
  warehouse, // 仓库管理(三张任务中心 + 品质结果 + 仓库草稿)
  purchase, // 采购管理
  finance, // 钱流管理
  subcontract, // 委外管理
  sales, // 销售管理
  qualityInspection, // 品质任务中心（IQC 待检收货单 + FQC 待检行）
  serverStatus, // 服务器状态(越过警告或危急阈值的告警条数)
  none, // 暂无角标数据源（预留：以后接入时新增枚举值）
}

/// 卡片种类 → 汇总里的红黄两个数。
///
/// 模块卡取整个容器: 采购/委外/仓库/钱流/销售/品质在工作台上只有一张卡, 生产管理卡与
/// 车间任务卡分属 production / workshop 两个容器(两张卡各计各的, 不双计)。
/// 钱流、品质、HR、服务器状态没有「在办」态, 黄数恒 0(服务端目录里就没有黄的来源)。
BadgeCounts workbenchBadgeCounts(
  WorkbenchBadgeKind kind,
  BadgeSummary summary,
) {
  BadgeCounts entry(BadgeEntry value) =>
      BadgeCounts(summary.entryTodo(value), summary.entryInProgress(value));
  BadgeCounts module(BadgeModule value) =>
      BadgeCounts(summary.moduleTodo(value), summary.moduleInProgress(value));
  return switch (kind) {
    WorkbenchBadgeKind.expenseMine => entry(BadgeEntry.expenseMine),
    WorkbenchBadgeKind.visitorHost => entry(BadgeEntry.visitorHost),
    WorkbenchBadgeKind.visitorApproval => entry(BadgeEntry.visitorApproval),
    WorkbenchBadgeKind.hrReview => entry(BadgeEntry.hrProfileReview),
    WorkbenchBadgeKind.hrTask => entry(BadgeEntry.hrTaskCenter),
    WorkbenchBadgeKind.production => module(BadgeModule.production),
    WorkbenchBadgeKind.productionWorkshop => module(BadgeModule.workshop),
    WorkbenchBadgeKind.rdTask => entry(BadgeEntry.rdTaskCenter),
    WorkbenchBadgeKind.warehouse => module(BadgeModule.warehouse),
    WorkbenchBadgeKind.purchase => module(BadgeModule.purchase),
    WorkbenchBadgeKind.finance => module(BadgeModule.finance),
    WorkbenchBadgeKind.subcontract => module(BadgeModule.subcontract),
    WorkbenchBadgeKind.sales => module(BadgeModule.sales),
    WorkbenchBadgeKind.qualityInspection => module(BadgeModule.quality),
    WorkbenchBadgeKind.serverStatus => entry(BadgeEntry.serverStatusAlert),
    WorkbenchBadgeKind.none => BadgeCounts.zero,
  };
}

/// 工作台卡片角标：**黄(进行中) 在左、红(待办) 在右**，应放在 [UtenLazyMount] 内，
/// 避免首帧就订阅汇总。
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
    final counts = ref.watch(
      badgeSummaryProvider.select((s) => workbenchBadgeCounts(kind, s)),
    );
    // 品质任务中心的红数字有自己的组件(某一类待检没算出时显示异常图标)；
    // 黄色那枚照常并排。
    final todo = kind == WorkbenchBadgeKind.qualityInspection
        ? QualityInspectionPendingBadge(size: size, showLabel: showLabel)
        : UtenNotificationBadge(
            count: counts.todo,
            size: size,
            showLabel: showLabel,
          );
    return _BadgePair(
      inProgress: UtenInProgressBadge(
        count: counts.inProgress,
        size: size,
        showLabel: showLabel,
      ),
      todo: todo,
    );
  }
}

/// 汇总组内全部模块角标(黄左红右)；应放在 [UtenLazyMount] 内延后取数。
///
/// 组是用户自己在工作台上摆的卡片集合(布局偏好), 不是业务容器, 服务端不知道
/// 它的成员; 这里把组内各卡的汇总数相加是纯展示层合计, 口径仍全在服务端。
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
    final counts = ref.watch(
      badgeSummaryProvider.select((s) {
        var total = BadgeCounts.zero;
        for (final kind in kinds) {
          final one = workbenchBadgeCounts(kind, s);
          total = BadgeCounts(
            total.todo + one.todo,
            total.inProgress + one.inProgress,
          );
        }
        return total;
      }),
    );
    final inProgress = UtenInProgressBadge(
      count: counts.inProgress,
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
    return _BadgePair(
      inProgress: inProgress,
      todo: UtenNotificationBadge(
        count: counts.todo,
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
