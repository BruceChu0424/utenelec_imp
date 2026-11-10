import 'package:flutter/widgets.dart';

/// Chosen references in entry forms share one visual role. Only explicit form
/// owners opt in; report filters, historical facts and other pages keep theirs.
class UtenSelectedValueTheme extends InheritedWidget {
  const UtenSelectedValueTheme({super.key, required super.child});

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenSelectedValueTheme>() !=
      null;

  @override
  bool updateShouldNotify(UtenSelectedValueTheme oldWidget) => false;
}

extension UtenSelectedValuePresentation on Widget {
  Widget withSelectedValueHighlights() => UtenSelectedValueTheme(child: this);
}
