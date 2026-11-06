import 'dart:async';

import 'package:flutter/material.dart';

import 'uten_busy_overlay.dart';

class _BlockingTaskSession {
  bool closed = false;
}

final _blockingTasks = Expando<_BlockingTaskSession>('uten-blocking-action');

/// Keeps an awaited operation visible and prevents accidental duplicate actions.
/// The exact route is removed on completion, including when the caller leaves.
Future<T> runUtenBlockingTask<T>({
  required BuildContext context,
  required String title,
  required Future<T> Function() task,
  bool Function()? isCurrent,
  Listenable? invalidation,
  ValueChanged<ModalRoute<void>>? onRouteCreated,
  Object? owner,
}) async {
  final existing = owner == null ? null : _blockingTasks[owner];
  if (existing != null && !existing.closed) {
    if (isCurrent != null && !isCurrent()) {
      throw StateError('操作已取消，请重新操作');
    }
    return await task();
  }
  final session = _BlockingTaskSession();
  if (owner != null) _blockingTasks[owner] = session;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
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
    // The route mounts first; its busy overlay inserts the root entry after
    // that frame. Paint that entry before work, including synchronous encoding.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (isCurrent != null && !isCurrent()) {
      throw StateError('操作已取消，请重新操作');
    }
    return await task();
  } finally {
    session.closed = true;
    if (owner != null && identical(_blockingTasks[owner], session)) {
      _blockingTasks[owner] = null;
    }
    invalidation?.removeListener(dismissIfInvalidated);
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  }
}

class UtenTaskProgressDialog extends StatelessWidget {
  const UtenTaskProgressDialog({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) =>
      UtenBusyOverlay(title: title, showDoNotLeaveHint: false);
}
