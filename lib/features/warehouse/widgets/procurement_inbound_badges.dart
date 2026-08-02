import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../providers/procurement_inbound_count_providers.dart';

class WarehouseInboundExpectationBadge extends ConsumerWidget {
  const WarehouseInboundExpectationBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(warehouseInboundExpectationCountProvider)
        .valueOrNull;
    return UtenNotificationBadge(count: count ?? 0);
  }
}

class WarehouseArrivalExceptionBadge extends ConsumerWidget {
  const WarehouseArrivalExceptionBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(warehouseArrivalExceptionCountProvider).valueOrNull;
    return UtenNotificationBadge(count: count ?? 0);
  }
}

class FinanceArrivalExceptionBadge extends ConsumerWidget {
  const FinanceArrivalExceptionBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(financeArrivalExceptionCountProvider).valueOrNull;
    return UtenNotificationBadge(count: count ?? 0);
  }
}

class ProcurementArrivalReturnBadge extends ConsumerWidget {
  const ProcurementArrivalReturnBadge({super.key, required this.orderType});

  final ProcurementInboundOrderType orderType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(procurementArrivalReturnCountProvider(orderType))
        .valueOrNull;
    return UtenNotificationBadge(count: count ?? 0);
  }
}
