import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/router/page_navigation_session.dart';

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
    this.navigation,
    this.closeBeforeAction = false,
    required super.child,
  });

  final BuildContext actionContext;
  final bool Function() claimAction;
  final VoidCallback dismiss;
  final PageNavigationSession? navigation;
  final bool closeBeforeAction;

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
      navigation: scope.navigation,
      closeBeforeAction: true,
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
    return () {
      if (scope != null) {
        if (!scope.claimAction()) return;
        scope.dismiss();
      }
      callback();
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
      return () {
        if (!scope.claimAction()) return;
        scope.dismiss();
        callback();
      };
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
    final height = UtenFilterRow.heightOf(context);
    // Override the header role explicitly. merge only fills null fields, while
    // a styleFrom mouse-cursor property may itself resolve to null; retain the
    // native interaction defaults instead of replacing that state property.
    final header = FilledButton.styleFrom(
      backgroundColor: colors.primary,
      foregroundColor: colors.onPrimary,
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
