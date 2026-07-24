// UtenListItem - 列表项卡片（一行可点击的卡片，常用于工资条/报销/通知列表）
// 文档：docs/02-组件库/UtenListItem.md（待写）

import 'package:flutter/material.dart';

/// Uten 列表项
///
/// 通用一行卡片：左侧图标/头像 + 标题 + 副标题 + 右侧状态/数值/箭头
class UtenListItem extends StatelessWidget {
  const UtenListItem({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.leadingIcon,
    this.leadingColor,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.showDivider = false,
    this.badge,
    this.showChevron = false,
  });

  /// 主标题（必填）
  final String title;

  /// 副标题
  final String? subtitle;

  /// 右侧自定义内容（如金额/状态徽章/箭头）
  final Widget? trailing;

  /// 左侧自定义头像（如圆形头像）
  final Widget? leading;

  /// 左侧图标（leading 为 null 时使用）
  final IconData? leadingIcon;

  /// 左侧图标背景色
  final Color? leadingColor;

  /// 点击回调
  final VoidCallback? onTap;

  /// 内边距
  final EdgeInsetsGeometry padding;

  /// 是否显示底部发丝级分隔线
  final bool showDivider;

  /// 右侧状态徽章（便捷参数，与 trailing 互斥）
  final Widget? badge;

  /// 是否在最右侧显示导航箭头（chevron），提示可点击进入详情
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const radius = 14.0;

    final Widget content = Padding(
      padding: padding,
      child: Row(
        children: [
          // 左侧
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          if (leading == null && leadingIcon != null) ...[
            _buildLeadingIcon(theme),
            const SizedBox(width: 12),
          ],
          // 中间
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // 右侧
          if (badge != null) ...[const SizedBox(width: 8), badge!],
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          if (showChevron) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );

    // 卡片视觉：背景色 + 细边框，无阴影（全局卡片去阴影）
    final Widget decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: showDivider
          ? Column(
              children: [
                content,
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: theme.colorScheme.outlineVariant,
                ),
              ],
            )
          : content,
    );

    // 关键：Material 必须在 Container 外面 + InkWell 在 Material 内，
    // 这样 InkWell 的 ripple 绘制在 Material 上方，Container 的背景色不会遮挡它
    if (onTap != null) {
      return Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: decorated,
        ),
      );
    }

    return decorated;
  }

  Widget _buildLeadingIcon(ThemeData theme) {
    final color = leadingColor ?? theme.colorScheme.primary;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(leadingIcon, color: color, size: 20),
    );
  }
}
