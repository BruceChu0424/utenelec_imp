import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/finance_procurement_approval_count_provider.dart';

class FinanceProcurementApprovalBadge extends ConsumerWidget {
  const FinanceProcurementApprovalBadge({
    super.key,
    this.size = 20,
    this.showLabel = true,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(financeProcurementApprovalCountProvider)
        .when(data: (value) => value, error: (_, _) => 0, loading: () => 0);
    return Semantics(
      label: count > 0 ? '待我审核 $count 张订货单' : '没有待审核订货单',
      child: UtenNotificationBadge(
        count: count,
        size: size,
        showLabel: showLabel,
      ),
    );
  }
}
