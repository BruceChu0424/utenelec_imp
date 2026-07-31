// 采购任务中心待办任务数量红色徽章（工作台「采购管理」卡片用）。
// 数据源 purchaseTaskCountProvider（60s 轮询 /operations/workbench/purchase/count），
// 口径 = 采购任务中心未完成任务（UNPEGGED + WAITING_SUPPLY），与任务中心同源；count<=0 时不渲染。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/purchase_task_count_provider.dart';

class PurchaseTaskBadge extends ConsumerWidget {
  const PurchaseTaskBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(purchaseTaskCountProvider);
    return UtenNotificationBadge(
      count: count,
      size: size,
      showLabel: showLabel,
    );
  }
}
