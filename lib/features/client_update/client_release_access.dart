import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/auth/permissions.dart';
import '../../shared/providers/authenticated_scope_provider.dart';

/// Shared authority and owner for the publishing entry and every draft command.
/// Super administrators receive this code from the server permission catalog.
final clientReleasePublisherProvider = Provider<AuthenticatedScope?>((ref) {
  final owner = ref.watch(authenticatedScopeProvider);
  final permissions = ref.watch(currentPermissionsProvider);
  if (owner == null ||
      owner.actorId != null ||
      owner.readOnly ||
      !permissions.contains(Perm.clientReleasePublish)) {
    return null;
  }
  return owner;
});
