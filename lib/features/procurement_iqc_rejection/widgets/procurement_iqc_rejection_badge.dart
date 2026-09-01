import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../repositories/procurement_iqc_rejection_repository.dart';

class ProcurementIqcRejectionBadge extends ConsumerWidget {
  const ProcurementIqcRejectionBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(procurementIqcRejectionOpenCountProvider);
    return count.when(
      data: (value) =>
          UtenNotificationBadge(count: value, size: size, showLabel: showLabel),
      loading: () => const SizedBox.shrink(),
      error: (_, _) => Tooltip(
        message: 'IQC 不合格任务数量加载失败，请进入任务页重试',
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('iqc-rejection-badge-error'),
          size: size,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: 'IQC 不合格任务数量加载失败',
        ),
      ),
    );
  }
}
