import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/warehouse_iqc_stock_in_count_provider.dart';

class WarehouseIqcStockInBadge extends ConsumerWidget {
  const WarehouseIqcStockInBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(warehouseIqcStockInPendingCountProvider);
    return count.when(
      data: (value) =>
          UtenNotificationBadge(count: value, size: size, showLabel: showLabel),
      loading: () => const SizedBox.shrink(),
      error: (_, _) => Tooltip(
        message: 'IQC 待入库数量加载失败，请进入任务页重试',
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('warehouse-iqc-stock-in-badge-error'),
          size: size,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: 'IQC 待入库数量加载失败，请进入任务页重试',
        ),
      ),
    );
  }
}
