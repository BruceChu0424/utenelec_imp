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
      UtenCardVariant.glass => (isDark ? UtenColors.darkSurface : Colors.white)
          .withValues(alpha: 0.7),
      UtenCardVariant.outlined => Colors.transparent,
    };

    final borderColor = showBorder
        ? switch (effectiveVariant) {
            UtenCardVariant.solid => isDark
                ? UtenColors.darkBorder
                : UtenColors.border,
            UtenCardVariant.glass =>
              (isDark ? UtenColors.teal400 : UtenColors.accent)
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

    // 关键：把卡片视觉（背景色 + 边框 + 阴影）放到 Material 内部，
    // 这样 Material 就是卡片的视觉表面，ListTile/InkWell 的 ink ripple
    // 会直接绘制在卡片上，永远可见，不再触发"ink splashes invisible"警告。
    Widget cardSurface = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: borderColor != null ? Border.all(color: borderColor) : null,
        boxShadow: shadows,
      ),
      child: child,
    );

    // 玻璃拟态：包一层 BackdropFilter（在 Material 内）
    if (effectiveVariant == UtenCardVariant.glass) {
      cardSurface = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: cardSurface,
        ),
      );
    }

    // Material 透明层：为 InkWell 提供 ink 表面。
    // 业务侧若直接放 ListTile，需自行包 Material(transparent)。
    final material = Material(
      color: Colors.transparent,
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(borderRadius),
      clipBehavior: Clip.antiAlias,
      child: onTap != null || onLongPress != null
          ? InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              borderRadius: BorderRadius.circular(borderRadius),
              child: cardSurface,
            )
          : cardSurface,
    );

    return material;
  }
}

enum UtenCardVariant {
  solid,
  glass,
  outlined,
}

enum UtenCardElevation {
  /// 无阴影
  none,

  /// 极轻阴影（默认，让卡片漂浮于背景）
  low,

  /// 较强阴影（悬浮态、对话框）
  high,
}
