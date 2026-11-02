import 'package:flutter/widgets.dart';

import 'display_zoom.dart';

/// Presentation density follows the real window, independently of the user's
/// selected zoom. Large desktop text must not silently select the phone theme.
abstract final class UtenCompactPresentation {
  /// One application-level choice shared by toolbars, export and print.
  /// Embedded controls outside the application keep their explicit labels.
  static bool auxiliaryIconsOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenCompactPresentationScope>()
          ?.auxiliaryIcons ??
      false;
  static bool iconSearchOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenCompactPresentationScope>()
          ?.iconSearch ??
      false;
  static bool of(BuildContext context) =>
      (UtenDisplayScale.maybeOf(context)?.window.width ??
          MediaQuery.sizeOf(context).width) <
      840;

  static EdgeInsets padding(BuildContext context, EdgeInsetsGeometry source) {
    final resolved = source.resolve(Directionality.of(context));
    if (!of(context)) return resolved;
    double inset(double value) => value > 12 ? value * .75 : value;
    return EdgeInsets.fromLTRB(
      inset(resolved.left),
      inset(resolved.top),
      inset(resolved.right),
      inset(resolved.bottom),
    );
  }
}

class UtenCompactPresentationScope extends InheritedWidget {
  const UtenCompactPresentationScope({
    super.key,
    required this.iconSearch,
    this.auxiliaryIcons = false,
    required super.child,
  });
  final bool iconSearch;
  final bool auxiliaryIcons;
  @override
  bool updateShouldNotify(UtenCompactPresentationScope oldWidget) =>
      iconSearch != oldWidget.iconSearch ||
      auxiliaryIcons != oldWidget.auxiliaryIcons;
}
