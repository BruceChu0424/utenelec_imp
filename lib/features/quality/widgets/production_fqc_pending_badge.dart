import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';

class ProductionFqcPendingBadge extends ConsumerWidget {
  const ProductionFqcPendingBadge({
    super.key,
    this.size = 20,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(productionFqcPendingCountProvider).valueOrNull ?? 0;
    return UtenNotificationBadge(
      count: count,
      size: size,
      showLabel: showLabel,
    );
  }
}
