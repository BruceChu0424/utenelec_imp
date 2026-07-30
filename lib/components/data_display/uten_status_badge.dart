// UtenStatusBadge - 状态徽章（用于工资条/报销/审批状态展示）
// 文档：docs/02-组件库/UtenStatusBadge.md（待写）
//
// 设计原则：柔和语义底色（UtenColors.*Bg）+ 深档同色文字，胶囊圆角，无边框。
// 深色模式下自动切换为"半透明底色 + 亮档文字"，保证可读性。

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// Uten 状态徽章
///
/// 用于工资条状态（待审核/已发布/已查看/已下载）、
/// 报销状态（草稿/已提交/已审批/已驳回/已打款）等。
class UtenStatusBadge extends StatelessWidget {
  const UtenStatusBadge({
    super.key,
    required this.label,
    required this.type,
    this.icon,
    this.size = UtenStatusBadgeSize.medium,
  });

  final String label;
  final UtenStatusBadgeType type;
  final IconData? icon;
  final UtenStatusBadgeSize size;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = _resolveColors(type, isDark);
    final (padH, padV, textSize, iconSize) = switch (size) {
      UtenStatusBadgeSize.small => (8.0, 2.0, 11.0, 12.0),
      UtenStatusBadgeSize.medium => (10.0, 3.0, 12.0, 13.0),
      UtenStatusBadgeSize.large => (12.0, 5.0, 13.0, 14.0),
    };

    return Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(UtenRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: colors.$2),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: colors.$2,
              fontSize: textSize,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  /// 解析两色：背景色（柔和浅底）/ 文字与图标色（深档同色）
  ///
  /// 浅色模式：*Bg 浅底 + *Text 深字（对比度达标）；
  /// 深色模式：语义色 18% 透明底 + 亮档文字。
  (Color, Color) _resolveColors(UtenStatusBadgeType t, bool isDark) {
    if (isDark) {
      return switch (t) {
        UtenStatusBadgeType.neutral => (
            UtenColors.slate400.withValues(alpha: 0.18),
            UtenColors.slate300,
          ),
        UtenStatusBadgeType.info => (
            UtenColors.info.withValues(alpha: 0.18),
            const Color(0xFF60A5FA),
          ),
        UtenStatusBadgeType.success => (
            UtenColors.success.withValues(alpha: 0.18),
            const Color(0xFF34D399),
          ),
        UtenStatusBadgeType.warning => (
            UtenColors.warning.withValues(alpha: 0.18),
            const Color(0xFFFBBF24),
          ),
        UtenStatusBadgeType.danger => (
            UtenColors.error.withValues(alpha: 0.18),
            const Color(0xFFF87171),
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
      UtenStatusBadgeType.accent => (
          UtenColors.tealSurface,
          UtenColors.teal700,
        ),
    };
  }
}

/// 徽章类型（决定配色）
enum UtenStatusBadgeType {
  /// 中性灰（默认/草稿）
  neutral,

  /// 信息蓝
  info,

  /// 成功绿（已审批/已发布）
  success,

  /// 警告黄（待处理/审核中）
  warning,

  /// 危险红（驳回/失败）
  danger,

  /// 品牌青绿（已查看/特殊状态）
  accent,
}

/// 徽章尺寸
enum UtenStatusBadgeSize {
  small,
  medium,
  large,
}
