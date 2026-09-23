// 仓库三张任务中心卡的角标(红色圆数字徽章，与工作台/品质任务中心同款)。
//
// 每张卡一个徽章入口，数字由服务端徽章目录按卡内各来源一次算好(ADR-108)，
// 这里只按入口取数、不做加法：
// - 汇总还没到过时不展示(不把「未知」伪装成真实 0)；
// - 该入口本次有来源没算出(服务端标 stale)时显示可辨识的异常图标。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/badge_registry.dart';

/// 出库任务中心角标 = 销售出库待办 + 委外出仓待办（草稿不计入待办数）。
///
/// 委外「等子件到货」的任务(ADR-103 黄枚)只画在出库任务中心的分段上, 不进本卡:
/// 那些委外单已在委外任务中心的 IN_PROGRESS 黄数里, 仓库卡再数一遍是跨卡双计。
class WarehouseOutboundTaskBadge extends ConsumerWidget {
  const WarehouseOutboundTaskBadge({super.key, this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _EntryBadge(
    entry: BadgeEntry.warehouseOutboundCenter,
    errorMessage: '出库待办数量加载失败，请进入出库任务中心后重试',
    showLabel: showLabel,
  );
}

/// 入库任务中心角标 = 预计到货 + 到货异常 + 产成品待点收（草稿不计入）。
class WarehouseInboundTaskBadge extends ConsumerWidget {
  const WarehouseInboundTaskBadge({super.key, this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _EntryBadge(
    entry: BadgeEntry.warehouseInboundCenter,
    errorMessage: '入库待办数量加载失败，请进入入库任务中心后重试',
    showLabel: showLabel,
  );
}

/// 生产领料任务中心角标 = 履约待领(DRAW 剩余可领)任务 + 待确认实收的退料(草稿不计入)。
class WarehouseDrawTaskBadge extends ConsumerWidget {
  const WarehouseDrawTaskBadge({super.key, this.showLabel = false});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _EntryBadge(
    entry: BadgeEntry.warehouseDrawCenter,
    errorMessage: '领退料待办数量加载失败，请进入生产领料任务中心后重试',
    showLabel: showLabel,
  );
}

class _EntryBadge extends ConsumerWidget {
  const _EntryBadge({
    required this.entry,
    required this.errorMessage,
    required this.showLabel,
  });

  final BadgeEntry entry;
  final String errorMessage;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      badgeSummaryProvider.select(
        (s) => (s.loaded, s.isStale(entry), s.entryTodo(entry)),
      ),
    );
    if (!state.$1) return const SizedBox.shrink();
    if (state.$2) {
      return Tooltip(
        message: errorMessage,
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('warehouse-task-badge-error'),
          size: 20,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: errorMessage,
        ),
      );
    }
    return UtenNotificationBadge(count: state.$3, showLabel: showLabel);
  }
}
