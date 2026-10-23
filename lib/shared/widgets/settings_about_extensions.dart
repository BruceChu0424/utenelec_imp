import 'package:flutter/widgets.dart';

/// Application-supplied entries for the settings About section.
///
/// Feature modules supply their own widgets at the application composition
/// root, so settings does not depend on another feature's private UI.
class SettingsAboutExtensions extends InheritedWidget {
  const SettingsAboutExtensions({
    super.key,
    required this.entries,
    required super.child,
  });

  final List<Widget> entries;

  static List<Widget> of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SettingsAboutExtensions>()
          ?.entries ??
      const <Widget>[];

  @override
  bool updateShouldNotify(SettingsAboutExtensions oldWidget) =>
      entries != oldWidget.entries;
}
