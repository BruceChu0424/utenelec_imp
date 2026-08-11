import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../providers/procurement_inbound_count_providers.dart';

class WarehouseInboundExpectationBadge extends ConsumerWidget {
  const WarehouseInboundExpectationBadge({
    super.key,
    this.size = 16,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(warehouseInboundExpectationCountProvider)
        .valueOrNull;
    return UtenNotificationBadge(
      count: count ?? 0,
      size: size,
      showLabel: showLabel,
    );
  }
}

class WarehouseArrivalExceptionBadge extends ConsumerWidget {
  const WarehouseArrivalExceptionBadge({
    super.key,
    this.size = 16,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(warehouseArrivalExceptionCountProvider).valueOrNull;
    return UtenNotificationBadge(
      count: count ?? 0,
      size: size,
      showLabel: showLabel,
    );
  }
}

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
    final count = ref.watch(financeArrivalExceptionCountProvider).valueOrNull;
    return UtenNotificationBadge(
      count: count ?? 0,
      size: size,
      showLabel: showLabel,
    );
  }
}

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
    final count = ref
        .watch(procurementArrivalReturnCountProvider(orderType))
        .valueOrNull;
    return UtenNotificationBadge(
      count: count ?? 0,
      size: size,
      showLabel: showLabel,
    );
  }
}
