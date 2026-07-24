// 权限管理仓库（超级管理员）：账号列表/角色/权限点/覆盖/部门角色/账号操作。
// 模仿 DioEmployeeRepository：注入 ApiClient，DioException 已在 ApiClient 层
// 统一转为 ApiException。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../../department/models/department_node.dart';
import '../models/admin_models.dart';

abstract interface class AdminRepository {
  /// 账号分页列表（search 按登录账号搜）。
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
  });

  /// 全部角色。
  Future<List<AdminRole>> listRoles();

  /// 全部权限点。
  Future<List<AdminPermission>> listPermissions();

  /// 保存用户角色分配。
  Future<void> updateUserRoles(String userId, List<String> roleCodes);

  /// 个人权限覆盖（grants=加授，revokes=回收）。
  Future<UserPermOverrides> getUserPermOverrides(String userId);

  /// 保存个人权限覆盖。
  Future<void> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  });

  /// 部门-角色配置列表。
  Future<List<DepartmentRoleEntry>> listDepartmentRoles();

  /// 保存部门角色配置。
  Future<void> updateDepartmentRoles(
    String departmentId,
    List<String> roleCodes,
  );

  /// 部门树（复用 /org/departments/tree）。
  Future<List<DepartmentNode>> departmentTree();

  // ===== 账号操作（已有接口）=====
  Future<void> lockUser(String userId);
  Future<void> unlockUser(String userId);
  Future<void> disableUser(String userId);
  Future<void> enableUser(String userId);
  Future<void> resetPassword(String userId);
}

class DioAdminRepository implements AdminRepository {
  DioAdminRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
  }) async {
    final json = await api.get(
      ApiEndpoints.adminUsers,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );
    return PagedResult.fromJson(json, AdminUserSummary.fromJson);
  }

  @override
  Future<List<AdminRole>> listRoles() async {
    final list = await api.getList(ApiEndpoints.adminRoles);
    return list.map(AdminRole.fromJson).toList();
  }

  @override
  Future<List<AdminPermission>> listPermissions() async {
    final list = await api.getList(ApiEndpoints.adminPermissionList);
    return list.map(AdminPermission.fromJson).toList();
  }

  @override
  Future<void> updateUserRoles(String userId, List<String> roleCodes) =>
      api.put(ApiEndpoints.userRoles(userId), body: {'roles': roleCodes});

  @override
  Future<UserPermOverrides> getUserPermOverrides(String userId) async {
    final json = await api.get(ApiEndpoints.userPermOverrides(userId));
    return UserPermOverrides.fromJson(json);
  }

  @override
  Future<void> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  }) => api.put(
    ApiEndpoints.userPermOverrides(userId),
    body: {'grants': grants, 'revokes': revokes},
  );

  @override
  Future<List<DepartmentRoleEntry>> listDepartmentRoles() async {
    final list = await api.getList(ApiEndpoints.adminDepartmentRoles);
    return list.map(DepartmentRoleEntry.fromJson).toList();
  }

  @override
  Future<void> updateDepartmentRoles(
    String departmentId,
    List<String> roleCodes,
  ) => api.put(
    ApiEndpoints.departmentRoles(departmentId),
    body: {'roles': roleCodes},
  );

  @override
  Future<List<DepartmentNode>> departmentTree() async {
    final list = await api.getList(ApiEndpoints.departmentsTree);
    return list.map(DepartmentNode.fromJson).toList();
  }

  @override
  Future<void> lockUser(String userId) =>
      api.post(ApiEndpoints.userLock(userId));

  @override
  Future<void> unlockUser(String userId) =>
      api.post(ApiEndpoints.userUnlock(userId));

  @override
  Future<void> disableUser(String userId) =>
      api.post(ApiEndpoints.userDisable(userId));

  @override
  Future<void> enableUser(String userId) =>
      api.post(ApiEndpoints.userEnable(userId));

  @override
  Future<void> resetPassword(String userId) =>
      api.post(ApiEndpoints.userResetPassword(userId));
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => DioAdminRepository(ref.watch(apiClientProvider)),
);
