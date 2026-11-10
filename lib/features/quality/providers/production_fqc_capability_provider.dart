import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/paging/shared_read_provider_owner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../repositories/production_fqc_repository.dart';

/// Current server decision capability. Replaced reads cannot restore authority
/// after a permission, account or server change; page inputs stay independent.
final productionFqcDecisionCapabilityProvider =
    FutureProvider.autoDispose<bool>((ref) async {
      final readBoundary = ref.watch(sensitiveReadBoundaryProvider);
      return runSharedProviderRead(
        ref,
        () async {
          ref.watch(authenticatedScopeProvider);
          final permissions = ref.watch(currentPermissionsProvider);
          final superAdmin = ref.watch(isSuperAdminProvider);
          final repository = ref.watch(productionFqcRepositoryProvider);
          if (!superAdmin &&
              !permissions.contains(Perm.productionQualityInspectionApprove)) {
            return false;
          }
          return repository.canDecide();
        },
        isCurrent: () =>
            ref.read(sensitiveReadBoundaryProvider) == readBoundary,
      );
    });

bool productionFqcDecisionAllowed(AsyncValue<bool> capability) =>
    !capability.isLoading && !capability.hasError && capability.value == true;
