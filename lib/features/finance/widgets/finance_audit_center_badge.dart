import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/badges/todo_badge_registry.dart';

/// 「业务审核中心」卡角标 = 五类审核队列待办之和。
///
/// 求和走 [sumTodoEntries]（注册表唯一累加实现）：「订单修改确认」是
/// 「销售订单确认」同一批单据的队列切片，总数只计一次；IQC 无权限不计。
/// 与本模块顶栏 UtenModuleTodoChip 的差值即 5 类单据草稿（口径见
/// shared/badges/todo_badge_registry.dart）。
class FinanceAuditCenterBadge extends ConsumerWidget {
  const FinanceAuditCenterBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = sumTodoEntries(const [
      TodoEntry.financeSalesOrderConfirmation,
      TodoEntry.financeShipmentAudit,
      TodoEntry.financeProcurementApproval,
      TodoEntry.financeArrivalException,
      TodoEntry.financeIqcRejection,
    ], ref.watch);
    return Semantics(
      label: count > 0 ? '待我审核共 $count 笔' : '没有待审核任务',
      child: UtenNotificationBadge(count: count, size: size),
    );
  }
}
