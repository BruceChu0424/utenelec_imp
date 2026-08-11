// 销售订单「完工提醒」红色数字徽章（销售 hub「订单进度查询」卡用）。
// 数据源 salesCompletionCountProvider（未读完工通知数）；count<=0 不渲染。
// 范式同 ProductionPendingBadge。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/sales_completion_count_provider.dart';

class SalesProgressBadge extends ConsumerWidget {
  const SalesProgressBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(salesCompletionCountProvider).valueOrNull ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    return Tooltip(
      message: '完工提醒 $count 条未读',
      child: UtenNotificationBadge(
        count: count,
        size: size,
        showLabel: showLabel,
      ),
    );
  }
}
