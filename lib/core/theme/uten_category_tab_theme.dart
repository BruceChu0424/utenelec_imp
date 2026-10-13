import 'package:flutter/material.dart';

import 'uten_tokens.dart';

Decoration utenCategoryTabIndicator(ColorScheme colors) => BoxDecoration(
  color: colors.secondaryContainer,
  borderRadius: UtenFilterRow.borderRadius,
  border: Border.all(color: colors.outline),
);

TabBarThemeData buildUtenCategoryTabTheme(
  ColorScheme colors,
  TextTheme textTheme,
) => TabBarThemeData(
  labelColor: colors.onSecondaryContainer,
  unselectedLabelColor: colors.onSurface,
  labelStyle: textTheme.labelLarge?.copyWith(
    fontWeight: FontWeight.w600,
    color: colors.onSecondaryContainer,
  ),
  unselectedLabelStyle: textTheme.labelLarge?.copyWith(color: colors.onSurface),
  labelPadding: UtenFilterRow.contentPadding,
  indicator: utenCategoryTabIndicator(colors),
  indicatorSize: TabBarIndicatorSize.tab,
  dividerColor: Colors.transparent,
);
