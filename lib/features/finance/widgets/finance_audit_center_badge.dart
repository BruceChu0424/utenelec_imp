import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/badge_registry.dart';

/// 「业务审核中心」卡角标 = 全部审核队列待办(徽章入口 financeAuditCenter)。
///
/// 数字由服务端徽章目录一次算好(ADR-108): 「订单修改确认」是「销售订单确认」同一批
/// 单据的队列切片, 总数只计一次; 无权看的队列不计。与本模块顶栏 UtenModuleTodoChip
/// 的差值即财务报销待办与 5 类单据草稿。
class FinanceAuditCenterBadge extends ConsumerWidget {
  const FinanceAuditCenterBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      badgeEntryTodoProvider(BadgeEntry.financeAuditCenter),
    );
    return Semantics(
      label: count > 0 ? '待我审核共 $count 笔' : '没有待审核任务',
      child: UtenNotificationBadge(count: count, size: size),
    );
  }
}
