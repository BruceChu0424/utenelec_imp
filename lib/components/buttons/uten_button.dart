import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// The shared Uten action button.
///
/// Uses Material interaction primitives so pointer, keyboard, focus, ripple,
/// and accessibility behavior stay consistent across supported platforms.
class UtenButton extends StatelessWidget {
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
    this.onDisabledTap,
    this.height,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final UtenButtonType type;
  final UtenButtonSize size;
  final bool isLoading;
  final bool isExpanded;
  final IconData? icon;
  final VoidCallback? onLongPress;

  /// 覆盖按钮最小高度（宽度仍按 [_minimumExtent]）。用于把工具条内的按钮
  /// 对齐到同条其它控件（如筛选 chip 的 48），而不动全站默认 44/52。
  final double? height;

  /// Called when the visually disabled button is tapped.
  ///
  /// This is useful for explaining why an action is unavailable. When omitted,
  /// a disabled or loading button remains non-interactive.
  final VoidCallback? onDisabledTap;

  double get _minimumExtent => switch (size) {
    UtenButtonSize.small || UtenButtonSize.medium => 44,
    UtenButtonSize.large => 52,
  };

  EdgeInsetsGeometry get _padding => switch (size) {
    UtenButtonSize.small => const EdgeInsets.symmetric(horizontal: 14),
    UtenButtonSize.medium => const EdgeInsets.symmetric(horizontal: 18),
    UtenButtonSize.large => const EdgeInsets.symmetric(horizontal: 22),
  };

  double get _iconSize => switch (size) {
    UtenButtonSize.small => 16,
    UtenButtonSize.medium => 18,
    UtenButtonSize.large => 20,
  };

  TextStyle get _textStyle => TextStyle(
    fontSize: switch (size) {
      UtenButtonSize.small => 13,
      UtenButtonSize.medium => 14,
      UtenButtonSize.large => 16,
    },
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null && !isLoading;
    final effectiveOnTap = enabled ? onPressed : onDisabledTap;
    final (enabledBackground, enabledForeground, enabledBorder) =
        _resolveColors(colorScheme);

    final background = enabled
        ? enabledBackground
        : colorScheme.onSurface.withValues(alpha: 0.12);
    final foreground = enabled
        ? enabledForeground
        : colorScheme.onSurface.withValues(alpha: 0.38);
    final border = enabled
        ? enabledBorder
        : enabledBorder == null
        ? null
        : colorScheme.outlineVariant;
    final radius = BorderRadius.circular(UtenRadius.control);
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      side: border == null ? BorderSide.none : BorderSide(color: border),
    );

    Widget button = MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        onTap: effectiveOnTap,
        onLongPress: enabled ? onLongPress : null,
        child: Material(
          color: background,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: effectiveOnTap,
            onLongPress: enabled
                ? onLongPress
                : effectiveOnTap == null
                ? null
                : _ignoreLongPress,
            canRequestFocus: effectiveOnTap != null,
            excludeFromSemantics: true,
            customBorder: shape,
            overlayColor: WidgetStateProperty.resolveWith(
              (states) => _resolveStateLayer(
                states: states,
                foreground: foreground,
                enabled: enabled,
                interactive: effectiveOnTap != null,
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: _minimumExtent,
                minHeight: height ?? _minimumExtent,
              ),
              child: Padding(
                padding: _padding,
                child: DefaultTextStyle.merge(
                  style: _textStyle.copyWith(color: foreground),
                  child: Row(
                    mainAxisSize: isExpanded
                        ? MainAxisSize.max
                        : MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isLoading)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ExcludeSemantics(
                            child: SizedBox(
                              width: _iconSize,
                              height: _iconSize,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: foreground,
                              ),
                            ),
                          ),
                        )
                      else if (icon != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(icon, size: _iconSize, color: foreground),
                        ),
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (isExpanded) {
      button = SizedBox(width: double.infinity, child: button);
    }
    return button;
  }

  (Color, Color, Color?) _resolveColors(ColorScheme colorScheme) {
    return switch (type) {
      UtenButtonType.primary => (
        colorScheme.primary,
        colorScheme.onPrimary,
        null,
      ),
      UtenButtonType.secondary => (
        colorScheme.surfaceContainerHigh,
        colorScheme.onSurface,
        null,
      ),
      UtenButtonType.tonal => (
        colorScheme.primaryContainer,
        colorScheme.onPrimaryContainer,
        null,
      ),
      UtenButtonType.ghost => (
        Colors.transparent,
        colorScheme.onSurface,
        colorScheme.outline,
      ),
      UtenButtonType.success => (UtenColors.deepGreen, Colors.white, null),
      UtenButtonType.danger => (colorScheme.error, colorScheme.onError, null),
    };
  }

  void _ignoreLongPress() {}

  Color? _resolveStateLayer({
    required Set<WidgetState> states,
    required Color foreground,
    required bool enabled,
    required bool interactive,
  }) {
    if (!interactive) return null;

    final disabledFactor = enabled ? 1.0 : 0.67;
    if (states.contains(WidgetState.pressed)) {
      return foreground.withValues(alpha: 0.12 * disabledFactor);
    }
    if (states.contains(WidgetState.focused)) {
      return foreground.withValues(alpha: 0.12 * disabledFactor);
    }
    if (states.contains(WidgetState.hovered)) {
      return foreground.withValues(alpha: 0.08 * disabledFactor);
    }
    return null;
  }
}

enum UtenButtonType { primary, secondary, tonal, ghost, success, danger }

enum UtenButtonSize { small, medium, large }
