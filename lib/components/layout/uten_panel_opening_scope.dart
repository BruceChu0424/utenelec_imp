import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';

/// Mount controllers and access subscriptions immediately. Heavy view regions
/// wait for every containing route or panel's opening transition to finish.
/// A ready inner panel cannot release a view while its outer page is opening.
class UtenOpeningScope extends StatelessWidget {
  const UtenOpeningScope({super.key, required this.ready, required this.child});

  final bool ready;
  final Widget child;

  static bool isReadyOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_OpeningReadiness>()?.ready ??
      true;

  @override
  Widget build(BuildContext context) =>
      _OpeningReadiness(ready: ready && isReadyOf(context), child: child);
}

/// Compatibility name for existing panels and heavy table/tree consumers.
typedef UtenPanelOpeningScope = UtenOpeningScope;

class _OpeningReadiness extends InheritedWidget {
  const _OpeningReadiness({required this.ready, required super.child});

  final bool ready;

  @override
  bool updateShouldNotify(_OpeningReadiness oldWidget) =>
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
