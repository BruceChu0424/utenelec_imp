import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';

/// The route mounts controllers and access subscriptions immediately. Heavy
/// view regions wait for the composited opening transition to finish.
class UtenPanelOpeningScope extends InheritedWidget {
  const UtenPanelOpeningScope({
    super.key,
    required this.ready,
    required super.child,
  });

  final bool ready;

  static bool isReadyOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenPanelOpeningScope>()
          ?.ready ??
      true;

  @override
  bool updateShouldNotify(UtenPanelOpeningScope oldWidget) =>
      ready != oldWidget.ready;
}

class UtenPanelDeferredView extends StatelessWidget {
  const UtenPanelDeferredView({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => UtenPanelOpeningScope.isReadyOf(context)
      ? builder(context)
      : const UtenPanelOpeningPlaceholder();
}

class UtenPanelOpeningPlaceholder extends StatelessWidget {
  const UtenPanelOpeningPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      child: Text(
        Localizations.of<AppLocalizations>(
              context,
              AppLocalizations,
            )?.commonLoading ??
            '加载中…',
      ),
    ),
  );
}
