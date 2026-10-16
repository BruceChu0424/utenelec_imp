import 'package:flutter/material.dart';

import 'uten_tokens.dart';

/// Applies the same target geometry to native Material controls and UtenButton.
/// This lives below application zoom so a user's smaller display preference
/// cannot reduce physical touch targets below their accessible minimum.
class UtenControlTheme extends StatelessWidget {
  const UtenControlTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final extent = UtenControlMetrics.minimumHitExtent(context);
    final fieldHeight = UtenPageField.heightOf(context);
    ButtonStyle control(ButtonStyle? style) =>
        (style ?? const ButtonStyle()).copyWith(
          minimumSize: WidgetStatePropertyAll(Size.square(extent)),
          visualDensity: VisualDensity.standard,
        );
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
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
            vertical: (fieldHeight - 24) / 2,
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
          style: control(theme.iconButtonTheme.style),
        ),
      ),
      child: child,
    );
  }
}
