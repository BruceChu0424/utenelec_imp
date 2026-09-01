import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';

/// Combined IQC + production FQC badge without turning load failures into 0.
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
    final iqc = ref.watch(procurementInspectionPendingCountProvider);
    final fqc = ref.watch(productionFqcPendingCountProvider);
    if (iqc.hasError || fqc.hasError) {
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
    // 任一来源仍在加载时总数尚未收敛；不把另一个已返回值伪装成最终合计。
    if (iqc.isLoading || fqc.isLoading) {
      return const SizedBox.shrink();
    }
    return UtenNotificationBadge(
      count: (iqc.valueOrNull ?? 0) + (fqc.valueOrNull ?? 0),
      size: size,
      showLabel: showLabel,
    );
  }
}
