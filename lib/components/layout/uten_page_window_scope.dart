import 'package:flutter/widgets.dart';

/// The application decides which pages can open an independent window.
/// App bars only present the contributed action, including their narrow menu.
class UtenPageWindowScope extends InheritedWidget {
  const UtenPageWindowScope({
    super.key,
    required this.actionBuilder,
    required super.child,
  });

  final Widget? Function(BuildContext context, String? title) actionBuilder;

  static UtenPageWindowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenPageWindowScope>();

  @override
  bool updateShouldNotify(UtenPageWindowScope oldWidget) =>
      actionBuilder != oldWidget.actionBuilder;
}
