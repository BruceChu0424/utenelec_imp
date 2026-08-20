import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';

/// 委外出仓任务角标（V304）：待出仓的发料计划数（OPEN 且有剩余量）。
class WarehouseSubcontractOutboundBadge extends ConsumerWidget {
  const WarehouseSubcontractOutboundBadge({
    super.key,
    this.size = 16,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(warehouseSubcontractOutboundCountProvider)
        .valueOrNull;
    return UtenNotificationBadge(
      count: count ?? 0,
      size: size,
      showLabel: showLabel,
    );
  }
}
