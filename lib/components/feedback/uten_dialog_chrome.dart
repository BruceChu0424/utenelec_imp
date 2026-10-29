import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_close_button.dart';
import 'uten_dialog_action_scope.dart';
import 'uten_dialog_action_layout.dart';

/// A soft accent at the top fades into the theme's dialog surface. This widget
/// adds no constraints, scrolling, Material, or route behavior of its own.
class UtenDialogSurface extends StatelessWidget {
  const UtenDialogSurface({
    super.key,
    required this.child,
    this.backgroundColor,
  });

  final Widget child;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    if (context.dependOnInheritedWidgetOfExactType<_UtenDialogSurfaceScope>() !=
        null) {
      return child;
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base =
        backgroundColor ?? theme.dialogTheme.backgroundColor ?? scheme.surface;
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              scheme.primary.withValues(alpha: dark ? 0.16 : 0.075),
              base,
            ),
            Color.alphaBlend(
              scheme.primary.withValues(alpha: dark ? 0.045 : 0.018),
              base,
            ),
            base,
          ],
          stops: const [0, 0.55, 1],
          transform: const _UtenDialogTopWash(),
        ),
      ),
      child: _UtenDialogSurfaceScope(child: child),
    );
  }
}

class _UtenDialogSurfaceScope extends InheritedWidget {
  const _UtenDialogSurfaceScope({required super.child});

  @override
  bool updateShouldNotify(_UtenDialogSurfaceScope oldWidget) => false;
}

/// Large workspaces keep the wash at the top instead of tinting the whole form.
class _UtenDialogTopWash extends GradientTransform {
  const _UtenDialogTopWash();

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final scale = bounds.height <= 0
        ? 1.0
        : (220 / bounds.height).clamp(0.0, 1.0);
    return Matrix4.diagonal3Values(1, scale, 1)
      ..setTranslationRaw(0, bounds.top * (1 - scale), 0);
  }
}

/// Shared title hierarchy for short dialogs and larger business workspaces.
class UtenDialogHeading extends StatelessWidget {
  const UtenDialogHeading({
    super.key,
    required this.title,
    required this.icon,
    this.leading,
    this.subtitle,
    this.danger = false,
    this.accent,
  });

  final Widget title;
  final Widget? subtitle;
  final IconData icon;
  final Widget? leading;
  final bool danger;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = accent ?? (danger ? scheme.error : scheme.primary);
    if (MediaQuery.sizeOf(context).width < 280) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          if (subtitle != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
              child: subtitle!,
            ),
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.topStart,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.15 : 0.08,
                ),
                borderRadius: UtenRadius.controlAll,
              ),
              child: leading ?? Icon(icon, color: color, size: 28),
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s16),
        Expanded(
          flex: 4,
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: subtitle == null ? UtenSpacing.s12 : UtenSpacing.s4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                if (subtitle != null) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class UtenDialogHeader extends StatelessWidget {
  const UtenDialogHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
    this.windowControls,
    this.onClose,
    this.showCloseButton = false,
    this.closeTooltip,
    this.closeButtonKey,
    this.padding,
  });

  final Widget title;
  final Widget? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;

  /// A single adjacent control group after business actions. When supplied,
  /// this replaces the default close button rather than rendering it twice.
  final Widget? windowControls;
  final FutureOr<void> Function()? onClose;
  final bool showCloseButton;
  final String? closeTooltip;
  final Key? closeButtonKey;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 360;
    Widget heading = title;
    if (title is! UtenDialogHeading &&
        (icon != null || leading != null || subtitle != null)) {
      heading = UtenDialogHeading(
        title: title,
        subtitle: subtitle,
        icon: icon ?? Icons.info_outline_rounded,
        leading: leading,
      );
    }
    return Padding(
      padding:
          padding ??
          EdgeInsets.fromLTRB(compact ? 16 : 24, 24, compact ? 16 : 24, 20),
      child: DefaultTextStyle.merge(
        style: theme.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurface,
          height: 1.3,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            if (trailing != null) ...[
              const SizedBox(width: UtenSpacing.s8),
              trailing!,
            ],
            if (windowControls != null || showCloseButton) ...[
              const SizedBox(width: UtenSpacing.s8),
              windowControls ??
                  UtenCloseButton(
                    key: closeButtonKey,
                    tooltip:
                        closeTooltip ??
                        MaterialLocalizations.of(context).closeButtonTooltip,
                    onPressed: onClose,
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An action group stays centered and wraps as a group in narrow windows.
class UtenDialogActions extends StatelessWidget {
  const UtenDialogActions({
    super.key,
    required this.children,
    this.padding,
    this.alignment = MainAxisAlignment.center,
    this.showDivider = true,
    this.overflowAlignment = OverflowBarAlignment.center,
    this.overflowDirection = VerticalDirection.down,
    this.overflowSpacing = 8,
    this.spacing = 8,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final MainAxisAlignment alignment;
  final bool showDivider;
  final OverflowBarAlignment overflowAlignment;
  final VerticalDirection overflowDirection;
  final double overflowSpacing;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const shape = RoundedRectangleBorder(borderRadius: UtenRadius.controlAll);
    final common = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(
        Size(
          0,
          UtenControlMetrics.minimumHitExtent(
            context,
            desktop: UtenControlMetrics.primaryHeight,
          ),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(
          horizontal: UtenSpacing.s20,
          vertical: UtenSpacing.s12,
        ),
      ),
      shape: const WidgetStatePropertyAll(shape),
      textStyle: WidgetStatePropertyAll(
        theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
    final secondary = common.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLow,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
            : scheme.onSurface,
      ),
      side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
    );
    final primary = common.copyWith(
      elevation: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled) ? 0 : 1,
      ),
      shadowColor: WidgetStatePropertyAll(
        scheme.primary.withValues(alpha: 0.18),
      ),
    );
    return UtenDialogActionScope(
      child: Theme(
        data: theme.copyWith(
          textButtonTheme: TextButtonThemeData(
            style: theme.textButtonTheme.style?.merge(secondary) ?? secondary,
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style:
                theme.outlinedButtonTheme.style?.merge(secondary) ?? secondary,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: theme.filledButtonTheme.style?.merge(primary) ?? primary,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: theme.elevatedButtonTheme.style?.merge(primary) ?? primary,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: showDivider
                ? Border(
                    top: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.55),
                    ),
                  )
                : null,
          ),
          child: Padding(
            padding: padding ?? const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: UtenDialogActionLayout(
              alignment: alignment,
              overflowAlignment: overflowAlignment,
              overflowDirection: overflowDirection,
              overflowSpacing: overflowSpacing,
              spacing: spacing,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
