import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/badge_registry.dart';

/// 品质任务中心红徽章 = IQC 待检收货单 + FQC 待检行(品质容器, 服务端算好的和)。
///
/// 某一类本次没算出(服务端 staleEntries)时显示异常图标, 不把半截合计当真数;
/// 汇总还没到过时不展示。
class QualityInspectionPendingBadge extends ConsumerWidget {
  const QualityInspectionPendingBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      badgeSummaryProvider.select(
        (s) => (
          s.loaded,
          s.isStale(BadgeEntry.qualityIqcPending) ||
              s.isStale(BadgeEntry.qualityFqcPending),
          s.moduleTodo(BadgeModule.quality),
        ),
      ),
    );
    if (!state.$1) return const SizedBox.shrink();
    if (state.$2) {
      return Tooltip(
        message: '品质待检数量加载失败，请进入品质任务中心后重试',
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('procurement-inspection-badge-error'),
          size: size,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: '品质待检数量加载失败，请进入品质任务中心后重试',
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
