// UtenStatusBadge - 状态徽章（用于工资条/报销/审批状态展示）
// 文档：docs/02-组件库/UtenStatusBadge.md（待写）

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

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
    final colors = _resolveColors(type);
    final (padH, padV, textSize, iconSize) = switch (size) {
      UtenStatusBadgeSize.small => (8.0, 3.0, 11.0, 12.0),
      UtenStatusBadgeSize.medium => (10.0, 4.0, 12.0, 13.0),
      UtenStatusBadgeSize.large => (12.0, 6.0, 13.0, 14.0),
    };

    return Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.$2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: colors.$3),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: colors.$3,
              fontSize: textSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 解析三色：背景色（浅）/ 边框色（中）/ 文字色（深）
  (Color, Color, Color) _resolveColors(UtenStatusBadgeType t) {
    return switch (t) {
      UtenStatusBadgeType.neutral => (
          UtenColors.slate200,
          UtenColors.slate400,
          UtenColors.slate700,
        ),
      UtenStatusBadgeType.info => (
          const Color(0xFFDBEAFE),
          const Color(0xFF93C5FD),
          const Color(0xFF1E40AF),
        ),
      UtenStatusBadgeType.success => (
          const Color(0xFFDCFCE7),
          const Color(0xFF86EFAC),
          const Color(0xFF166534),
        ),
      UtenStatusBadgeType.warning => (
          const Color(0xFFFEF3C7),
          const Color(0xFFFCD34D),
          const Color(0xFF92400E),
        ),
      UtenStatusBadgeType.danger => (
          const Color(0xFFFEE2E2),
          const Color(0xFFFCA5A5),
          const Color(0xFF991B1B),
        ),
      UtenStatusBadgeType.accent => (
          UtenColors.teal100,
          UtenColors.teal300,
          UtenColors.teal800,
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
