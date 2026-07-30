// UtenButton - 主按钮（v2 - 大厂企业后台范）
// 文档：docs/02-组件库/UtenButton.md
//
// 设计原则：
// - 主按钮：实心深绿（主题色），无边框、无阴影、无渐变
// - 次要按钮：实心浅色背景 + 中性文字（slate）
// - 幽灵按钮：透明背景 + 细边框 + 中性文字
// - 危险按钮：实心红
// - 按下时：opacity 0.7（无 scale 变换，避免 layout shift）
// - 触摸目标 ≥44pt

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

class UtenButton extends StatefulWidget {
  const UtenButton({
    super.key,
    this.onPressed,
    required this.child,
    this.type = UtenButtonType.primary,
    this.size = UtenButtonSize.medium,
    this.isLoading = false,
    this.isExpanded = false,
    this.icon,
    this.onLongPress,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final UtenButtonType type;
  final UtenButtonSize size;
  final bool isLoading;
  final bool isExpanded;
  final IconData? icon;
  final VoidCallback? onLongPress;

  @override
  State<UtenButton> createState() => _UtenButtonState();
}

class _UtenButtonState extends State<UtenButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  bool get _isEnabled => widget.onPressed != null && !widget.isLoading;

  void _setHovered(bool v) {
    if (_isHovered != v) setState(() => _isHovered = v);
  }

  void _setPressed(bool v) {
    if (_isPressed != v) setState(() => _isPressed = v);
  }

  EdgeInsetsGeometry get _padding => switch (widget.size) {
    UtenButtonSize.small => const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 8,
    ),
    UtenButtonSize.medium => const EdgeInsets.symmetric(
      horizontal: 18,
      vertical: 12,
    ),
    UtenButtonSize.large => const EdgeInsets.symmetric(
      horizontal: 22,
      vertical: 16,
    ),
  };

  double get _iconSize => widget.size == UtenButtonSize.small
      ? 16
      : (widget.size == UtenButtonSize.large ? 20 : 18);

  TextStyle get _textStyle => TextStyle(
    fontSize: widget.size == UtenButtonSize.small
        ? 13
        : (widget.size == UtenButtonSize.large ? 16 : 14),
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final (bg, fg, borderColor) = _resolveColors(isDark);
    final disabledBg = isDark
        ? UtenColors.darkSurfaceHigh
        : UtenColors.slate200;
    final disabledFg = isDark
        ? UtenColors.darkTextTertiary
        : UtenColors.slate400;

    // 按下/悬停反馈：仅改透明度，无 layout 变换
    double opacity = 1.0;
    if (!_isEnabled) {
      opacity = 1.0; // disabled 走 disabledBg/disabledFg
    } else if (_isPressed) {
      opacity = 0.7;
    } else if (_isHovered && borderColor == null) {
      // 实心按钮 hover 时用深一档色（仅主按钮/危险按钮）
      opacity = 0.92;
    }

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: _isEnabled ? widget.onPressed : null,
        onLongPress: _isEnabled ? widget.onLongPress : null,
        child: Container(
          constraints: widget.isExpanded
              ? const BoxConstraints(minWidth: double.infinity)
              : null,
          padding: _padding,
          decoration: BoxDecoration(
            color: _isEnabled ? bg : disabledBg,
            borderRadius: BorderRadius.circular(10),
            border: borderColor != null ? Border.all(color: borderColor) : null,
          ),
          foregroundDecoration: _isEnabled
              ? BoxDecoration(
                  color: Colors.white.withValues(
                    alpha: opacity - 1.0 + 0.0001 <= -0.001 ? 0 : 0,
                  ),
                )
              : null,
          child: Opacity(
            opacity: _isEnabled ? opacity : 1.0,
            child: DefaultTextStyle.merge(
              style: _textStyle.copyWith(color: _isEnabled ? fg : disabledFg),
              child: Row(
                mainAxisSize: widget.isExpanded
                    ? MainAxisSize.max
                    : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.isLoading)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: _iconSize,
                        height: _iconSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(
                            _isEnabled ? fg : disabledFg,
                          ),
                        ),
                      ),
                    )
                  else if (widget.icon != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        widget.icon,
                        size: _iconSize,
                        color: _isEnabled ? fg : disabledFg,
                      ),
                    ),
                  widget.child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 返回 (背景色, 文字色, 边框色)
  (Color, Color, Color?) _resolveColors(bool isDark) {
    return switch (widget.type) {
      // 主按钮：浅色 / 深色都用 teal500（青绿），统一品牌。
      // 背景是品牌绿，文字/icon 统一用白色，保证品牌色背景下的视觉一致性。
      UtenButtonType.primary => (UtenColors.teal500, Colors.white, null),
      // 次要按钮：浅灰背景 + 深文字（类似 macOS / Linear 的次按钮）
      UtenButtonType.secondary =>
        isDark
            ? (UtenColors.darkSurfaceLow, UtenColors.darkTextPrimary, null)
            : (UtenColors.surfaceMid, UtenColors.textPrimary, null),
      // 品牌色调实心按钮：深绿底（teal700）+ 白字。
      // 原为浅青绿底深绿字，现场反馈"按钮看不见"，统一改为深绿实心白字（2026-07）。
      UtenButtonType.tonal =>
        isDark
            ? (UtenColors.teal600, Colors.white, null)
            : (UtenColors.teal700, Colors.white, null),
      // 幽灵按钮：透明 + 细边框
      UtenButtonType.ghost => (
        Colors.transparent,
        isDark ? UtenColors.darkTextPrimary : UtenColors.textPrimary,
        isDark ? UtenColors.darkBorderStrong : UtenColors.borderStrong,
      ),
      // 危险按钮：实心红
      UtenButtonType.danger => (UtenColors.error, Colors.white, null),
    };
  }
}

enum UtenButtonType { primary, secondary, tonal, ghost, danger }

enum UtenButtonSize { small, medium, large }
