// 权限管理仓库(超级管理员)：账号列表/权限目录/个人覆盖/部门权限配置/
// 全员基础包/账号操作。角色体系已删除(ADR-109)，授权只剩这几条来源。
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

  /// 个人权限覆盖（grants=加授，revokes=回收）。
  Future<UserPermOverrides> getUserPermOverrides(String userId);

  /// 保存个人权限覆盖(期望的完整集合，服务端按差量落库并回传真正改动的码)。
  Future<PermissionChange> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  });

  /// 个人「全部授权 / 本模块 / 本组」：服务端按授权策略补齐，立即生效。
  Future<PermissionChange> grantAllToUser(
    String userId,
    PermissionBulkScope scope,
  );

  /// 部门树（复用 /org/departments/tree）。
  Future<List<DepartmentNode>> departmentTree();

  /// 完整权限目录（按 category 分组、已排序）。
  Future<List<PermissionCatalogGroup>> permissionCatalog();

  /// 部门已配置的权限点 code 列表。
  Future<List<String>> departmentPermissions(String departmentId);

  /// 保存部门权限配置(期望的完整集合，服务端按差量落库并回传真正改动的码)。
  Future<PermissionChange> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  );

  /// 部门「全部授权 / 本模块 / 本组」：服务端按授权策略补齐，立即生效。
  Future<PermissionChange> grantAllToDepartment(
    String departmentId,
    PermissionBulkScope scope,
  );

  /// 全员基础包的码。
  Future<List<String>> permissionBaseline();

  /// 保存全员基础包(期望的完整集合，服务端按差量落库)。
  Future<PermissionChange> updatePermissionBaseline(List<String> codes);

  /// 员工有效权限(全员基础 ∪ 部门 ± 个人覆盖 ∪ 负责人委派，后端计算)。
  Future<EffectivePermissions> effectivePermissions(String userId);

  /// 服务端权威数据范围目录（含启用状态、全量覆盖权限和业务分组）。
  Future<List<DataScopeCatalogItem>> dataScopeCatalog();

  /// 数据范围授权：某用户在某范围（goods/client）的可见归属人员工 id 列表。
  Future<List<String>> getUserDataScopes(String userId, String scope);

  /// 保存数据范围授权（整体替换）。
  Future<void> updateUserDataScopes(
    String userId,
    String scope,
    List<String> ownerEmployeeIds, {
    required List<String> expectedOwnerEmployeeIds,
  });

  /// 授权归属人候选（范围内实际有归属数据的员工 + 数量）。
  Future<List<DataScopeOwner>> dataScopeOwners(String scope);

  // ===== 账号操作（已有接口）=====
  Future<void> lockUser(String userId);
  Future<void> unlockUser(String userId);
  Future<void> disableUser(String userId);
  Future<void> enableUser(String userId);

  /// 重置后返回仅本次响应可见的临时密码；调用方不得持久化或记录日志。
  /// 临时密码只由后端随机生成 (20 位高熵)，不接受管理员自定义；强制员工首登改密，
  /// 有效期由系统设置「临时密码有效期」决定 (默认 72 小时)。服务端要求再认证 (ADR-110)。
  Future<String> resetPassword(String userId);

  /// 开通账号候选：尚无登录账号的在册员工（姓名/工号/部门 + 资料齐备标记）。
  Future<List<AccountProvisionCandidate>> provisionCandidates({String? search});

  /// 设置/取消超级管理员（仅超管可调；降级禁止降本人/最后一位超管，由后端校验）。
  Future<void> setSuperAdmin(String userId, {required bool superAdmin});

  /// 设置/取消云端(外网)访问授权（仅超管可调；变更即时失效旧 token，由后端校验）。
  Future<void> setRemoteAccess(String userId, {required bool remoteAccess});
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
  Future<UserPermOverrides> getUserPermOverrides(String userId) async {
    final json = await api.get(ApiEndpoints.userPermOverrides(userId));
    return UserPermOverrides.fromJson(json);
  }

  @override
  Future<PermissionChange> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  }) async {
    final json = await api.put(
      ApiEndpoints.userPermOverrides(userId),
      body: {'grants': grants, 'revokes': revokes},
    );
    return _change(json);
  }

  @override
  Future<PermissionChange> grantAllToUser(
    String userId,
    PermissionBulkScope scope,
  ) async {
    final json = await api.put(
      ApiEndpoints.userPermGrantAll(userId),
      body: scope.toJson(),
    );
    return _change(json);
  }

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
  Future<PermissionChange> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  ) async {
    final json = await api.put(
      ApiEndpoints.departmentPermissions(departmentId),
      body: {'permissions': permissionCodes},
    );
    return _change(json);
  }

  @override
  Future<PermissionChange> grantAllToDepartment(
    String departmentId,
    PermissionBulkScope scope,
  ) async {
    final json = await api.put(
      ApiEndpoints.departmentPermGrantAll(departmentId),
      body: scope.toJson(),
    );
    return _change(json);
  }

  @override
  Future<List<String>> permissionBaseline() async {
    final json = await api.get(ApiEndpoints.adminPermissionBaseline);
    return (json['permissions'] as List<dynamic>? ?? const [])
        .map((e) => e as String)
        .toList();
  }

  @override
  Future<PermissionChange> updatePermissionBaseline(List<String> codes) async {
    final json = await api.put(
      ApiEndpoints.adminPermissionBaseline,
      body: {'permissions': codes},
    );
    return _change(json);
  }

  static PermissionChange _change(Map<String, dynamic> json) =>
      PermissionChange.fromJson(json);

  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async {
    final json = await api.get(ApiEndpoints.userEffectivePermissions(userId));
    return EffectivePermissions.fromJson(json);
  }

  @override
  Future<List<DataScopeCatalogItem>> dataScopeCatalog() async {
    final rows = await api.getList(ApiEndpoints.adminDataScopeCatalog);
    return rows
        .map(DataScopeCatalogItem.fromJson)
        .where((item) => item.scope.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<List<String>> getUserDataScopes(String userId, String scope) =>
      api.getStringList(ApiEndpoints.userDataScopes(userId, scope));

  @override
  Future<void> updateUserDataScopes(
    String userId,
    String scope,
    List<String> ownerEmployeeIds, {
    required List<String> expectedOwnerEmployeeIds,
  }) => api.put(
    ApiEndpoints.userDataScopes(userId, scope),
    body: {
      'ownerEmployeeIds': ownerEmployeeIds,
      'expectedOwnerEmployeeIds': expectedOwnerEmployeeIds,
    },
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
    final issued = json['temporaryPassword'];
    if (issued is! String || issued.trim().isEmpty) {
      throw const FormatException('重置密码响应缺少 temporaryPassword');
    }
    return issued;
  }

  @override
  Future<List<AccountProvisionCandidate>> provisionCandidates({
    String? search,
  }) async {
    final list = await api.getList(
      ApiEndpoints.adminProvisionCandidates,
      query: <String, dynamic>{
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );
    return list.map(AccountProvisionCandidate.fromJson).toList();
  }

  @override
  Future<void> setSuperAdmin(String userId, {required bool superAdmin}) =>
      api.put(
        ApiEndpoints.userSuperAdmin(userId),
        body: {'superAdmin': superAdmin},
      );

  @override
  Future<void> setRemoteAccess(String userId, {required bool remoteAccess}) =>
      api.put(
        ApiEndpoints.userRemoteAccess(userId),
        body: {'remoteAccess': remoteAccess},
      );
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => DioAdminRepository(ref.watch(apiClientProvider)),
);
