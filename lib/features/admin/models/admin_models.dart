// 权限管理（超级管理员）数据模型。
// 对应后端接口契约：/admin/users · /admin/permissions · /admin/permission-catalog
// · /admin/users/{id}/permission-overrides · /admin/users/{id}/effective-permissions
// · /admin/departments/{id}/permissions。角色体系已下线（ADR-011/V29）。

/// 员工账号摘要（GET /admin/users 的 items[]）。
class AdminUserSummary {
  const AdminUserSummary({
    required this.id,
    required this.loginAccount,
    required this.status,
    required this.mustChangePassword,
    required this.roles,
    required this.remoteAccess,
    this.employeeName,
    this.employeeCode,
    this.lastLoginAt,
    this.departmentId,
    this.departmentName,
  });

  final String id;
  final String loginAccount;

  /// 'active' | 'locked' | 'disabled'
  final String status;
  final bool mustChangePassword;

  /// 已分配的角色 code 列表（历史遗留字段，后端仍返回；角色体系下线后仅作展示参考，不参与权限）
  final List<String> roles;

  /// 是否授权云端(外网)访问。仅 remote_access=TRUE 的账号可在云端实例登录；
  /// 权限页顶部「云端访问」开关据此回显，授权后该账号须重新登录拿新 token。
  final bool remoteAccess;

  final String? employeeName;
  final String? employeeCode;
  final String? lastLoginAt;
  final String? departmentId;
  final String? departmentName;

  factory AdminUserSummary.fromJson(Map<String, dynamic> json) =>
      AdminUserSummary(
        id: json['id'] as String,
        loginAccount: json['loginAccount'] as String? ?? '',
        status: json['status'] as String? ?? 'active',
        mustChangePassword: json['mustChangePassword'] as bool? ?? false,
        roles: (json['roles'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
        employeeName: json['employeeName'] as String?,
        employeeCode: json['employeeCode'] as String?,
        lastLoginAt: json['lastLoginAt'] as String?,
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
        remoteAccess: json['remoteAccess'] as bool? ?? false,
      );
}

/// 权限点（GET /admin/permissions）。
class AdminPermission {
  const AdminPermission({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
    this.module,
  });

  final String id;
  final String code;
  final String name;

  /// 二级子类（矩阵按此折叠二级分组）
  final String category;

  /// 一级功能模块（如「基础资料」）；驱动权限目录一级分组。目录项可能不带回传，由组名兜底。
  final String? module;

  factory AdminPermission.fromJson(Map<String, dynamic> json) =>
      AdminPermission(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        category: json['category'] as String? ?? '其他',
        module: json['module'] as String?,
      );
}

/// 个人权限覆盖（GET /admin/users/{id}/permission-overrides）。
class UserPermOverrides {
  const UserPermOverrides({required this.grants, required this.revokes});

  /// 加授的权限点 code 列表
  final List<String> grants;

  /// 回收的权限点 code 列表
  final List<String> revokes;

  factory UserPermOverrides.fromJson(Map<String, dynamic> json) =>
      UserPermOverrides(
        grants: (json['grants'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
        revokes: (json['revokes'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
      );
}

/// 权限目录分组（GET /admin/permission-catalog 的数组项）。
/// 目录是动态的：后端返回什么前端显示什么，不硬编码权限清单。
/// 两级：[module] 一级功能模块 → [category] 二级子类 → permissions。
class PermissionCatalogGroup {
  const PermissionCatalogGroup({
    required this.module,
    required this.category,
    required this.permissions,
  });

  /// 一级模块（如「基础资料」「销售管理」）。
  final String module;

  /// 二级子类（如「货品资料」「销售订货」）。
  final String category;

  /// 该分组下的权限点（已按后端排序）
  final List<AdminPermission> permissions;

  factory PermissionCatalogGroup.fromJson(Map<String, dynamic> json) {
    final category = json['category'] as String? ?? '其他';
    final module = json['module'] as String? ?? '其他';
    return PermissionCatalogGroup(
      module: module,
      category: category,
      permissions: (json['permissions'] as List<dynamic>? ?? const []).map((e) {
        final p = e as Map<String, dynamic>;
        final code = p['code'] as String? ?? '';
        // 目录项可能不带 id/module/category，用 code 兜底 id、组名兜底 module/category
        return AdminPermission(
          id: p['id'] as String? ?? code,
          code: code,
          name: p['name'] as String? ?? '',
          category: p['category'] as String? ?? category,
          module: p['module'] as String? ?? module,
        );
      }).toList(),
    );
  }
}

/// 员工有效权限（GET /admin/users/{id}/effective-permissions）。
/// effective 由后端计算：全员基础 ∪ 部门配置 ∪ 个人加授 − 个人收回。
class EffectivePermissions {
  const EffectivePermissions({
    required this.departmentPermissions,
    required this.baselinePermissions,
    required this.grants,
    required this.revokes,
    required this.effective,
    this.departmentId,
    this.departmentName,
    this.superAdmin = false,
  });

  final String? departmentId;
  final String? departmentName;

  /// 超级管理员：恒为全量权限，权限页据此全部显示"已授权"且不可调整
  final bool superAdmin;

  /// 所在部门已配置的权限点 code 列表
  final List<String> departmentPermissions;

  /// 全员基础权限点 code 列表（人人有份，角色体系下线后仅保留基础包）
  final List<String> baselinePermissions;

  /// 个人加授的权限点 code 列表
  final List<String> grants;

  /// 个人收回的权限点 code 列表
  final List<String> revokes;

  /// 最终有效权限点 code 列表（后端计算结果，前端以此为准）
  final List<String> effective;

  static List<String> _codes(Map<String, dynamic> json, String key) =>
      (json[key] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList();

  factory EffectivePermissions.fromJson(Map<String, dynamic> json) =>
      EffectivePermissions(
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
        departmentPermissions: _codes(json, 'departmentPermissions'),
        baselinePermissions: _codes(json, 'baselinePermissions'),
        grants: _codes(json, 'grants'),
        revokes: _codes(json, 'revokes'),
        effective: _codes(json, 'effective'),
        superAdmin: json['superAdmin'] as bool? ?? false,
      );
}

/// 数据范围授权归属人候选（范围内实际有归属数据的员工）。
class DataScopeOwner {
  const DataScopeOwner({
    required this.employeeId,
    required this.name,
    required this.count,
  });

  final String employeeId;
  final String name;
  final int count;

  factory DataScopeOwner.fromJson(Map<String, dynamic> json) => DataScopeOwner(
    employeeId: json['employeeId'] as String,
    name: json['name'] as String,
    count: (json['count'] as num).toInt(),
  );
}
