// PMC 缺料待备料数量红色徽章（工作台「采购管理」卡片用）。
// 数据源 pmcShortageCountProvider（60s 轮询 /production/schedule/shortage-count），
// 口径 = 计划已审但 BOM 净需求不足的订单行（chain_status=3 待物料），count<=0 时不渲染。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../production/providers/production_pending_provider.dart';

class PmcShortageBadge extends ConsumerWidget {
  const PmcShortageBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pmcShortageCountProvider);
    return UtenNotificationBadge(
      count: count,
      size: size,
      showLabel: showLabel,
    );
  }
}
