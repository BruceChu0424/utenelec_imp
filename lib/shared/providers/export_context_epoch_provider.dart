import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/server_config.dart';
import '../auth/permissions.dart';
import 'authenticated_scope_provider.dart';

/// Persistent, monotonic fence; returning to a former identity cannot revive old work.
class ExportContextEpoch extends Notifier<int> {
  @override
  int build() {
    ref.listen(authenticatedScopeProvider, (previous, next) {
      if (previous != next) state++;
    });
    ref.listen(apiBaseUrlProvider, (previous, next) {
      if (previous != next) state++;
    });
    ref.listen(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) state++;
    });
    return 0;
  }
}

final exportContextEpochProvider = NotifierProvider<ExportContextEpoch, int>(
  ExportContextEpoch.new,
);
