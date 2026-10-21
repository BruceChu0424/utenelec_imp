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
// - 页面动作只显示文字与计数，不带图标；窄屏通过统一操作面板保留完整文案。
//
// 用法：直接放进 `UtenAppBar(actions: [...])`，间距由顶栏统一管理。

import 'dart:async';

import 'package:flutter/material.dart';

import 'uten_button.dart';
import '../../core/theme/uten_tokens.dart';
import '../layout/uten_app_bar_action_scope.dart';

class UtenAppBarActionButton extends StatelessWidget {
  const UtenAppBarActionButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.onLongPress,
    this.tooltip,
    this.compact = false,
    this.badge,
    this.isLoading = false,
  });

  /// 按钮文案，窄屏同样保留。
  final String label;

  /// Kept for source compatibility. Header actions display their text label.
  final IconData? icon;

  /// Return the real request Future so the header can show pending feedback
  /// and prevent another click until completion.
  final FutureOr<void> Function()? onPressed;
  final FutureOr<void> Function()? onLongPress;

  /// 悬停提示；缺省用 [label]。
  final String? tooltip;

  /// Kept for source compatibility. Narrow headers use the actions panel.
  final bool compact;

  /// 文案右侧的计数徽章（如「草稿」的红底白字数量）。窄屏也保留——
  /// 数字才是用户要看的那一眼，收的是文案不是计数。
  final Widget? badge;

  /// 进行中（「刷新」这类会等网络的动作）：走 UtenButton 自带的转圈，高度不变。
  final bool isLoading;

  /// 顶栏动作统一高度（顶栏 56 高，留出上下呼吸）。
  static const double height = UtenControlMetrics.compactHeight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: UtenAppBarActionPresentation.contains(context)
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip ?? label,
        child: UtenButton(
          size: UtenButtonSize.small,
          height: height,
          isLoading: isLoading,
          onPressed: onPressed,
          onLongPress: onLongPress,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              if (badge != null) ...[const SizedBox(width: 6), badge!],
            ],
          ),
        ),
      ),
    );
  }
}
