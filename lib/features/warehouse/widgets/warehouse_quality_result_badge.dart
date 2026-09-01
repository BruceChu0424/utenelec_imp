import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/warehouse_quality_result_count_provider.dart';

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
    final count = ref.watch(warehouseQualityResultPendingCountProvider);
    return count.when(
      data: (value) =>
          UtenNotificationBadge(count: value, size: size, showLabel: showLabel),
      loading: () => const SizedBox.shrink(),
      error: (_, _) => Tooltip(
        message: '品质检查结果待办数量加载失败，请进入任务页重试',
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('warehouse-quality-result-badge-error'),
          size: size,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: '品质检查结果待办数量加载失败，请进入任务页重试',
        ),
      ),
    );
  }
}
