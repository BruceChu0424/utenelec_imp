import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/data_write_revision.dart';
import '../providers/export_context_epoch_provider.dart';

/// A shared producer replaces caller intent with its own monotonic boundary,
/// including the interval before a dependency rebuild delivers onDispose.
bool Function() captureSharedReadProviderOwner(Ref ref) {
  final epoch = ref.watch(exportContextEpochProvider);
  final write = ref.watch(dataWriteRevisionProvider);
  return () =>
      ref.mounted &&
      epoch == ref.read(exportContextEpochProvider) &&
      write == ref.read(dataWriteRevisionProvider);
}
