import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../auth/permissions.dart';
import 'authenticated_scope_provider.dart';

/// Cache identity only; this does not grant access. The API client is recreated
/// when its trusted endpoint changes, including local/cloud switching.
final class SensitiveReadBoundary {
  SensitiveReadBoundary({
    required this.identity,
    required this.api,
    required Set<String> permissions,
    required this.superAdmin,
  }) : permissions = Set<String>.unmodifiable(permissions);

  final AuthenticatedScope? identity;
  final ApiClient api;
  final Set<String> permissions;
  final bool superAdmin;

  static const _permissionEquality = SetEquality<String>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensitiveReadBoundary &&
          identity == other.identity &&
          identical(api, other.api) &&
          _permissionEquality.equals(permissions, other.permissions) &&
          superAdmin == other.superAdmin;

  @override
  int get hashCode => Object.hash(
    identity,
    identityHashCode(api),
    _permissionEquality.hash(permissions),
    superAdmin,
  );
}

final sensitiveReadBoundaryProvider = Provider<SensitiveReadBoundary>(
  (ref) => SensitiveReadBoundary(
    identity: ref.watch(authenticatedScopeProvider),
    api: ref.watch(apiClientProvider),
    permissions: ref.watch(currentPermissionsProvider),
    superAdmin: ref.watch(isSuperAdminProvider),
  ),
);
