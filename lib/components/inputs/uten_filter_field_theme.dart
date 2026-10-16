import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'uten_table_cell_spec.dart';

/// Search/filter fields share the search bar's role, independently of forms.
///
/// This scope supplies minimum geometry only: large text can grow naturally.
/// Table hosts keep their own compact role even when nested in a filter scope.
class UtenFilterFieldTheme extends StatelessWidget {
  const UtenFilterFieldTheme({super.key, required this.child});

  final Widget child;

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_UtenFilterFieldScope>() !=
      null;

  @override
  Widget build(BuildContext context) {
    if (UtenTableCellInputTheme.contains(context)) return child;
    final theme = Theme.of(context);
    final height = UtenFilterRow.heightOf(context);
    final decoration = theme.inputDecorationTheme;
    // Generic Material themes otherwise use an underline with a different
    // floating-label layout. Filters own the same outline as the search bar.
    OutlineInputBorder filterBorder(
      InputBorder? border, {
      Color? color,
      double width = 1,
    }) => OutlineInputBorder(
      borderRadius: UtenFilterRow.borderRadius,
      borderSide:
          border?.borderSide ??
          BorderSide(color: color ?? theme.colorScheme.outline, width: width),
    );
    return _UtenFilterFieldScope(
      child: Theme(
        data: theme.copyWith(
          inputDecorationTheme: decoration.copyWith(
            // Density belongs to the field outline, never neighbouring commands.
            visualDensity: UtenControlMetrics.usesTouchTargets(context)
                ? VisualDensity.standard
                : VisualDensity.compact,
            isDense: true,
            constraints: BoxConstraints(minHeight: height),
            contentPadding: UtenFilterRow.contentPadding,
            prefixIconConstraints: BoxConstraints(
              minWidth: height,
              minHeight: height,
            ),
            suffixIconConstraints: BoxConstraints(
              minWidth: height,
              minHeight: height,
            ),
            border: filterBorder(decoration.border),
            enabledBorder: filterBorder(decoration.enabledBorder),
            focusedBorder: filterBorder(
              decoration.focusedBorder,
              color: theme.colorScheme.primary,
              width: 2,
            ),
            disabledBorder: filterBorder(
              decoration.disabledBorder,
              color: theme.disabledColor,
            ),
            errorBorder: filterBorder(
              decoration.errorBorder,
              color: theme.colorScheme.error,
            ),
            focusedErrorBorder: filterBorder(
              decoration.focusedErrorBorder,
              color: theme.colorScheme.error,
              width: 2,
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}

class _UtenFilterFieldScope extends InheritedWidget {
  const _UtenFilterFieldScope({required super.child});

  @override
  bool updateShouldNotify(_UtenFilterFieldScope oldWidget) => false;
}
