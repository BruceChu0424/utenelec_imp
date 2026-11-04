import 'package:flutter/widgets.dart';

/// Table toolbar buttons share one visual size. The scope wraps actions only,
/// leaving table cells, document forms and transient dialogs independent.
class UtenTableActionScope extends InheritedWidget {
  const UtenTableActionScope({super.key, required super.child});

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenTableActionScope>() !=
      null;

  @override
  bool updateShouldNotify(UtenTableActionScope oldWidget) => false;
}
