import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'page_permission_delegation_models.dart';

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
    return employeePermissions(
      surfaceKey: surfaceKey,
      departmentId: departmentId,
      employeeId: employeeId,
    );
  }
}

final pagePermissionDelegationRepositoryProvider =
    Provider<PagePermissionDelegationRepository>(
      (ref) => PagePermissionDelegationRepository(ref.watch(apiClientProvider)),
    );
