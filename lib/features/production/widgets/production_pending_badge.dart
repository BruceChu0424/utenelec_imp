// 生产部待排产数量红色徽章（生产 hub「生产任务中心」卡片用）。
// 数据源 productionPendingCountProvider（随工作台徽章汇总带回），
// count<=0 时不渲染，数字样式复用 UtenNotificationBadge。
//
// overdue>0 时在主徽章左侧追加「逾期 N」描边小标（深红文字），
// 悬浮提示展示完整拆分：待排产 / 紧急 / 已逾期 / 草稿。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../providers/production_pending_provider.dart';

class ProductionPendingBadge extends ConsumerWidget {
  const ProductionPendingBadge({
    super.key,
    this.size = 16,
    this.showLabel = false,
    this.includeProductionDrafts = false,
  });

  final double size;
  final bool showLabel;

  /// 把生产草稿（计划 draft + 日报 status=0，含本地表单草稿投影）并入红数
  /// （2026-09-26 全站草稿口径：hub 任务中心卡红数里的每张草稿都要能在
  /// 「生产任务中心 → 草稿」段看到行——红数与下钻落点同源同数）。
  final bool includeProductionDrafts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(productionPendingCountProvider);
    final drafts = includeProductionDrafts
        ? ref.watch(draftCountsProvider).sumOf(const [
            DraftDocKind.productionPlan,
            DraftDocKind.productionDailyReport,
          ])
        : 0;
    if (c.count + drafts <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Tooltip(
      message:
          '待排产 ${c.count} 行 · 紧急 ${c.urgent} · 已逾期 ${c.overdue}'
          '${drafts > 0 ? ' · 草稿 $drafts' : ''}',
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
            count: c.count + drafts,
            size: size,
            showLabel: showLabel,
          ),
        ],
      ),
    );
  }
}
