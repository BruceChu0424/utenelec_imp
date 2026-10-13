// UtenSectionHeader - 区块标题
// 文档：docs/02-组件库/UtenSectionHeader.md（待写）
//
// 统一各页面散落的区块标题实现（此前 _sectionTitle / _buildSectionTitle / 内联 Text
// 存在颜色 onSurface vs onSurfaceVariant、字重 w600 vs w700、是否带图标等不一致）。
//
// 设计原则：纯文字为主（不使用彩色圆角方块图标容器），可选一个简洁的前缀线性图标。
//
//   UtenSectionHeader(title: '报销明细')                       // 内容区标题（15px w600）
//   UtenSectionHeader(title: '应发明细', icon: Icons.add_circle_outline_rounded)
//   UtenSectionHeader(title: '报销明细 (3)', trailing: 添加按钮)
//   UtenSectionHeader(title: '外观', subdued: true)            // 设置页分组标题（弱化）

import '../../core/theme/uten_tokens.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/brand_theme.dart';

class UtenSectionHeader extends StatelessWidget {
  const UtenSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.accentColor,
    this.trailing,
    this.subdued = false,
  });

  /// 标题文字。
  final String title;

  /// 可选前缀图标（简洁线性图标，青绿色，仅 [subdued]=false 时着色）。
  final IconData? icon;

  /// 可选标题左侧色条颜色（与 UtenCollapsibleSection 的色条统一：4×16 圆角条）。
  /// null 不显示色条。
  final Color? accentColor;

  /// 可选尾部控件（如"添加"按钮、计数徽章）。
  final Widget? trailing;

  /// 弱化样式：用于设置页等"分组标签"，颜色更浅、字号更小。
  /// 默认 false：内容区标题，15px w600 onSurface。
  final bool subdued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final stacked =
              trailing != null && constraints.maxWidth < 420 * textScale;
          final heading = Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (accentColor != null) ...[
                Container(
                  width: 4,
                  height: 16,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(UtenRadius.xs),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 16,
                  color: brandAccent(theme, UtenColors.teal600),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  title,
                  style: subdued
                      ? theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant,
                          letterSpacing: 0.5,
                        )
                      : theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                          letterSpacing: -0.1,
                          color: theme.colorScheme.onSurface,
                        ),
                ),
              ),
            ],
          );
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: trailing,
                ),
              ],
            );
          }
          if (trailing == null) return heading;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: heading),
              const SizedBox(width: 8),
              trailing!,
            ],
          );
        },
      ),
    );
  }
}
