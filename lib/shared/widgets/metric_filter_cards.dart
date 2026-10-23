// MetricFilterCards - 任务/进度类页面顶部的「指标卡 = 筛选器」卡片区。
//
// 统一自任务工作台（operations_workbench_page，仓库/采购/委外共用）的 _Overview/_MetricCard：
// 卡片即筛选——单选互斥由调用方状态保证（选中一张卡即清除其它筛选维度），再点已选卡取消；
// 计数一律由后端概览/汇总接口提供，不用当前列表页推算或伪造（value 为 null 时显示 '—'）。
// 复用：任务工作台、销售订单进度查询等「顶部卡片 + 列表」同类页面——视觉与交互只维护这一处。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// 指标筛选卡色调 → 颜色（与任务工作台行级状态药丸同色系）。
Color metricToneColor(String tone, ThemeData theme) {
  return switch (tone.toLowerCase()) {
    'error' || 'danger' || 'critical' => theme.colorScheme.error,
    'warning' || 'attention' => UtenColors.warning,
    'orange' || 'partial' => UtenColors.statusOrange,
    'success' || 'ready' => UtenColors.success,
    'info' => UtenColors.info,
    _ => theme.colorScheme.primary,
  };
}

/// 一张指标筛选卡的数据：标签 + 计数 + 色调 + 选中态 + 点击回调（null = 纯展示卡）。
class MetricFilterCardItem {
  const MetricFilterCardItem({
    required this.key,
    required this.label,
    required this.value,
    this.tone = 'neutral',
    this.icon = Icons.assessment_outlined,
    this.description,
    this.selected = false,
    this.onTap,
  });

  final String key;
  final String label;

  /// 计数；null = 后端尚未返回，显示 '—'。
  final num? value;
  final String tone;
  final IconData icon;

  /// 可选说明行（单卡任务中心的口径说明，如「仅显示分配给您的订货单」）；
  /// 最多两行，超出省略。筛选卡行一般不设置。
  final String? description;
  final bool selected;
  final VoidCallback? onTap;
}

class MetricFilterCards extends StatelessWidget {
  const MetricFilterCards({
    super.key,
    required this.items,
    this.itemWidth = 220,
  });

  final List<MetricFilterCardItem> items;

  /// 最小卡宽度；按可用空间等分排列，窄屏自动换行。
  final double itemWidth;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth) {
          return SizedBox(
            width: itemWidth.isFinite ? itemWidth : 220,
            child: MetricFilterCards(items: items, itemWidth: itemWidth),
          );
        }
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final minimumWidth = itemWidth * scale;
        final maximumColumns = minimumWidth.isFinite
            ? ((constraints.maxWidth + UtenSpacing.s12) /
                      (minimumWidth + UtenSpacing.s12))
                  .floor()
                  .clamp(1, items.length)
            : 1;
        final rows = (items.length / maximumColumns).ceil();
        final columns = (items.length / rows).ceil();
        final cardWidth =
            (constraints.maxWidth - (columns - 1) * UtenSpacing.s12) / columns;
        final contentWidth = math.max(1.0, cardWidth - UtenSpacing.s16 * 2);
        final theme = Theme.of(context);
        double measure(
          String text,
          TextStyle? style,
          double width, {
          int? maxLines,
        }) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: maxLines,
            ellipsis: maxLines == null ? null : '…',
          )..layout(maxWidth: width);
          final height = painter.height;
          painter.dispose();
          return height;
        }

        final labelHeight = items
            .map(
              (item) => measure(
                item.label,
                theme.textTheme.bodySmall,
                math.max(1.0, contentWidth - 22 - UtenSpacing.s8),
              ),
            )
            .fold(22.0, math.max);
        final valueHeight = items
            .map(
              (item) => measure(
                item.value?.toString() ?? '—',
                theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                contentWidth,
              ),
            )
            .reduce(math.max);
        final descriptionHeight = items
            .map(
              (item) => measure(
                item.description ?? ' ',
                theme.textTheme.bodySmall,
                contentWidth,
                maxLines: 2,
              ),
            )
            .reduce(math.max);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var start = 0; start < items.length; start += columns) ...[
              if (start > 0) const SizedBox(height: UtenSpacing.s12),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var column = 0; column < columns; column++) ...[
                      if (column > 0) const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: start + column < items.length
                            ? _MetricFilterCard(
                                item: items[start + column],
                                labelHeight: labelHeight,
                                valueHeight: valueHeight,
                                descriptionHeight: descriptionHeight,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MetricFilterCard extends StatelessWidget {
  const _MetricFilterCard({
    required this.item,
    required this.labelHeight,
    required this.valueHeight,
    required this.descriptionHeight,
  });

  final MetricFilterCardItem item;
  final double labelHeight;
  final double valueHeight;
  final double descriptionHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = metricToneColor(item.tone, theme);
    final selected = item.selected;
    return Semantics(
      button: item.onTap != null,
      selected: selected,
      label: '${item.label}，${item.value ?? '—'}',
      child: Material(
        color: selected
            ? color.withValues(alpha: 0.1)
            : theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: UtenRadius.lgAll,
          side: BorderSide(
            color: selected ? color : theme.colorScheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: item.onTap,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: labelHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(item.icon, color: color, size: 22),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Text(
                          item.label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                SizedBox(
                  height: valueHeight,
                  child: Text(
                    item.value?.toString() ?? '—',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                SizedBox(
                  height: descriptionHeight,
                  child: Text(
                    item.description ?? ' ',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
