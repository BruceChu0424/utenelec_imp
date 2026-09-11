// 顶栏（AppBar.actions）动作按钮的唯一形态。
//
// 背景：顶栏右上角此前一页一个样——「草稿(N)」是 tonal 浅底深字的 UtenButton、
// 「权限设置」在宽屏是裸 TextButton.icon、窄屏又变成 IconButton，三种底色三种
// 高度。用户明确要求「这些按钮 颜色大小都统一起来」：**深绿实心 + 白字**、同一高度。
//
// 口径：
// - 配色走 [UtenButtonType.primary]（浅色主题 colorScheme.primary = teal700 深绿、
//   onPrimary 白字；深色主题自动提亮为 teal400，不在暗底上糊成一块）。与表格工具条
//   的「表头设置 x/y」「预览打印」同一视觉语言。
// - 高度固定 [height]=36：顶栏 56 高，44/52 的全站默认会顶满上下留白。
// - [compact]=true 只渲染图标（窄屏顶栏放不下文案），底色/高度/圆角不变——
//   窄屏缩的是文案不是形态，避免「一个按钮两种长相」。
//
// 用法：直接放进 `UtenAppBar(actions: [...])`，本组件自带右侧 4px 间距。

import 'package:flutter/material.dart';

import 'uten_button.dart';

class UtenAppBarActionButton extends StatelessWidget {
  const UtenAppBarActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.compact = false,
    this.badge,
  });

  /// 按钮文案（[compact]=true 时不渲染，仅进 tooltip / 语义标签）。
  final String label;

  final IconData icon;

  final VoidCallback? onPressed;

  /// 悬停提示；缺省用 [label]。
  final String? tooltip;

  /// 窄屏收敛为纯图标。
  final bool compact;

  /// 文案右侧的计数徽章（如「草稿」的红底白字数量）。窄屏也保留——
  /// 数字才是用户要看的那一眼，收的是文案不是计数。
  final Widget? badge;

  /// 顶栏动作统一高度（顶栏 56 高，留出上下呼吸）。
  static const double height = 36;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip ?? label,
        child: UtenButton(
          size: UtenButtonSize.small,
          height: height,
          icon: icon,
          onPressed: onPressed,
          // compact 下仍走同一个 UtenButton：图标已由 icon 渲染，文案让位，
          // 但徽章保留（数字是用户要看的那一眼）。
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact) Text(label),
              if (badge != null) ...[
                if (!compact) const SizedBox(width: 6),
                badge!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
