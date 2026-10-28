import 'package:flutter/widgets.dart';

/// Dialog footer presentation only; business callbacks remain caller-owned.
class UtenDialogActionScope extends InheritedWidget {
  const UtenDialogActionScope({super.key, required super.child});

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenDialogActionScope>() !=
      null;

  @override
  bool updateShouldNotify(UtenDialogActionScope oldWidget) => false;
}
