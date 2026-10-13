import 'package:flutter/material.dart';

/// One type scale for both brightnesses. Business values use bodyMedium;
/// normal prose and form input use bodyLarge, and captions use bodySmall.
TextTheme buildUtenTextTheme({
  required Color primary,
  required Color secondary,
  required Color tertiary,
}) {
  TextStyle text(double size, FontWeight weight, Color color, double height) =>
      TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
      );
  return TextTheme(
    displayLarge: text(48, FontWeight.w700, primary, 1.15),
    displayMedium: text(36, FontWeight.w700, primary, 1.2),
    displaySmall: text(28, FontWeight.w700, primary, 1.25),
    headlineLarge: text(24, FontWeight.w600, primary, 1.35),
    headlineMedium: text(22, FontWeight.w600, primary, 1.4),
    headlineSmall: text(20, FontWeight.w600, primary, 1.4),
    titleLarge: text(18, FontWeight.w600, primary, 1.4),
    titleMedium: text(16, FontWeight.w600, primary, 1.4),
    titleSmall: text(14, FontWeight.w600, primary, 1.4),
    bodyLarge: text(16, FontWeight.w400, primary, 1.5),
    bodyMedium: text(14, FontWeight.w400, primary, 1.5),
    bodySmall: text(13, FontWeight.w400, secondary, 1.5),
    labelLarge: text(14, FontWeight.w600, primary, 1.4),
    labelMedium: text(13, FontWeight.w500, secondary, 1.4),
    labelSmall: text(13, FontWeight.w400, tertiary, 1.4),
  );
}
