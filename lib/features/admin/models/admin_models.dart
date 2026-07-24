// 权限管理（超级管理员）数据模型。
// 对应后端接口契约：/admin/users · /admin/roles · /admin/permissions
// · /admin/users/{id}/permission-overrides · /admin/department-roles。

/// 员工账号摘要（GET /admin/users 的 items[]）。
class AdminUserSummary {
  const AdminUserSummary({
    required this.id,
    required this.loginAccount,
    required this.status,
    required this.mustChangePassword,
    required this.roles,
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

  /// 已分配的角色 code 列表
  final List<String> roles;
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
      );
}

/// 角色（GET /admin/roles）。
class AdminRole {
  const AdminRole({
    required this.id,
    required this.code,
    required this.name,
    required this.permissions,
    this.description,
  });

  final String id;
  final String code;
  final String name;
  final String? description;

  /// 该角色包含的权限点 code 列表
  final List<String> permissions;

  factory AdminRole.fromJson(Map<String, dynamic> json) => AdminRole(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String?,
    permissions: (json['permissions'] as List<dynamic>? ?? const [])
        .map((e) => e as String)
        .toList(),
  );
}

/// 权限点（GET /admin/permissions）。
class AdminPermission {
  const AdminPermission({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
  });

  final String id;
  final String code;
  final String name;

  /// 分组名（矩阵按此折叠分组）
  final String category;

  factory AdminPermission.fromJson(Map<String, dynamic> json) =>
      AdminPermission(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        category: json['category'] as String? ?? '其他',
      );
}

/// 部门-角色配置项（GET /admin/department-roles）。
class DepartmentRoleEntry {
  const DepartmentRoleEntry({
    required this.departmentId,
    required this.departmentName,
    required this.roles,
  });

  final String departmentId;
  final String departmentName;

  /// 该部门已配置的角色 code 列表
  final List<String> roles;

  factory DepartmentRoleEntry.fromJson(Map<String, dynamic> json) =>
      DepartmentRoleEntry(
        departmentId: json['departmentId'] as String,
        departmentName: json['departmentName'] as String? ?? '',
        roles: (json['roles'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
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
