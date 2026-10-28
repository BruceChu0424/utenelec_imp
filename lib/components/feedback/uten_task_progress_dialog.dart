import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'uten_dialog.dart';

/// Keeps an awaited operation visible and prevents accidental duplicate actions.
/// The exact route is removed on completion, including when the caller leaves.
Future<T> runUtenBlockingTask<T>({
  required BuildContext context,
  required String title,
  required Future<T> Function() task,
  bool Function()? isCurrent,
  Listenable? invalidation,
  ValueChanged<ModalRoute<void>>? onRouteCreated,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        PopScope(canPop: false, child: UtenTaskProgressDialog(title: title)),
  );
  void dismissIfInvalidated() {
    // Identity notifications may run while a widget is building.
    scheduleMicrotask(() {
      if (isCurrent != null &&
          !isCurrent() &&
          navigator.mounted &&
          route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  onRouteCreated?.call(route);
  navigator.push(route);
  invalidation?.addListener(dismissIfInvalidated);
  try {
    // Paint the busy state before starting work, including synchronous encoding.
    await WidgetsBinding.instance.endOfFrame;
    if (isCurrent != null && !isCurrent()) {
      throw StateError('操作已取消，请重新操作');
    }
    return await task();
  } finally {
    invalidation?.removeListener(dismissIfInvalidated);
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  }
}

class UtenTaskProgressDialog extends StatelessWidget {
  const UtenTaskProgressDialog({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => UtenAlertDialog(
    maxWidth: 420,
    content: Row(
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(width: UtenSpacing.s20),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
      ],
    ),
  );
}
