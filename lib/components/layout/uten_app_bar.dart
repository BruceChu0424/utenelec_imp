// UtenAppBar - 自适应顶栏
// 文档：docs/02-组件库/UtenAppBar.md（待写）
//
// 设计原则：
// - 标题层级清晰：标题 17px w600，副标题 12px textTertiary
// - 用发丝级底部分隔线代替阴影分层（elevation 恒为 0）
// - blurred 变体：半透明背景 + 背景模糊，用于内容可从顶栏下方滚过的场景

import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../buttons/uten_back_button.dart';

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
    this.showBottomBorder = true,
    this.blurred = false,
    this.centerWidget,
    this.titleWidget,
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

  /// 标题区内「居中」部件（如列表页的 [UtenSegmentedFilter]）。
  /// 与 [title] 共存：[title] 文字靠最左，[centerWidget] 在标题区水平居中；
  /// 空间不足时自动等比缩小（FittedBox），不会溢出报错。
  final Widget? centerWidget;

  /// 完全自定义标题区（整体替换 [title] / [centerWidget]，优先级最高）。
  final Widget? titleWidget;

  /// 是否显示底部发丝级分隔线（带 TabBar 等 bottom 时可关闭）
  final bool showBottomBorder;

  /// 毛玻璃变体：半透明背景 + BackdropFilter 模糊。
  /// 适合内容从顶栏下方滚过的沉浸式页面；性能敏感场景慎用（blur 有开销）。
  final bool blurred;

  @override
  Size get preferredSize {
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Size.fromHeight(
      subtitle != null ? 64 + bottomHeight : 56 + bottomHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final baseColor =
        backgroundColor ??
        theme.appBarTheme.backgroundColor ??
        (isDark ? UtenColors.darkBackground : UtenColors.background);
    final dividerColor =
        theme.dividerTheme.color ??
        (isDark ? UtenColors.darkBorder : UtenColors.divider);

    final appBar = AppBar(
      title: _buildTitleArea(theme, isDark),
      leading:
          leading ??
          (showBackButton ? const UtenBackButton() : const SizedBox.shrink()),
      automaticallyImplyLeading: false,
      actions: actions,
      centerTitle: centerTitle,
      backgroundColor: blurred ? baseColor.withValues(alpha: 0.8) : baseColor,
      foregroundColor: foregroundColor ?? theme.appBarTheme.foregroundColor,
      bottom: bottom,
      flexibleSpace: flexibleSpace,
      // 发丝级底部分隔线代替阴影
      shape: showBottomBorder
          ? Border(bottom: BorderSide(color: dividerColor, width: 0.5))
          : null,
    );

    if (!blurred) return appBar;

    // 毛玻璃：裁剪矩形内做背景模糊（AppBar 自身无圆角，ClipRect 即可）
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: appBar,
      ),
    );
  }

  /// 组合标题区，优先级：[titleWidget] > [title]+[centerWidget] > [title]。
  Widget? _buildTitleArea(ThemeData theme, bool isDark) {
    if (titleWidget != null) return titleWidget;

    final titleCol = title != null ? _titleColumn(theme, isDark) : null;
    if (centerWidget == null) return titleCol;

    // title 文字靠最左；centerWidget 在标题右侧的剩余空间内水平居中，
    // FittedBox.scaleDown 保证空间不足时整体缩小——不溢出、不与标题重叠。
    return Row(
      children: [
        ?titleCol,
        Expanded(
          child: Center(
            child: FittedBox(fit: BoxFit.scaleDown, child: centerWidget!),
          ),
        ),
      ],
    );
  }

  Widget _titleColumn(ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title!,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: foregroundColor ?? theme.colorScheme.onSurface,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color:
                    foregroundColor?.withValues(alpha: 0.7) ??
                    (isDark
                        ? UtenColors.darkTextTertiary
                        : UtenColors.textTertiary),
              ),
            ),
          ),
      ],
    );
  }
}
