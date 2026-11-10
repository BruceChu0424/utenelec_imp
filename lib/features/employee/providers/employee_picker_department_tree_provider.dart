import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/paging/shared_read_provider_owner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/models/department_node.dart';

/// Minimal organization metadata, without staff, managers or headcount. This
/// cache follows the same identity/permission boundary as employee candidates.
final employeePickerDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>((ref) async {
      final readBoundary = ref.watch(sensitiveReadBoundaryProvider);
      return runSharedProviderRead(
        ref,
        () async {
          ref.watch(authenticatedScopeProvider);
          ref.watch(currentPermissionsProvider);
          ref.watch(isSuperAdminProvider);
          final rows = await ref
              .watch(apiClientProvider)
              .getList(ApiEndpoints.employeePickerDepartmentTree);
          return rows.map(DepartmentNode.fromJson).toList();
        },
        isCurrent: () =>
            ref.read(sensitiveReadBoundaryProvider) == readBoundary,
      );
    });
