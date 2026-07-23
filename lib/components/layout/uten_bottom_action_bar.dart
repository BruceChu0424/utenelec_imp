// UtenBottomActionBar - 底部固定操作栏
// 文档：docs/02-组件库/UtenBottomActionBar.md（待写）
//
// 用途：详情页 / 表单页的内容可滚动，主操作按钮固定吸底。
// 视觉：surface 背景 + 顶部细分隔线 + SafeArea 底部安全区。
// 用法：把多个按钮放进一个 Row 作为 child，即可"同一行排布"，避免按钮各占一行。
//
//   Column(
//     children: [
//       Expanded(child: ListView(...)),     // 可滚动内容
//       UtenBottomActionBar(                // 吸底操作栏
//         child: Row(children: [删除, 提交]),
//       ),
//     ],
//   )

import 'package:flutter/material.dart';

class UtenBottomActionBar extends StatelessWidget {
  const UtenBottomActionBar({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.background,
    this.showDivider = true,
  });

  /// 操作区内容，通常是一个 [Row]，里面放若干 [UtenButton]。
  final Widget child;

  /// 操作区内边距。
  final EdgeInsetsGeometry padding;

  /// 背景色，默认跟随主题 surface。
  final Color? background;

  /// 是否显示顶部分隔线。
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background ?? theme.colorScheme.surface,
          border: showDivider
              ? Border(top: BorderSide(color: theme.colorScheme.outlineVariant))
              : null,
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
