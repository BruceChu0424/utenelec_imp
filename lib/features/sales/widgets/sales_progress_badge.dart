// 销售订单关注事项红色数字徽章（销售 hub「订单进度查询」卡用）。
// 数据源 = 未解决财务驳回订单 + 未读完工通知；count<=0 不渲染。
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
    final count = ref.watch(salesAttentionCountProvider).valueOrNull ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    return Tooltip(
      message: '销售待关注 $count 项',
      child: UtenNotificationBadge(
        count: count,
        size: size,
        showLabel: showLabel,
      ),
    );
  }
}
