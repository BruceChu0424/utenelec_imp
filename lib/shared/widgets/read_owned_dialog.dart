import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../components/feedback/uten_dialog.dart';
import '../auth/read_owner_fence.dart';
import '../providers/export_context_epoch_provider.dart';

/// A frozen read-only evidence dialog belongs to the reader that opened it.
/// Remove that exact route, and never let its late result command a newer view.
Future<R?> showReadOwnedDialog<R>({
  required WidgetRef ref,
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final current = captureReadOwner(ref);
  ModalRoute<dynamic>? owned;
  final subscription = ref.listenManual(exportContextEpochProvider, (_, next) {
    if (current()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = owned;
      if (route != null && route.isActive) route.navigator?.removeRoute(route);
    });
  });
  try {
    if (!current()) return null;
    final result = await UtenDialog.showAndWaitForExit<R>(
      context,
      barrierDismissible: barrierDismissible,
      builder: (dialog) {
        owned = ModalRoute.of(dialog);
        if (!current()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final route = owned;
            if (route != null && route.isActive) {
              route.navigator?.removeRoute(route);
            }
          });
          return const SizedBox.shrink();
        }
        return builder(dialog);
      },
    );
    return current() ? result : null;
  } finally {
    subscription.close();
  }
}
