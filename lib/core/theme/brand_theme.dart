import 'package:flutter/material.dart';

import '../../shared/platform_branding/platform_branding.dart';

Color _hexColor(String value) =>
    Color(int.parse('FF${value.substring(1)}', radix: 16));

class PlatformBrandTheme extends ThemeExtension<PlatformBrandTheme> {
  const PlatformBrandTheme();

  @override
  PlatformBrandTheme copyWith() => this;

  @override
  PlatformBrandTheme lerp(covariant PlatformBrandTheme? other, double t) =>
      this;
}

/// Existing default artwork keeps its established tones. Custom companies
/// consume semantic theme roles instead of the bundled Uten palette.
Color brandAccent(ThemeData theme, Color defaultColor) =>
    theme.extension<PlatformBrandTheme>() == null
    ? defaultColor
    : theme.colorScheme.primary;

/// Derive readable roles for each brightness while retaining neutral surfaces,
/// typography, density and semantic error/success/warning colors. The selected
/// colors are seeds; Material tones keep text and controls readable.
ThemeData applyPlatformBrandTheme(ThemeData base, PlatformBranding branding) {
  if (branding.usesDefaultColors) return base;
  final primary = ColorScheme.fromSeed(
    seedColor: _hexColor(branding.primaryColor),
    brightness: base.brightness,
  );
  final secondary = ColorScheme.fromSeed(
    seedColor: _hexColor(branding.secondaryColor),
    brightness: base.brightness,
  );
  final scheme = base.colorScheme.copyWith(
    primary: primary.primary,
    onPrimary: primary.onPrimary,
    primaryContainer: primary.primaryContainer,
    onPrimaryContainer: primary.onPrimaryContainer,
    secondary: secondary.primary,
    onSecondary: secondary.onPrimary,
    secondaryContainer: secondary.primaryContainer,
    onSecondaryContainer: secondary.onPrimaryContainer,
    tertiary: secondary.primary,
    onTertiary: secondary.onPrimary,
    tertiaryContainer: secondary.primaryContainer,
    onTertiaryContainer: secondary.onPrimaryContainer,
    inversePrimary: primary.inversePrimary,
    surfaceTint: primary.primary,
  );
  ButtonStyle? solid(ButtonStyle? style) => style?.copyWith(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? style.backgroundColor?.resolve(states)
          : scheme.primary,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? style.foregroundColor?.resolve(states)
          : scheme.onPrimary,
    ),
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => scheme.onPrimary.withValues(
        alpha: states.contains(WidgetState.pressed) ? 0.10 : 0.08,
      ),
    ),
  );
  final focusedBorder = base.inputDecorationTheme.focusedBorder;
  return base.copyWith(
    extensions: [...base.extensions.values, const PlatformBrandTheme()],
    colorScheme: scheme,
    primaryColor: scheme.primary,
    primaryColorLight: scheme.primaryContainer,
    primaryColorDark: scheme.onPrimaryContainer,
    textSelectionTheme: base.textSelectionTheme.copyWith(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.25),
      selectionHandleColor: scheme.primary,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: solid(base.elevatedButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: solid(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        overlayColor: WidgetStatePropertyAll(
          scheme.primary.withValues(alpha: 0.08),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withValues(alpha: 0.38)
              : scheme.primary,
        ),
        overlayColor: WidgetStatePropertyAll(
          scheme.primary.withValues(alpha: 0.08),
        ),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      focusedBorder: focusedBorder is OutlineInputBorder
          ? focusedBorder.copyWith(
              borderSide: BorderSide(color: scheme.primary, width: 2),
            )
          : focusedBorder,
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final original = base.navigationBarTheme.labelTextStyle?.resolve(
          states,
        );
        return states.contains(WidgetState.selected)
            ? original?.copyWith(color: scheme.primary)
            : original;
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final original = base.navigationBarTheme.iconTheme?.resolve(states);
        return states.contains(WidgetState.selected)
            ? original?.copyWith(color: scheme.onPrimaryContainer)
            : original;
      }),
    ),
    navigationRailTheme: base.navigationRailTheme.copyWith(
      indicatorColor: scheme.primaryContainer,
      selectedIconTheme: base.navigationRailTheme.selectedIconTheme?.copyWith(
        color: scheme.onPrimaryContainer,
      ),
      selectedLabelTextStyle: base.navigationRailTheme.selectedLabelTextStyle
          ?.copyWith(color: scheme.primary),
    ),
    chipTheme: base.chipTheme.copyWith(
      selectedColor: scheme.secondaryContainer,
    ),
    progressIndicatorTheme: base.progressIndicatorTheme.copyWith(
      color: scheme.primary,
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
    ),
    switchTheme: base.switchTheme.copyWith(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : base.switchTheme.thumbColor?.resolve(states),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : base.switchTheme.trackColor?.resolve(states),
      ),
    ),
    checkboxTheme: base.checkboxTheme.copyWith(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : base.checkboxTheme.fillColor?.resolve(states),
      ),
      checkColor: WidgetStatePropertyAll(scheme.onPrimary),
    ),
    radioTheme: base.radioTheme.copyWith(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : base.radioTheme.fillColor?.resolve(states),
      ),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
  );
}
