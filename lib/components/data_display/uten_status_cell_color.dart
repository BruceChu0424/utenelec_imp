// 徽章配色解析的公共落点（2026-09-27 用户口径「表格格内胶囊改成单元格背景色」）。
// UtenStatusBadge 自身与表格 cellColor（utenStatusBadgeCellColor）共用同一份
// 浅底/深字解析，保证徽章与整格底色永远同色；单独成文件供两处 import。
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import 'uten_status_badge.dart';

/// 徽章同款底色，给表格 cellColor 铺整格用（替代单元格内嵌胶囊）：
/// 浅色模式=柔和浅底，深色模式=语义色 18% 叠加。文字颜色与字号由表格
/// cellColor 双向对比度约定统一接管（黑/白自适应 + 正文字号）。
Color udenStatusBadgeCellColor(BuildContext context, UtenStatusBadgeType type) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return resolveStatusBadgeColors(type, isDark).$1;
}

/// 解析两色：背景色（柔和浅底）/ 文字与图标色（深档同色）
///
/// 浅色模式：*Bg 浅底 + *Text 深字（对比度达标）；
/// 深色模式：语义色 18% 透明底 + 亮档文字。
(Color, Color) resolveStatusBadgeColors(UtenStatusBadgeType t, bool isDark) {
  if (isDark) {
    return switch (t) {
      UtenStatusBadgeType.neutral => (
        UtenColors.slate400.withValues(alpha: 0.18),
        UtenColors.slate300,
      ),
      UtenStatusBadgeType.info => (
        UtenColors.info.withValues(alpha: 0.18),
        UtenColors.infoOnDark,
      ),
      UtenStatusBadgeType.success => (
        UtenColors.success.withValues(alpha: 0.18),
        UtenColors.successOnDark,
      ),
      UtenStatusBadgeType.warning => (
        UtenColors.warning.withValues(alpha: 0.18),
        UtenColors.warningOnDark,
      ),
      UtenStatusBadgeType.danger => (
        UtenColors.error.withValues(alpha: 0.18),
        UtenColors.errorOnDark,
      ),
      UtenStatusBadgeType.fuchsia => (
        UtenColors.fuchsia.withValues(alpha: 0.18),
        UtenColors.fuchsiaOnDark,
      ),
      UtenStatusBadgeType.violet => (
        UtenColors.violet.withValues(alpha: 0.18),
        UtenColors.violetOnDark,
      ),
      UtenStatusBadgeType.accent => (
        UtenColors.teal500.withValues(alpha: 0.18),
        UtenColors.teal300,
      ),
    };
  }
  return switch (t) {
    UtenStatusBadgeType.neutral => (
      UtenColors.surfaceMid,
      UtenColors.textSecondary,
    ),
    UtenStatusBadgeType.info => (UtenColors.infoBg, UtenColors.infoText),
    UtenStatusBadgeType.success => (
      UtenColors.successBg,
      UtenColors.successText,
    ),
    UtenStatusBadgeType.warning => (
      UtenColors.warningBg,
      UtenColors.warningText,
    ),
    UtenStatusBadgeType.danger => (UtenColors.errorBg, UtenColors.errorText),
    UtenStatusBadgeType.fuchsia => (
      UtenColors.fuchsiaBg,
      UtenColors.fuchsiaText,
    ),
    UtenStatusBadgeType.violet => (UtenColors.violetBg, UtenColors.violetText),
    UtenStatusBadgeType.accent => (UtenColors.tealSurface, UtenColors.teal700),
  };
}
