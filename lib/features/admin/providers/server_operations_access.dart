import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/server_config.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_snapshot_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';

/// Local facts fence responses; the server's can* fields still authorize actions.
final serverOperationsOwnerProvider = Provider<Object?>((ref) {
  final scope = ref.watch(authenticatedScopeProvider);
  final server = ref.watch(apiBaseUrlProvider);
  final snapshot = confirmedSessionSnapshot(ref.watch(sessionSnapshotProvider));
  return scope == null ? null : (scope, server, snapshot?.generation);
});

final serverOperationsVisibleProvider = Provider<bool>((ref) {
  final permissions = ref.watch(currentPermissionsProvider);
  return ref.watch(sessionProvider).user?.superAdmin == true ||
      permissions.any(
        const {
          Perm.serverStatusView,
          Perm.serverUpdate,
          Perm.serverCleanup,
        }.contains,
      );
});

final serverSourceVisibleProvider = Provider<bool>(
  (ref) =>
      ref.watch(sessionProvider).user?.superAdmin == true &&
      ref.watch(currentPermissionsProvider).contains(Perm.authorizationManage),
);

final serverOperationsWritableProvider = Provider<bool>((ref) {
  final scope = ref.watch(authenticatedScopeProvider);
  final snapshot = confirmedSessionSnapshot(ref.watch(sessionSnapshotProvider));
  return scope != null &&
      scope.actorId == null &&
      !scope.readOnly &&
      snapshot != null &&
      ref.watch(sessionProvider).user?.id == scope.userId;
});
