import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

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

/// Adapt native page actions while preserving their focus, state and callbacks.
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
         style: null,
         focusNode: source.focusNode,
         autofocus: source.autofocus,
         clipBehavior: source.clipBehavior,
         statesController: source.statesController,
         isSemanticButton: source.isSemanticButton,
         tooltip: source.tooltip,
         child: _UtenAppBarActionLabel(source.child),
       );

  final ButtonStyleButton source;

  @override
  ButtonStyle defaultStyleOf(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final height = UtenFilterRow.heightOf(context);
    return source
        .defaultStyleOf(context)
        .merge(
          FilledButton.styleFrom(
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
            shape: const RoundedRectangleBorder(
              borderRadius: UtenRadius.controlAll,
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        );
  }

  @override
  ButtonStyle? themeStyleOf(BuildContext context) => null;
}

/// Resolve Material .icon composition in a widget build context. The labels
/// remain real widgets, so localization, badges and inherited styles survive.
class _UtenAppBarActionLabel extends StatelessWidget {
  const _UtenAppBarActionLabel(this.child);

  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      _textOnlyChild(child, context) ?? const SizedBox.shrink();

  Widget? _textOnlyChild(Widget? child, BuildContext context) {
    // Material's .icon factories compose a private StatelessWidget around the
    // public label. Build that composition, then retain its public label tree.
    // The action's state and callback still belong to the original button.
    if (child is StatelessWidget &&
        child.runtimeType.toString().endsWith('ButtonWithIconChild')) {
      return _textOnlyChild(child.build(context), context);
    }
    if (child is Row && child.children.any((child) => child is Icon)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in child.children)
            if (entry is! Icon && entry is! SizedBox) entry,
        ],
      );
    }
    return child;
  }
}
