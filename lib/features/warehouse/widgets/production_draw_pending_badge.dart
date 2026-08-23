import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/production_draw_count_provider.dart';

class WarehouseProductionDrawPendingBadge extends ConsumerWidget {
  const WarehouseProductionDrawPendingBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref
        .watch(warehouseProductionDrawPendingCountProvider)
        .valueOrNull;
    return UtenNotificationBadge(
      count: count ?? 0,
      size: size,
      showLabel: showLabel,
    );
  }
}
