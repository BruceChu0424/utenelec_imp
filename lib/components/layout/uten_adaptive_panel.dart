import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';

/// Opens a Uten panel as a bottom sheet on compact screens and an end drawer
/// on wider screens.
///
/// The function owns only the responsive presentation shell. Loading,
/// selection drafts, validation, cancel and confirm behavior remain inside
/// [builder].
Future<T?> showUtenAdaptivePanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double compactHeightFactor = 0.85,
  double drawerWidth = 420,
  bool barrierDismissible = true,
  bool useSafeArea = true,
  bool showDragHandle = false,
  String? barrierLabel,
  Color barrierColor = Colors.black54,
  Duration transitionDuration = const Duration(milliseconds: 250),
}) {
  assert(compactHeightFactor > 0 && compactHeightFactor <= 1);
  assert(drawerWidth > 0);

  final resolvedBarrierLabel =
      barrierLabel ??
      MaterialLocalizations.of(context).modalBarrierDismissLabel;

  if (context.breakpoint.isCompact) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(UtenRadius.lg)),
    );
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: barrierDismissible,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      barrierLabel: resolvedBarrierLabel,
      barrierColor: barrierColor,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        final visibleHeight = math.max(
          0.0,
          mediaQuery.size.height - mediaQuery.viewInsets.bottom,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
          child: SizedBox(
            height: visibleHeight * compactHeightFactor,
            child: builder(sheetContext),
          ),
        );
      },
    );
  }

  final isRtl = Directionality.of(context) == TextDirection.rtl;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: resolvedBarrierLabel,
    barrierColor: barrierColor,
    transitionDuration: transitionDuration,
    pageBuilder: (dialogContext, _, _) {
      Widget content = builder(dialogContext);
      if (useSafeArea) {
        content = SafeArea(left: false, child: content);
      }
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Material(
          color: Theme.of(dialogContext).colorScheme.surface,
          child: SizedBox(
            width: drawerWidth,
            height: double.infinity,
            child: content,
          ),
        ),
      );
    },
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: Offset(isRtl ? -1 : 1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}
