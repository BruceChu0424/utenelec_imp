import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/router/page_navigation_session.dart';

/// UI projection of the application's monotonic authenticated-reader epoch.
/// Components receive an opaque identity and never decide business access.
class UtenActionOwnerScope extends InheritedWidget {
  const UtenActionOwnerScope({
    super.key,
    required this.identity,
    required super.child,
  });
  final Object identity;

  static Object? identityOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<UtenActionOwnerScope>()?.identity;

  @override
  bool updateShouldNotify(UtenActionOwnerScope oldWidget) =>
      identity != oldWidget.identity;
}

/// Flat full-width rows inside the project-owned action dropdown.
class UtenMenuActionPresentation extends InheritedWidget {
  const UtenMenuActionPresentation({
    super.key,
    required this.enabled,
    required super.child,
  });
  final bool enabled;
  static bool contains(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenMenuActionPresentation>()
          ?.enabled ??
      false;
  @override
  bool updateShouldNotify(UtenMenuActionPresentation oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Page-header actions keep their labels visible and use a single button role.
/// This also reaches action widgets that build their UtenButton internally.
class UtenAppBarActionPresentation extends InheritedWidget {
  const UtenAppBarActionPresentation({super.key, required super.child});

  static bool contains(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenAppBarActionPresentation>() !=
      null;

  @override
  bool updateShouldNotify(UtenAppBarActionPresentation oldWidget) => false;
}

/// Presentation-only action ownership. It never supplies permissions or data.
/// Stateful asynchronous controls may retain their lifetime until completion;
/// navigation controls use the original page context and close before acting.
class UtenAppBarActionScope extends InheritedWidget {
  const UtenAppBarActionScope({
    super.key,
    required this.actionContext,
    required this.claimAction,
    required this.dismiss,
    required this.isCurrent,
    this.navigation,
    this.closeBeforeAction = false,
    this.transient = true,
    required super.child,
  });

  final BuildContext actionContext;
  final bool Function() claimAction;
  final VoidCallback dismiss;
  final bool Function() isCurrent;
  final PageNavigationSession? navigation;
  final bool closeBeforeAction;
  final bool transient;

  static BuildContext actionContextOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenAppBarActionScope>()
          ?.actionContext ??
      context;

  /// Navigation waits belong to the source header, not its temporary panel.
  static PageNavigationSession? navigationOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<UtenAppBarActionScope>()
      ?.navigation;

  static Widget withCloseBeforeAction(
    BuildContext context, {
    required Widget child,
  }) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<UtenAppBarActionScope>();
    if (scope == null) return child;
    return UtenAppBarActionScope(
      actionContext: scope.actionContext,
      claimAction: scope.claimAction,
      dismiss: scope.dismiss,
      isCurrent: scope.isCurrent,
      navigation: scope.navigation,
      closeBeforeAction: true,
      transient: scope.transient,
      child: child,
    );
  }

  static VoidCallback? wrapBefore(
    BuildContext context,
    FutureOr<void> Function()? callback,
  ) {
    if (callback == null) return null;
    final scope = context
        .dependOnInheritedWidgetOfExactType<UtenAppBarActionScope>();
    if (scope == null) return () => callback();
    if (!scope.transient) {
      return () {
        if (scope.claimAction()) callback();
      };
    }
    return wrapOwnedBefore(
      owner: scope.actionContext,
      claimAction: scope.claimAction,
      dismiss: scope.dismiss,
      isCurrent: scope.isCurrent,
      callback: callback,
    );
  }

  /// Shared by native and Uten controls; the source owner survives its panel.
  static VoidCallback? wrapOwnedBefore({
    required BuildContext owner,
    required bool Function() claimAction,
    required VoidCallback dismiss,
    required bool Function() isCurrent,
    required FutureOr<void> Function()? callback,
  }) {
    if (callback == null) return null;
    return () async {
      if (!owner.mounted || !claimAction()) return;
      final identity = UtenActionOwnerScope.identityOf(owner);
      dismiss();
      await WidgetsBinding.instance.endOfFrame;
      if (!owner.mounted ||
          !isCurrent() ||
          identity != UtenActionOwnerScope.identityOf(owner)) {
        return;
      }
      await callback();
    };
  }

  static VoidCallback? wrap(
    BuildContext context,
    FutureOr<void> Function()? callback,
  ) {
    if (callback == null) return null;
    final scope = context
        .dependOnInheritedWidgetOfExactType<UtenAppBarActionScope>();
    if (scope == null) return () => callback();
    if (scope.closeBeforeAction) {
      return wrapBefore(context, callback);
    }
    return () {
      if (!scope.claimAction()) return;
      // FutureOr is explicit here: no dynamic inspection of void callbacks.
      unawaited(Future<void>.sync(callback).whenComplete(scope.dismiss));
    };
  }

  @override
  bool updateShouldNotify(UtenAppBarActionScope oldWidget) =>
      actionContext != oldWidget.actionContext ||
      navigation != oldWidget.navigation ||
      closeBeforeAction != oldWidget.closeBeforeAction ||
      transient != oldWidget.transient ||
      isCurrent != oldWidget.isCurrent ||
      claimAction != oldWidget.claimAction ||
      dismiss != oldWidget.dismiss;
}

/// Adapt native page actions while preserving their focus, state and callbacks.
class UtenAppBarNativeActionButton extends ButtonStyleButton {
  UtenAppBarNativeActionButton({
    Key? key,
    required this.source,
    required super.onPressed,
    required super.onLongPress,
    Widget? label,
  }) : super(
         key: key ?? source.key,
         onHover: source.onHover,
         onFocusChange: source.onFocusChange,
         style: null,
         focusNode: source.focusNode,
         autofocus: source.autofocus,
         clipBehavior: source.clipBehavior,
         statesController: source.statesController,
         isSemanticButton: source.isSemanticButton,
         tooltip: source.tooltip,
         child: label ?? source.child,
       );

  /// Native .icon factories keep their label inside private Flutter widgets.
  /// Supply the public label explicitly when adapting one, or use a native
  /// button with a plain child. Runtime type names are minified in release Web.
  final ButtonStyleButton source;

  @override
  ButtonStyle defaultStyleOf(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final inMenu = UtenMenuActionPresentation.contains(context);
    final height = UtenFilterRow.heightOf(context);
    // Override the header role explicitly. merge only fills null fields, while
    // a styleFrom mouse-cursor property may itself resolve to null; retain the
    // native interaction defaults instead of replacing that state property.
    final header = FilledButton.styleFrom(
      alignment: inMenu ? AlignmentDirectional.centerStart : null,
      backgroundColor: inMenu ? colors.surface : colors.primary,
      foregroundColor: inMenu ? colors.onSurface : colors.onPrimary,
      disabledBackgroundColor: colors.surfaceContainerHigh,
      disabledForegroundColor: colors.onSurfaceVariant,
      elevation: 0,
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: Size(height, height),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.controlAll),
      textStyle: (Theme.of(context).textTheme.labelLarge ?? const TextStyle())
          .copyWith(fontSize: 14, fontWeight: FontWeight.w600, height: 1.2),
    );
    return source
        .defaultStyleOf(context)
        .copyWith(
          alignment: header.alignment,
          backgroundColor: header.backgroundColor,
          foregroundColor: header.foregroundColor,
          elevation: header.elevation,
          side: header.side,
          padding: header.padding,
          minimumSize: header.minimumSize,
          tapTargetSize: header.tapTargetSize,
          visualDensity: header.visualDensity,
          shape: header.shape,
          textStyle: header.textStyle,
        );
  }

  @override
  ButtonStyle? themeStyleOf(BuildContext context) => null;
}
