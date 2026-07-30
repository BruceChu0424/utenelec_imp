// 生产部待排产数量红色徽章（工作台「生产管理」卡片 / 生产 hub「生产调度」卡片用）。
// 数据源 productionPendingCountProvider（60s 轮询 /production/schedule/pending-count），
// count<=0 时不渲染。范式同 HrPendingBadge。
//
// overdue>0 时在主徽章左侧追加「逾期 N」描边小标（深红文字），
// 悬浮提示展示完整拆分：待排产 / 紧急 / 已逾期。

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
    final c = ref.watch(productionPendingCountProvider);
    if (c.count <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Tooltip(
      message: '待排产 ${c.count} 行 · 紧急 ${c.urgent} · 已逾期 ${c.overdue}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.overdue > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: BoxConstraints(minHeight: size),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(size),
                border: Border.all(color: theme.colorScheme.error, width: 1.2),
              ),
              alignment: Alignment.center,
              child: Text(
                '逾期 ${c.overdue > 99 ? '99+' : c.overdue}',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          UtenNotificationBadge(
            count: c.count,
            size: size,
            showLabel: showLabel,
          ),
        ],
      ),
    );
  }
}
