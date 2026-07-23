// UtenCard - 通用卡片（v2 - 大厂企业后台范）
// 文档：docs/02-组件库/UtenCard.md
//
// 设计原则：
// - 白底 + 细边框（slate-200）+ 极轻阴影（offset 1px）
// - 不用渐变、不用过重阴影（除非显式 elevation: high）
// - 玻璃拟态保留（仅在 rich 档启用，且要求显式声明 variant: glass）

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_colors.dart';
import '../../shared/providers/performance_provider.dart';

class UtenCard extends ConsumerWidget {
  const UtenCard({
    super.key,
    required this.child,
    this.variant = UtenCardVariant.solid,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.onLongPress,
    this.borderRadius = 12,
    this.showBorder = true,
    this.elevation = UtenCardElevation.low,
  });

  final Widget child;
  final UtenCardVariant variant;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double borderRadius;
  final bool showBorder;

  /// 阴影层级
  final UtenCardElevation elevation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);
    final isDark = theme.brightness == Brightness.dark;

    // 玻璃拟态仅在 rich 档启用，其他档降级为实心
    final effectiveVariant =
        (variant == UtenCardVariant.glass && !tier.enableBlur)
        ? UtenCardVariant.solid
        : variant;

    final bgColor = switch (effectiveVariant) {
      UtenCardVariant.solid => theme.colorScheme.surface,
      UtenCardVariant.glass =>
        (isDark ? UtenColors.darkSurface : Colors.white).withValues(alpha: 0.7),
      UtenCardVariant.outlined => Colors.transparent,
    };

    final borderColor = showBorder
        ? switch (effectiveVariant) {
            UtenCardVariant.solid =>
              isDark ? UtenColors.darkBorder : UtenColors.border,
            UtenCardVariant.glass =>
              (isDark ? UtenColors.teal400 : theme.colorScheme.primary)
                  .withValues(alpha: 0.3),
            UtenCardVariant.outlined =>
              isDark ? UtenColors.darkBorderStrong : UtenColors.borderStrong,
          }
        : null;

    final shadows = switch (elevation) {
      UtenCardElevation.none => null,
      UtenCardElevation.low => UtenColors.cardShadow(isDark: isDark),
      UtenCardElevation.high => UtenColors.cardShadowLg(isDark: isDark),
    };

    // 关键：把卡片视觉（背景色 + 边框）放到 Material 本身，让 Material
    // 同时充当"视觉表面"和"ink 表面"。这样 child 是 ListTile/InkWell 时，
    // 它们的 ripple 直接画在 Material 表面上，没有任何中间 DecoratedBox
    // 遮挡，不再触发 "ListTile background color or ink splashes may be
    // invisible" 警告。
    //
    // - 背景色：Material.color
    // - 边框：   Material.shape (RoundedRectangleBorder + side)
    // - 圆角裁剪：Material.clipBehavior（替换 Container 的 BoxDecoration.borderRadius）
    // - 阴影：   外层 DecoratedBox（Material 3 elevation 走的是 surface tint
    //          而非传统阴影，不能直接复刻 UtenColors.cardShadow 的极轻效果）
    Widget content = Padding(padding: padding, child: child);

    // 卡片自带的 onTap/onLongPress：InkWell 必须放在 Material 内部，
    // 这样 ripple 才会画在卡片这张 Material 上（而不是更外层）。
    if (onTap != null || onLongPress != null) {
      content = InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(borderRadius),
        child: content,
      );
    }

    Widget card = Material(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        side: borderColor != null ? BorderSide(color: borderColor) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    // 阴影：外包一层 DecoratedBox，boxShadow 渲染在 Material 外侧，
    // 不会遮挡卡片内部的 ink 效果。
    if (shadows != null) {
      card = DecoratedBox(
        decoration: BoxDecoration(boxShadow: shadows),
        child: card,
      );
    }

    // 玻璃拟态：在 Material 外再包 BackdropFilter（不影响 ink 表面）
    if (effectiveVariant == UtenCardVariant.glass) {
      card = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: card,
        ),
      );
    }

    // margin：Container 的 margin 等价于 Padding
    if (margin != null) {
      card = Padding(padding: margin!, child: card);
    }

    return card;
  }
}

enum UtenCardVariant { solid, glass, outlined }

enum UtenCardElevation {
  /// 无阴影
  none,

  /// 极轻阴影（默认，让卡片漂浮于背景）
  low,

  /// 较强阴影（悬浮态、对话框）
  high,
}
