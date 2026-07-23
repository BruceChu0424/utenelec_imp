// 异常告警页（Phase 5）
// 文档：docs/03-页面/异常告警页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/alert.dart';
import '../providers/analytics_providers.dart';

enum AlertFilter { pending, processing, resolved, all }

class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(alertStatusFilterProvider);
    final listAsync = ref.watch(alertListProvider);

    final seg = status == AlertStatus.processing
        ? AlertFilter.processing
        : status == AlertStatus.resolved
            ? AlertFilter.resolved
            : status == null
                ? AlertFilter.all
                : AlertFilter.pending;

    return Scaffold(
      appBar: const UtenAppBar(title: '异常告警', showBackButton: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: UtenSegmentedFilter<AlertFilter>(
              selected: seg,
              onChanged: (v) {
                ref.read(alertStatusFilterProvider.notifier).state = switch (v) {
                  AlertFilter.all => null,
                  AlertFilter.pending => AlertStatus.pending,
                  AlertFilter.processing => AlertStatus.processing,
                  AlertFilter.resolved => AlertStatus.resolved,
                };
              },
              segments: const [
                UtenSegment(value: AlertFilter.pending, label: '未处理'),
                UtenSegment(value: AlertFilter.processing, label: '处理中'),
                UtenSegment(value: AlertFilter.resolved, label: '已解决'),
                UtenSegment(value: AlertFilter.all, label: '全部'),
              ],
            ),
          ),
          Expanded(
            child: listAsync.when(
              loading: () => const UtenSkeletonList(itemCount: 4),
              error: (e, _) => UtenEmpty.error(message: '加载失败：$e'),
              data: (list) {
                if (list.isEmpty) {
                  return ListView(children: const [
                    SizedBox(height: 80),
                    UtenEmpty(icon: Icons.check_circle_outline_rounded, message: '暂无异常告警 🎉'),
                  ]);
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: UtenResponsiveGrid(
                    itemCount: list.length,
                    itemBuilder: (context, i, _) => _AlertCard(alert: list[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert});
  final Alert alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levelColor = switch (alert.level) {
      AlertLevel.high => UtenColors.error,
      AlertLevel.medium => UtenColors.warning,
      AlertLevel.low => UtenColors.slate500,
    };
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: levelColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(alert.type.icon, color: levelColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  children: [
                    UtenStatusBadge(
                        label: alert.type.label,
                        type: UtenStatusBadgeType.neutral,
                        size: UtenStatusBadgeSize.small),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: levelColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${alert.level.label}级',
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              UtenStatusBadge(
                label: alert.status.label,
                type: alert.status == AlertStatus.resolved
                    ? UtenStatusBadgeType.success
                    : alert.status == AlertStatus.processing
                        ? UtenStatusBadgeType.warning
                        : UtenStatusBadgeType.danger,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(alert.content, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.location_on_outlined, size: 13, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(
                child: Text(alert.source ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ),
              Text(_fmt(alert.time),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          if (alert.status == AlertStatus.pending) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已标记处理中（Mock）'))),
                icon: const Icon(Icons.touch_app_rounded, size: 18),
                label: const Text('开始处理'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _fmt(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  return '${d.month}-${d.day}';
}
