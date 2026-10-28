import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'page_permission_delegation_models.dart';

/// The write was acknowledged; only the following read failed.
class PagePermissionSaveCommittedError implements Exception {
  const PagePermissionSaveCommittedError(this.cause);
  final Object cause;
}

class PagePermissionDelegationRepository {
  const PagePermissionDelegationRepository(this._api);

  final ApiClient _api;

  Future<List<ManagedPermissionDepartment>> managedDepartments(
    String surfaceKey,
  ) async {
    final rows = await _api.getList(
      ApiEndpoints.departmentStaffPermissionManagedDepartments,
      query: {'surfaceKey': surfaceKey},
    );
    return rows
        .map(ManagedPermissionDepartment.fromJson)
        .toList(growable: false);
  }

  Future<PagePermissionStaffPage> staffPage({
    required String surfaceKey,
    String? departmentId,
    String? search,
    int page = 1,
    int size = 40,
    Map<String, String?> columnQuery = const {},
    String? sort,
    bool ascending = true,
  }) async {
    final normalized = search?.trim();
    final normalizedDepartmentId = departmentId?.trim();
    final json = await _api.get(
      ApiEndpoints.departmentStaffPermissionStaff,
      query: {
        'surfaceKey': surfaceKey,
        if (normalizedDepartmentId != null && normalizedDepartmentId.isNotEmpty)
          'departmentId': normalizedDepartmentId,
        if (normalized != null && normalized.isNotEmpty) 'search': normalized,
        'page': page,
        'size': size,
        for (final entry in columnQuery.entries)
          if ((entry.key.startsWith('search.') ||
                  const {
                    'accountStatus',
                    'employmentStatus',
                  }.contains(entry.key)) &&
              entry.value?.trim().isNotEmpty == true)
            entry.key: entry.value!.trim(),
        'sort': ?sort,
        if (sort != null) 'order': ascending ? 'asc' : 'desc',
      },
    );
    return PagePermissionStaffPage.fromJson(json);
  }

  Future<PagePermissionEmployeeDetail> employeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
  }) async {
    final json = await _api.get(
      ApiEndpoints.departmentStaffEmployeePermissions(employeeId),
      query: {'surfaceKey': surfaceKey, 'departmentId': departmentId},
    );
    return PagePermissionEmployeeDetail.fromJson(json);
  }

  Future<PagePermissionEmployeeDetail> saveEmployeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
    required List<PagePermissionChange> changes,
  }) async {
    await _api.putWithQuery(
      ApiEndpoints.departmentStaffEmployeePermissions(employeeId),
      query: {'surfaceKey': surfaceKey, 'departmentId': departmentId},
      body: {'changes': changes.map((item) => item.toJson()).toList()},
    );
    try {
      return await employeePermissions(
        surfaceKey: surfaceKey,
        departmentId: departmentId,
        employeeId: employeeId,
      );
    } catch (error) {
      throw PagePermissionSaveCommittedError(error);
    }
  }
}

final pagePermissionDelegationRepositoryProvider =
    Provider<PagePermissionDelegationRepository>(
      (ref) => PagePermissionDelegationRepository(ref.watch(apiClientProvider)),
    );
