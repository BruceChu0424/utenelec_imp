// MetricFilterCards - 任务/进度类页面顶部的「指标卡 = 筛选器」卡片区。
//
// 统一自任务工作台（operations_workbench_page，仓库/采购/委外共用）的 _Overview/_MetricCard：
// 卡片即筛选——单选互斥由调用方状态保证（选中一张卡即清除其它筛选维度），再点已选卡取消；
// 计数一律由后端概览/汇总接口提供，不用当前列表页推算或伪造（value 为 null 时显示 '—'）。
// 复用：任务工作台、销售订单进度查询等「顶部卡片 + 列表」同类页面——视觉与交互只维护这一处。
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// 指标筛选卡色调 → 颜色（与任务工作台行级状态药丸同色系）。
Color metricToneColor(String tone, ThemeData theme) {
  return switch (tone.toLowerCase()) {
    'error' || 'danger' || 'critical' => theme.colorScheme.error,
    'warning' || 'attention' => UtenColors.warning,
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

  /// 单卡宽度；传 `double.infinity` 时占满整行（单卡任务中心的横幅式用法）。
  final double itemWidth;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        for (final item in items)
          SizedBox(
            width: itemWidth,
            child: _MetricFilterCard(item: item),
          ),
      ],
    );
  }
}

class _MetricFilterCard extends StatelessWidget {
  const _MetricFilterCard({required this.item});

  final MetricFilterCardItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = metricToneColor(item.tone, theme);
    final selected = item.selected;
    return Semantics(
      button: item.onTap != null,
      selected: selected,
      label: '${item.label}，${item.value ?? '—'}',
      child: GestureDetector(
        onTap: item.onTap,
        child: Container(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.1)
                : theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(
              color: selected ? color : theme.colorScheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: UtenElevation.low(
              isDark: theme.brightness == Brightness.dark,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Icon(item.icon, color: color, size: 22),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.value?.toString() ?? '—',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                    Text(
                      item.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (item.description?.isNotEmpty == true)
                      Text(
                        item.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
