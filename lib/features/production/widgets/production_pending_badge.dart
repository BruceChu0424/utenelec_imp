// 生产部待排产数量红色徽章（工作台「生产管理」卡片 / 生产 hub「生产调度」卡片用）。
// 数据源 productionPendingCountProvider（60s 轮询 /production/schedule/pending-count），
// count<=0 时不渲染。范式同 HrPendingBadge。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/production_pending_provider.dart';

class ProductionPendingBadge extends ConsumerWidget {
  const ProductionPendingBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(productionPendingCountProvider).count;
    return UtenNotificationBadge(
      count: count,
      size: size,
      showLabel: showLabel,
    );
  }
}
