// 权限管理仓库（超级管理员）：账号列表/权限点/个人覆盖/部门权限配置/账号操作。
// 角色体系已下线（ADR-011/V29），角色相关接口已移除。
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
    String? status,
  });

  /// 由员工档案 id 精确解析其登录账号，供人事详情页深链权限设置。
  Future<AdminUserSummary> userByEmployeeId(String employeeId);

  /// 全部权限点。
  Future<List<AdminPermission>> listPermissions();

  /// 个人权限覆盖（grants=加授，revokes=回收）。
  Future<UserPermOverrides> getUserPermOverrides(String userId);

  /// 保存个人权限覆盖。
  Future<void> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  });

  /// 部门树（复用 /org/departments/tree）。
  Future<List<DepartmentNode>> departmentTree();

  /// 完整权限目录（按 category 分组、已排序）。
  Future<List<PermissionCatalogGroup>> permissionCatalog();

  /// 部门已配置的权限点 code 列表。
  Future<List<String>> departmentPermissions(String departmentId);

  /// 保存部门权限配置（整体替换，未知 code 后端报错）。
  Future<void> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  );

  /// 员工有效权限（部门 ∪ 角色 ± 个人覆盖，后端计算）。
  Future<EffectivePermissions> effectivePermissions(String userId);

  /// 数据范围授权：某用户在某范围（goods/client）的可见归属人员工 id 列表。
  Future<List<String>> getUserDataScopes(String userId, String scope);

  /// 保存数据范围授权（整体替换）。
  Future<void> updateUserDataScopes(
    String userId,
    String scope,
    List<String> ownerEmployeeIds,
  );

  /// 授权归属人候选（范围内实际有归属数据的员工 + 数量）。
  Future<List<DataScopeOwner>> dataScopeOwners(String scope);

  // ===== 账号操作（已有接口）=====
  Future<void> lockUser(String userId);
  Future<void> unlockUser(String userId);
  Future<void> disableUser(String userId);
  Future<void> enableUser(String userId);

  /// 重置后返回仅本次响应可见的临时密码；调用方不得持久化或记录日志。
  Future<String> resetPassword(String userId);

  /// 设置/取消超级管理员（仅超管可调；降级禁止降本人/最后一位超管，由后端校验）。
  Future<void> setSuperAdmin(String userId, {required bool superAdmin});
}

class DioAdminRepository implements AdminRepository {
  DioAdminRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
    String? status,
  }) async {
    final json = await api.get(
      ApiEndpoints.adminUsers,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (search != null && search.isNotEmpty) 'search': search,
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    return PagedResult.fromJson(json, AdminUserSummary.fromJson);
  }

  @override
  Future<AdminUserSummary> userByEmployeeId(String employeeId) async {
    final json = await api.get(ApiEndpoints.adminUserByEmployee(employeeId));
    return AdminUserSummary.fromJson(json);
  }

  @override
  Future<List<AdminPermission>> listPermissions() async {
    final list = await api.getList(ApiEndpoints.adminPermissionList);
    return list.map(AdminPermission.fromJson).toList();
  }

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
  Future<List<DepartmentNode>> departmentTree() async {
    final list = await api.getList(ApiEndpoints.departmentsTree);
    return list.map(DepartmentNode.fromJson).toList();
  }

  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async {
    final list = await api.getList(ApiEndpoints.adminPermissionCatalog);
    return list.map(PermissionCatalogGroup.fromJson).toList();
  }

  @override
  Future<List<String>> departmentPermissions(String departmentId) async {
    final json = await api.get(
      ApiEndpoints.departmentPermissions(departmentId),
    );
    return (json['permissions'] as List<dynamic>? ?? const [])
        .map((e) => e as String)
        .toList();
  }

  @override
  Future<void> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  ) => api.put(
    ApiEndpoints.departmentPermissions(departmentId),
    body: {'permissions': permissionCodes},
  );

  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async {
    final json = await api.get(ApiEndpoints.userEffectivePermissions(userId));
    return EffectivePermissions.fromJson(json);
  }

  @override
  Future<List<String>> getUserDataScopes(String userId, String scope) =>
      api.getStringList(ApiEndpoints.userDataScopes(userId, scope));

  @override
  Future<void> updateUserDataScopes(
    String userId,
    String scope,
    List<String> ownerEmployeeIds,
  ) => api.put(
    ApiEndpoints.userDataScopes(userId, scope),
    body: {'ownerEmployeeIds': ownerEmployeeIds},
  );

  @override
  Future<List<DataScopeOwner>> dataScopeOwners(String scope) async {
    final list = await api.getList(ApiEndpoints.dataScopeOwners(scope));
    return list.map(DataScopeOwner.fromJson).toList();
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
  Future<String> resetPassword(String userId) async {
    final json = await api.post(ApiEndpoints.userResetPassword(userId));
    final temporaryPassword = json['temporaryPassword'];
    if (temporaryPassword is! String || temporaryPassword.trim().isEmpty) {
      throw const FormatException('重置密码响应缺少 temporaryPassword');
    }
    return temporaryPassword;
  }

  @override
  Future<void> setSuperAdmin(String userId, {required bool superAdmin}) =>
      api.put(
        ApiEndpoints.userSuperAdmin(userId),
        body: {'superAdmin': superAdmin},
      );
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => DioAdminRepository(ref.watch(apiClientProvider)),
);
