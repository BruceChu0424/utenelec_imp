import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/badges/badge_registry.dart';

/// 超量到货财务审批待办数(业务审核中心页内分段), 随徽章汇总带回(ADR-108)。
class FinanceArrivalExceptionBadge extends ConsumerWidget {
  const FinanceArrivalExceptionBadge({
    super.key,
    this.size = 16,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return UtenNotificationBadge(
      count: ref.watch(badgeFactProvider(BadgeFact.financeArrivalException)),
      size: size,
      showLabel: showLabel,
    );
  }
}

/// 采购/委外「待退回供应商」卡的待办数(徽章入口, 随徽章汇总带回)。
class ProcurementArrivalReturnBadge extends ConsumerWidget {
  const ProcurementArrivalReturnBadge({
    super.key,
    required this.orderType,
    this.size = 16,
    this.showLabel = false,
  });

  final ProcurementInboundOrderType orderType;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = orderType == ProcurementInboundOrderType.subcontract
        ? BadgeEntry.subcontractSupplierReturn
        : BadgeEntry.purchaseSupplierReturn;
    return UtenNotificationBadge(
      count: ref.watch(badgeEntryTodoProvider(entry)),
      size: size,
      showLabel: showLabel,
    );
  }
}
