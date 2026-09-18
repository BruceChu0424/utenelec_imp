// UtenInlineNotice - 页内提示框(信息 / 警告 / 错误三档)
// 文档：docs/02-组件库/UtenInlineNotice.md
//
// 定位：
// - 页面内容区里「常驻」的一段提示(不是弹出、不会自动消失)：顶部标红的作业提醒
//   (「货品已入库，需到对应储放区域检查」)、单人兼任复核提醒、刷新失败说明等。
// - 与顶部通知条 UtenNotify.banner(会消失的横幅)和 UtenCenterAlert(弹窗)互补。
// - 颜色不是唯一表达：图标 + 正文始终同时在场；error 档同时给 liveRegion 播报。

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// 提示档位。
enum UtenInlineNoticeLevel {
  /// 一般说明(主题主色淡底)。
  info,

  /// 需要注意但不阻断(琥珀)。
  warning,

  /// 必须处理 / 标红(红)。
  error;

  Color get accent => switch (this) {
    UtenInlineNoticeLevel.info => UtenColors.info,
    UtenInlineNoticeLevel.warning => UtenColors.warning,
    UtenInlineNoticeLevel.error => UtenColors.error,
  };

  IconData get icon => switch (this) {
    UtenInlineNoticeLevel.info => Icons.info_outline_rounded,
    UtenInlineNoticeLevel.warning => Icons.warning_amber_rounded,
    UtenInlineNoticeLevel.error => Icons.error_outline_rounded,
  };
}

/// 页内提示框：左图标 + 可选标题 + 正文 + 可选右侧动作。
///
/// ```dart
/// UtenInlineNotice(
///   level: UtenInlineNoticeLevel.error,
///   title: '货品已入库，需到对应储放区域检查',
///   message: '本单 3 行已先入库上架：A 仓 / A-01 …',
/// )
/// ```
class UtenInlineNotice extends StatelessWidget {
  const UtenInlineNotice({
    super.key,
    required this.message,
    this.level = UtenInlineNoticeLevel.info,
    this.title,
    this.trailing,
    this.semanticLabel,
  });

  final String message;
  final UtenInlineNoticeLevel level;
  final String? title;

  /// 右侧动作(按钮等)，null 不渲染。
  final Widget? trailing;

  /// 无障碍整句；null 时用「标题 + 正文」。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = level.accent;
    final titleText = title;
    return Semantics(
      container: true,
      liveRegion: level == UtenInlineNoticeLevel.error,
      label: semanticLabel ??
          (titleText == null ? message : '$titleText。$message'),
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: dark ? 0.18 : 0.10),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(level.icon, size: 20, color: accent),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (titleText != null && titleText.isNotEmpty) ...[
                    Text(
                      titleText,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: level == UtenInlineNoticeLevel.info
                            ? theme.colorScheme.onSurface
                            : accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                  ],
                  Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: UtenSpacing.s8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
