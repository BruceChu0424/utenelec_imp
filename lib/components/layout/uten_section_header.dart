// UtenSectionHeader - 区块标题
// 文档：docs/02-组件库/UtenSectionHeader.md（待写）
//
// 统一各页面散落的区块标题实现（此前 _sectionTitle / _buildSectionTitle / 内联 Text
// 存在颜色 onSurface vs onSurfaceVariant、字重 w600 vs w700、是否带图标等不一致）。
//
//   UtenSectionHeader(title: '报销明细')                       // 内容区标题（粗、onSurface）
//   UtenSectionHeader(title: '应发明细', icon: Icons.add_circle_outline_rounded)
//   UtenSectionHeader(title: '报销明细 (3)', trailing: 添加按钮)
//   UtenSectionHeader(title: '外观', subdued: true)            // 设置页分组标题（弱化）

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

class UtenSectionHeader extends StatelessWidget {
  const UtenSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    this.subdued = false,
  });

  /// 标题文字。
  final String title;

  /// 可选前缀图标（青绿色，仅 [subdued]=false 时着色）。
  final IconData? icon;

  /// 可选尾部控件（如"添加"按钮、计数徽章）。
  final Widget? trailing;

  /// 弱化样式：用于设置页等"分组标签"，颜色更浅、字重更轻。
  /// 默认 false：内容区标题，onSurface + w700。
  final bool subdued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: UtenColors.teal600),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: subdued ? FontWeight.w600 : FontWeight.w700,
                color: subdued
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
                letterSpacing: subdued ? 0.5 : 0,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
