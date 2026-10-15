import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../auth/permissions.dart';
import 'authenticated_scope_provider.dart';

/// Cache identity only; this does not grant access. The API client is recreated
/// when its trusted endpoint changes, including local/cloud switching.
typedef SensitiveReadBoundary = ({
  AuthenticatedScope? identity,
  ApiClient api,
  Set<String> permissions,
  bool superAdmin,
});

final sensitiveReadBoundaryProvider = Provider<SensitiveReadBoundary>(
  (ref) => (
    identity: ref.watch(authenticatedScopeProvider),
    api: ref.watch(apiClientProvider),
    permissions: ref.watch(currentPermissionsProvider),
    superAdmin: ref.watch(isSuperAdminProvider),
  ),
);
