// 采购任务中心待办任务数量红色徽章（工作台「采购管理」卡片用）。
// 数据源 = 徽章汇总的 purchaseTaskCenter 入口红数(ADR-108，原端点
// /operations/workbench/purchase/count 同一口径：待分解 + 财务驳回)；count<=0 时不渲染。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/badge_registry.dart';

class PurchaseTaskBadge extends ConsumerWidget {
  const PurchaseTaskBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      badgeEntryTodoProvider(BadgeEntry.purchaseTaskCenter),
    );
    return UtenNotificationBadge(
      count: count,
      size: size,
      showLabel: showLabel,
    );
  }
}
