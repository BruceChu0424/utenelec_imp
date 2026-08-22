import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/procurement_inbound_count_providers.dart';

/// IQC 待检收货单角标。
///
/// 正数显示、零隐藏；请求失败时显示可辨识的异常图标，避免把“未知”静默伪装成
/// 真实零待办。权限短路与 60 秒轮询由计数 provider 统一负责。
class ProcurementInspectionPendingBadge extends ConsumerWidget {
  const ProcurementInspectionPendingBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(procurementInspectionPendingCountProvider);
    return count.when(
      data: (value) =>
          UtenNotificationBadge(count: value, size: size, showLabel: showLabel),
      loading: () => const SizedBox.shrink(),
      error: (_, _) => Tooltip(
        message: '待检数量加载失败，请进入待检处置后重试',
        child: Icon(
          Icons.sync_problem_outlined,
          key: const ValueKey('procurement-inspection-badge-error'),
          size: size,
          color: Theme.of(context).colorScheme.error,
          semanticLabel: '待检数量加载失败，请进入待检处置后重试',
        ),
      ),
    );
  }
}
