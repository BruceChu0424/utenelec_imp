import 'package:flutter/material.dart';

import 'uten_tokens.dart';
import '../responsive/compact_presentation.dart';
import '../responsive/display_zoom.dart';

/// Applies the same target geometry to native Material controls and UtenButton.
/// This lives below application zoom so a user's smaller display preference
/// cannot reduce physical touch targets below their accessible minimum.
class UtenControlTheme extends StatelessWidget {
  const UtenControlTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = UtenCompactPresentation.of(context);
    final text = theme.textTheme;
    TextStyle? sized(TextStyle? style, double size) =>
        style?.copyWith(fontSize: size);
    final extent = UtenControlMetrics.minimumHitExtent(context);
    final fieldHeight = UtenPageField.heightOf(context);
    final fieldLineHeight = compact ? 14 * (text.bodyLarge?.height ?? 1.5) : 24;
    ButtonStyle control(ButtonStyle? style, {bool icon = false}) =>
        (style ?? const ButtonStyle()).copyWith(
          minimumSize: WidgetStatePropertyAll(
            Size.square(
              compact && !icon && UtenDisplayScale.fontZoomOf(context) >= 1
                  ? 36
                  : extent,
            ),
          ),
          tapTargetSize: compact && !icon
              ? MaterialTapTargetSize.padded
              : style?.tapTargetSize,
          textStyle: compact && !icon
              ? WidgetStatePropertyAll(text.labelLarge?.copyWith(fontSize: 13))
              : style?.textStyle,
          visualDensity: VisualDensity.standard,
          padding: compact
              ? const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                )
              : style?.padding,
        );
    return Theme(
      data: theme.copyWith(
        textTheme: compact
            ? text.copyWith(
                displayLarge: sized(text.displayLarge, 36),
                displayMedium: sized(text.displayMedium, 28),
                displaySmall: sized(text.displaySmall, 24),
                headlineLarge: sized(text.headlineLarge, 22),
                headlineMedium: sized(text.headlineMedium, 20),
                headlineSmall: sized(text.headlineSmall, 18),
                titleLarge: sized(text.titleLarge, 16),
                titleMedium: sized(text.titleMedium, 15),
                bodyLarge: sized(text.bodyLarge, 14),
              )
            : text,
        appBarTheme: compact
            ? theme.appBarTheme.copyWith(
                titleTextStyle: sized(theme.appBarTheme.titleTextStyle, 16),
              )
            : theme.appBarTheme,
        listTileTheme: compact
            ? theme.listTileTheme.copyWith(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                minVerticalPadding: 6,
              )
            : theme.listTileTheme,
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          hintStyle: compact
              ? sized(theme.inputDecorationTheme.hintStyle, 14)
              : theme.inputDecorationTheme.hintStyle,
          labelStyle: compact
              ? sized(theme.inputDecorationTheme.labelStyle, 14)
              : theme.inputDecorationTheme.labelStyle,
          // Desktop adaptive density subtracts 8px from a plain outline while
          // icon slots retain their 44px minimum. Form geometry owns its density;
          // table/filter hosts override this with their own compact roles.
          visualDensity: VisualDensity.standard,
          isDense: true,
          constraints: BoxConstraints(minHeight: fieldHeight),
          contentPadding: EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            // A plain field has no icon slot to establish its painted outline.
            // Keep its content tall enough for the touch target as well.
            vertical: (fieldHeight - fieldLineHeight) / 2,
          ),
          prefixIconConstraints: BoxConstraints(
            minWidth: fieldHeight,
            minHeight: fieldHeight,
          ),
          suffixIconConstraints: BoxConstraints(
            minWidth: fieldHeight,
            minHeight: fieldHeight,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: control(theme.elevatedButtonTheme.style),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: control(theme.filledButtonTheme.style),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: control(theme.outlinedButtonTheme.style),
        ),
        textButtonTheme: TextButtonThemeData(
          style: control(theme.textButtonTheme.style),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: control(theme.iconButtonTheme.style, icon: true),
        ),
      ),
      child: UtenCompactPresentationScope(
        iconSearch: compact,
        auxiliaryIcons: compact,
        child: child,
      ),
    );
  }
}
