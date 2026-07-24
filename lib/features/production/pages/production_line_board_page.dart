// 流水线看板页（Phase 4）
// 文档：docs/03-页面/流水线看板页.md
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区（1600），
// 内部 UtenResponsiveGrid 按容器宽度自动扩列，超宽屏可看更多产线

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production.dart';
import '../providers/production_providers.dart';

class ProductionLineBoardPage extends ConsumerWidget {
  const ProductionLineBoardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(productionLineBoardProvider);
    return Scaffold(
      appBar: const UtenAppBar(
        title: '流水线看板',
        subtitle: '今日 · 白班',
        showBackButton: true,
      ),
      body: async.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(productionLineBoardProvider),
        ),
        data: (lines) {
          if (lines.isEmpty) {
            return const UtenEmpty(
                icon: Icons.view_module_outlined, message: '暂无产线数据');
          }
          // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
          Widget board = SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: UtenResponsiveGrid(
              itemCount: lines.length,
              itemBuilder: (context, i, _) => _LineCard(line: lines[i]),
            ),
          );
          if (context.breakpoint.isCompact) {
            board = UtenContentContainer(child: board);
          }
          return board;
        },
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.line});
  final ProductionLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (statusColor, badgeType) = switch (line.status) {
      LineStatus.running => (UtenColors.success, UtenStatusBadgeType.success),
      LineStatus.changeover => (UtenColors.warning, UtenStatusBadgeType.warning),
      LineStatus.stopped => (UtenColors.error, UtenStatusBadgeType.danger),
    };
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(line.name,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              UtenStatusBadge(
                label: line.status.label,
                type: badgeType,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text('工单 ${line.order}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: UtenSpacing.s12),
          // 进度
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: line.progress,
                    minHeight: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    color: statusColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('${(line.progress * 100).round()}%',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          const Divider(),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(
                child: _Metric(
                    label: '节拍',
                    value: line.takt == null ? '—' : '${line.takt}s'),
              ),
              Expanded(
                child: _Metric(
                    label: '今日产量', value: '${line.outputToday}'),
              ),
              Expanded(
                child: _Metric(
                  label: '异常',
                  value: '${line.alertCount}',
                  valueColor:
                      line.alertCount > 0 ? UtenColors.error : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value,
            style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: valueColor,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}
