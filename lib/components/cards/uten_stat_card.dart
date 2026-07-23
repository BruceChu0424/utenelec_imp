// UtenStatCard - 数据统计卡片（v2 - 大厂 KPI 卡片范）
// 文档：docs/02-组件库/UtenStatCard.md
//
// 设计参考：Linear / Vercel / Stripe Dashboard
// - 中性白卡 + 极轻阴影
// - 图标用浅色圆角方块（不抢镜）
// - 标题 secondary 文字色
// - 数值 primary 大字号 + tabular figures
// - 趋势用语义色 + 小箭头

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_colors.dart';
import '../../shared/providers/performance_provider.dart';
import '../cards/uten_card.dart';
import '../data_display/uten_animated_number.dart';

class UtenStatCard extends ConsumerWidget {
  const UtenStatCard({
    super.key,
    required this.title,
    required this.value,
    this.unit,
    this.icon,
    this.iconColor,
    this.trend,
    this.trendPercent,
    this.onTap,
    this.isLoading = false,
  });

  final String title;
  final num value;
  final String? unit;
  final IconData? icon;
  final Color? iconColor;
  final UtenTrend? trend;
  final double? trendPercent;
  final VoidCallback? onTap;
  final bool isLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);

    if (isLoading) {
      return UtenCard(
        padding: const EdgeInsets.all(20),
        child: _buildSkeleton(theme),
      );
    }

    return UtenCard(
      onTap: onTap,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：图标 + 标题
          Row(
            children: [
              if (icon != null)
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: (iconColor ?? UtenColors.accent)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    color: iconColor ?? UtenColors.accent,
                    size: 18,
                  ),
                ),
              if (icon != null) const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 第二行：数值 + 单位
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              tier.enableNumberAnimation
                  ? UtenAnimatedNumber(
                      value: value,
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    )
                  : Text(
                      _format(value),
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(
                  unit!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          // 第三行：趋势
          if (trend != null && trendPercent != null) ...[
            const SizedBox(height: 8),
            _buildTrend(theme),
          ],
        ],
      ),
    );
  }

  Widget _buildTrend(ThemeData theme) {
    final isUp = trend == UtenTrend.up;
    final color = isUp ? UtenColors.success : UtenColors.error;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
          color: color,
          size: 12,
        ),
        const SizedBox(width: 2),
        Text(
          '${trendPercent!.abs().toStringAsFixed(1)}%',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 12,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '较昨日',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildSkeleton(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 80,
              height: 12,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          width: 120,
          height: 28,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: 60,
          height: 12,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ],
    );
  }

  String _format(num v) {
    if (v is int) return v.toString();
    return v.toStringAsFixed(1);
  }
}

enum UtenTrend {
  up,
  down,
}
