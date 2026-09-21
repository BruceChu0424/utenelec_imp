// ADR-098 委外回厂短交待判定数徽章（委外 hub「回厂短交判定」卡片用）。
// 数据源 subcontractShortDeliveryCountProvider.pending；count<=0 时不渲染。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/subcontract_short_delivery_count_provider.dart';

class SubcontractShortDeliveryBadge extends ConsumerWidget {
  const SubcontractShortDeliveryBadge({
    super.key,
    this.size = 16,
    this.showLabel = false,
  });

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(subcontractShortDeliveryCountProvider);
    return UtenNotificationBadge(
      count: counts.pending,
      size: size,
      showLabel: showLabel,
    );
  }
}
