import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/badge_registry.dart';

/// 品质部检查结果卡的红徽章: 轮到仓库动手的任务数(徽章入口, 随汇总带回)。
class WarehouseQualityResultBadge extends ConsumerWidget {
  const WarehouseQualityResultBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const entry = BadgeEntry.warehouseQualityResult;
    final state = ref.watch(
      badgeSummaryProvider.select(
        (s) => (s.loaded, s.isStale(entry), s.entryTodo(entry)),
      ),
    );
    if (!state.$1) return const SizedBox.shrink();
    if (state.$2) {
      return Tooltip(
        message: '品质检查结果待办数量加载失败，请进入任务页重试',
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('warehouse-quality-result-badge-error'),
          size: size,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: '品质检查结果待办数量加载失败，请进入任务页重试',
        ),
      );
    }
    return UtenNotificationBadge(
      count: state.$3,
      size: size,
      showLabel: showLabel,
    );
  }
}
