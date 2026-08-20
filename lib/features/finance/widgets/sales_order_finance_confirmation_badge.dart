import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';

/// 销售订货单待财务确认徽标（V294 闸门）。
class SalesOrderFinanceConfirmationBadge extends ConsumerWidget {
  const SalesOrderFinanceConfirmationBadge({
    super.key,
    this.size = 20,
    this.showLabel = true,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(salesOrderFinanceConfirmationCountProvider)
        .when(data: (value) => value, error: (_, _) => 0, loading: () => 0);
    return Semantics(
      label: count > 0 ? '待财务确认 $count 张销售订货单' : '没有待确认销售订货单',
      child: UtenNotificationBadge(
        count: count,
        size: size,
        showLabel: showLabel,
      ),
    );
  }
}
