import 'package:flutter/material.dart';

import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_overlay_lifecycle.dart';

/// One waiting surface for notice actions, including delayed banner callbacks.
/// The source route owns visibility; hiding it never cancels or replays a write.
Future<T> runNoticeActionWithBusy<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function() action,
}) async {
  // Delayed arrival actions retain the root Navigator's context, which owns
  // its Overlay below itself rather than having one as an ancestor.
  final overlay =
      Overlay.maybeOf(context, rootOverlay: true) ??
      Navigator.maybeOf(context, rootNavigator: true)?.overlay;
  if (overlay == null) throw StateError('通知操作缺少加载弹层入口');
  OverlayEntry? host;
  void removeHost() {
    final entry = host;
    host = null;
    entry?.remove();
    entry?.dispose();
  }

  final lifecycle = UtenOverlayLifecycle(
    transient: false,
    onUnavailable: removeHost,
    onAvailable: () {
      if (!overlay.mounted || host != null) return;
      final entry = OverlayEntry(
        builder: (_) =>
            UtenBusyOverlay(title: title, showDoNotLeaveHint: false),
      );
      host = entry;
      overlay.insert(entry);
    },
  );
  lifecycle.attach(context);
  try {
    return await action();
  } finally {
    lifecycle.dispose();
    removeHost();
  }
}
