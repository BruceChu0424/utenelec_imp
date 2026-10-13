import 'dart:async';

import 'package:flutter/material.dart';

/// Presentation-only action ownership. It never supplies permissions or data.
/// Stateful asynchronous controls may retain their lifetime until completion;
/// navigation controls use the original page context and close before acting.
class UtenAppBarActionScope extends InheritedWidget {
  const UtenAppBarActionScope({
    super.key,
    required this.actionContext,
    required this.claimAction,
    required this.dismiss,
    this.closeBeforeAction = false,
    required super.child,
  });

  final BuildContext actionContext;
  final bool Function() claimAction;
  final VoidCallback dismiss;
  final bool closeBeforeAction;

  static BuildContext actionContextOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenAppBarActionScope>()
          ?.actionContext ??
      context;

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
      closeBeforeAction != oldWidget.closeBeforeAction;
}

/// Keep the native style button's defaults, including filled/tonal styles.
class UtenAppBarNativeActionButton extends ButtonStyleButton {
  UtenAppBarNativeActionButton({
    Key? key,
    required this.source,
    required super.onPressed,
    required super.onLongPress,
  }) : super(
         key: key ?? source.key,
         onHover: source.onHover,
         onFocusChange: source.onFocusChange,
         style: source.style,
         focusNode: source.focusNode,
         autofocus: source.autofocus,
         clipBehavior: source.clipBehavior,
         statesController: source.statesController,
         isSemanticButton: source.isSemanticButton,
         tooltip: source.tooltip,
         child: source.child,
       );

  final ButtonStyleButton source;

  @override
  ButtonStyle defaultStyleOf(BuildContext context) =>
      source.defaultStyleOf(context);

  @override
  ButtonStyle? themeStyleOf(BuildContext context) =>
      source.themeStyleOf(context);
}
