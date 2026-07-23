// UtenAppBar - 自适应顶栏
// 文档：docs/02-组件库/UtenAppBar.md（待写）

import 'package:flutter/material.dart';

/// Uten 自适应顶栏
///
/// 在手机端显示紧凑标题，在大屏端可以扩展显示副标题/操作区。
class UtenAppBar extends StatelessWidget implements PreferredSizeWidget {
  const UtenAppBar({
    super.key,
    this.title,
    this.subtitle,
    this.leading,
    this.actions,
    this.centerTitle = false,
    this.showBackButton = false,
    this.backgroundColor,
    this.foregroundColor,
    this.bottom,
    this.flexibleSpace,
  });

  final String? title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget>? actions;
  final bool centerTitle;
  final bool showBackButton;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final PreferredSizeWidget? bottom;
  final Widget? flexibleSpace;

  @override
  Size get preferredSize {
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Size.fromHeight(subtitle != null ? 64 + bottomHeight : 56 + bottomHeight);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppBar(
      title: title != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title!,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: foregroundColor ?? theme.colorScheme.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foregroundColor?.withValues(alpha: 0.7) ??
                            theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            )
          : null,
      leading: leading ?? (showBackButton ? null : const SizedBox.shrink()),
      automaticallyImplyLeading: showBackButton,
      actions: actions,
      centerTitle: centerTitle,
      backgroundColor: backgroundColor ?? theme.appBarTheme.backgroundColor,
      foregroundColor: foregroundColor ?? theme.appBarTheme.foregroundColor,
      bottom: bottom,
      flexibleSpace: flexibleSpace,
    );
  }
}
