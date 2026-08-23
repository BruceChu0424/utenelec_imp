import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_exception.dart';
import '../providers/session_provider.dart';
import 'page_permission_delegation_models.dart';

class PagePermissionDelegationRepository {
  const PagePermissionDelegationRepository(this._api);

  final ApiClient _api;

  Future<PageDelegationCapability> capability(String surfaceKey) async {
    final json = await _api.get(
      ApiEndpoints.departmentStaffPermissionCapability,
      query: {'surfaceKey': surfaceKey},
    );
    return PageDelegationCapability.fromJson(json);
  }

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

/// 离开页面即释放旧值；切换账号或权限快照后重新探测入口能力。
final pageDelegationCapabilityProvider = FutureProvider.autoDispose
    .family<PageDelegationCapability, String>((ref, surfaceKey) async {
      final user = ref.watch(sessionProvider.select((state) => state.user));
      if (user == null) {
        return PageDelegationCapability(
          surfaceKey: surfaceKey,
          superAdmin: false,
          canManage: false,
        );
      }
      final repository = ref.watch(pagePermissionDelegationRepositoryProvider);
      try {
        return await repository.capability(surfaceKey);
      } on ApiException catch (error) {
        if (error.code != 'NETWORK' &&
            error.code != 'NETWORK_TIMEOUT' &&
            error.code != 'INTERNAL') {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return repository.capability(surfaceKey);
      }
    });
