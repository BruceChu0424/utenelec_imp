import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/production_finished_inbound_task_count_provider.dart';

class WarehouseProductionFinishedInboundPendingBadge extends ConsumerWidget {
  const WarehouseProductionFinishedInboundPendingBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(warehouseProductionFinishedInboundPendingCountProvider)
        .valueOrNull;
    return UtenNotificationBadge(
      count: count ?? 0,
      size: size,
      showLabel: showLabel,
    );
  }
}
