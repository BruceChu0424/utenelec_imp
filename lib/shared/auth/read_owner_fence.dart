import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/export_context_epoch_provider.dart';

/// A read's publication owner, including account/permission/server A-B-A.
/// This does not cancel transport or decide the outcome of a business command.
bool Function() captureReadOwner(WidgetRef ref) {
  final context = ref.context;
  final epoch = ref.read(exportContextEpochProvider);
  return () => context.mounted && ref.read(exportContextEpochProvider) == epoch;
}

/// Keep the monotonic epoch observed for the entire native page lifetime.
/// Riverpod closes this subscription when the consumer is disposed.
void listenReadOwner(WidgetRef ref, void Function() invalidate) {
  ref.listenManual(exportContextEpochProvider, (previous, next) {
    if (previous != next && ref.context.mounted) invalidate();
  });
}
