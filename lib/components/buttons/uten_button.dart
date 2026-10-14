import 'dart:async';

import 'package:flutter/material.dart';
import '../layout/uten_app_bar_action_scope.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/responsive/scale.dart';

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

  final FutureOr<void> Function()? onPressed;
  final Widget child;
  final UtenButtonType type;
  final UtenButtonSize size;
  final bool isLoading;
  final bool isExpanded;
  final IconData? icon;
  final VoidCallback? onLongPress;

  /// Aligns a compact control with its toolbar. Touch targets retain their
  /// minimum extent even when the visual desktop height is overridden.
  final double? height;

  /// Called when the visually disabled button is tapped.
  ///
  /// This is useful for explaining why an action is unavailable. When omitted,
  /// a disabled or loading button remains non-interactive.
  final VoidCallback? onDisabledTap;

  UtenButtonSize get _visualSize =>
      size == UtenButtonSize.large &&
          height != null &&
          height! <= UtenControlMetrics.standardHeight
      ? UtenButtonSize.medium
      : size;

  double get _minimumExtent => switch (_visualSize) {
    UtenButtonSize.small => UtenControlMetrics.compactHeight,
    UtenButtonSize.medium => UtenControlMetrics.standardHeight,
    UtenButtonSize.large => UtenControlMetrics.primaryHeight,
  };

  EdgeInsetsGeometry get _padding => switch (_visualSize) {
    UtenButtonSize.small => const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 8,
    ),
    UtenButtonSize.medium => const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 8,
    ),
    UtenButtonSize.large => const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 8,
    ),
  };

  double get _iconSize => switch (_visualSize) {
    UtenButtonSize.small => 16,
    UtenButtonSize.medium => 18,
    UtenButtonSize.large => 20,
  };

  TextStyle get _textStyle => TextStyle(
    fontSize: switch (_visualSize) {
      UtenButtonSize.small => 14,
      UtenButtonSize.medium => 14,
      UtenButtonSize.large => 16,
    },
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inAppBar = UtenAppBarActionPresentation.contains(context);
    final enabled = onPressed != null && !isLoading;
    final effectiveOnTap = enabled
        ? UtenAppBarActionScope.wrap(context, onPressed)
        : onDisabledTap;
    final effectiveLongPress = enabled
        ? UtenAppBarActionScope.wrap(context, onLongPress)
        : null;
    final (enabledBackground, enabledForeground, enabledBorder) =
        _resolveColors(colorScheme, inAppBar: inAppBar);

    // 禁用态刻意比 M3 默认（12% 底 + 38% 字）浓：默认那套在浅色底上几乎透明，
    // 用户在物料分析/下达采购等页反馈「不选的时候根本不知道这里可以点」。
    // 现在是「实底 + 描边 + 可读灰字」——看得见是个按钮，也看得出现在不可用。
    // 描边对所有类型都给（含本来无边的实心型），禁用态才有清晰边界。
    final background = enabled
        ? enabledBackground
        : colorScheme.surfaceContainerHigh;
    final foreground = enabled
        ? enabledForeground
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    final border = enabled ? enabledBorder : colorScheme.outline;
    final radius = BorderRadius.circular(UtenRadius.control);
    final minimumWidth = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: context.scaled(
        inAppBar ? UtenFilterRow.minHeight : _minimumExtent,
      ),
    );
    final minimumHeight = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: context.scaled(
        inAppBar ? UtenFilterRow.minHeight : (height ?? _minimumExtent),
      ),
    );
    final iconSize = context.scaled(_iconSize);
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      side: border == null ? BorderSide.none : BorderSide(color: border),
    );

    Widget button = MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        onTap: effectiveOnTap,
        onLongPress: effectiveLongPress,
        child: Material(
          color: background,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: effectiveOnTap,
            onLongPress: enabled
                ? effectiveLongPress
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
                minWidth: minimumWidth,
                minHeight: minimumHeight,
              ),
              child: Padding(
                padding: inAppBar
                    ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                    : _padding,
                child: DefaultTextStyle.merge(
                  style:
                      (inAppBar
                              ? const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                )
                              : _textStyle)
                          .copyWith(color: foreground),
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
                              width: iconSize,
                              height: iconSize,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: foreground,
                              ),
                            ),
                          ),
                        )
                      else if (icon != null && !inAppBar)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(icon, size: iconSize, color: foreground),
                        ),
                      child is Flexible ? child : Flexible(child: child),
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
    if (inAppBar) {
      button = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: button,
      );
    }
    return button;
  }

  (Color, Color, Color?) _resolveColors(
    ColorScheme colorScheme, {
    bool inAppBar = false,
  }) {
    return switch (inAppBar ? UtenButtonType.primary : type) {
      UtenButtonType.primary => (
        colorScheme.primary,
        colorScheme.onPrimary,
        null,
      ),
      UtenButtonType.secondary => (
        colorScheme.surfaceContainerHigh,
        colorScheme.onSurface,
        // 2026-09-15 用户口径：普通动作按钮（取消/返回/进度追踪这类 secondary）
        // 全站统一带边框——与悬浮组按钮同语言，实底按钮不再「裸」在页面上。
        colorScheme.outline,
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
