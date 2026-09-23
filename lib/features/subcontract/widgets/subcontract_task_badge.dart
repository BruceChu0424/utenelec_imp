// 委外任务中心待办任务数量徽章（委外 hub「委外任务中心」卡片用）。
// 数据源 = 徽章汇总的 subcontractTaskCenter 入口红数(ADR-108，原端点
// /operations/workbench/subcontract/count 同一口径)，
// 口径 = 委外任务台 open_qty>0 行（待分解 + 待采购完成 + 财务驳回）；count<=0 时不渲染。
// 范式对齐 lib/features/purchase/widgets/purchase_task_badge.dart。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/badge_registry.dart';

class SubcontractTaskBadge extends ConsumerWidget {
  const SubcontractTaskBadge({
    super.key,
    this.size = 16,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      badgeEntryTodoProvider(BadgeEntry.subcontractTaskCenter),
    );
    return UtenNotificationBadge(
      count: count,
      size: size,
      showLabel: showLabel,
    );
  }
}
