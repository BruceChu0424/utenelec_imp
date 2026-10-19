import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../repositories/production_fqc_repository.dart';

/// Current server decision capability. Replaced reads cannot restore authority
/// after a permission, account or server change; page inputs stay independent.
final productionFqcDecisionCapabilityProvider =
    FutureProvider.autoDispose<bool>((ref) async {
      ref.watch(authenticatedScopeProvider);
      final permissions = ref.watch(currentPermissionsProvider);
      final superAdmin = ref.watch(isSuperAdminProvider);
      final repository = ref.watch(productionFqcRepositoryProvider);
      if (!superAdmin &&
          !permissions.contains(Perm.productionQualityInspectionApprove)) {
        return false;
      }
      return repository.canDecide();
    });

bool productionFqcDecisionAllowed(AsyncValue<bool> capability) =>
    !capability.isLoading &&
    !capability.hasError &&
    capability.value == true;
