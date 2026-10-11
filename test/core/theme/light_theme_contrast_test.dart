import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

void main() {
  test('light theme action color pairs meet WCAG AA contrast', () {
    final colors = buildLightTheme().colorScheme;

    expect(
      _contrastRatio(colors.primary, colors.onPrimary),
      greaterThanOrEqualTo(4.5),
      reason: 'primary/onPrimary must remain readable for button labels',
    );
    expect(
      _contrastRatio(colors.error, colors.onError),
      greaterThanOrEqualTo(4.5),
      reason: 'error/onError must remain readable for destructive actions',
    );
  });

  test('focus and selected indicators meet non-text contrast', () {
    final theme = buildLightTheme();
    final focusedBorder =
        theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
    final tabIndicator = theme.tabBarTheme.indicator! as UnderlineTabIndicator;

    expect(
      _contrastRatio(focusedBorder.borderSide.color, theme.colorScheme.surface),
      greaterThanOrEqualTo(3),
    );
    expect(
      _contrastRatio(tabIndicator.borderSide.color, theme.colorScheme.surface),
      greaterThanOrEqualTo(3),
    );
  });
  test('legacy primary token remains readable on dark surfaces', () {
    expect(
      _contrastRatio(UtenColors.primary, UtenColors.darkSurface),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(UtenColors.primary, UtenColors.darkBackground),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('input suffix (数量单位后缀) uses primary text color in both themes', () {
    // 2026-10-10 用户口径：数量输入框的单位后缀（suffixText）用正文色——
    // 浅色=近黑、深色=近白，不吃 Material 默认的灰 onSurfaceVariant。
    final light = buildLightTheme().inputDecorationTheme;
    expect(light.suffixStyle?.color, UtenColors.textPrimary);
    final dark = buildDarkTheme().inputDecorationTheme;
    expect(dark.suffixStyle?.color, UtenColors.darkTextPrimary);
  });
}

double _contrastRatio(Color first, Color second) {
  final lighter = first.computeLuminance() > second.computeLuminance()
      ? first.computeLuminance()
      : second.computeLuminance();
  final darker = first.computeLuminance() > second.computeLuminance()
      ? second.computeLuminance()
      : first.computeLuminance();
  return (lighter + 0.05) / (darker + 0.05);
}
