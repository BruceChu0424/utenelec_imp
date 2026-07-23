// 用户模型（前端阶段简化版）
// 完整模型待 Phase 2 员工档案阶段细化

import 'role.dart';

class AppUser {
  const AppUser({
    required this.id,
    required this.code,
    required this.name,
    required this.roles,
    this.department,
    this.position,
    this.avatarUrl,
    this.permissions = const [],
    this.superAdmin = false,
    this.employeeId,
  });

  final String id;
  final String code;
  final String name;
  final List<Role> roles;
  final String? department;
  /// super admin 该字段为 null（数据库没设 position），显示端展示"系统管理员"。
  final String? position;
  final String? avatarUrl;

  /// 功能权限点（来自后端 JWT；admin / super admin 视为通配，set 已包含所有权限）
  final List<String> permissions;

  /// 超级管理员（来自后端 users.is_super_admin）。拥有该字段后所有权限检查短路放行。
  /// 与 isAdmin 不同：super admin 不依赖具体 role/rolePermission 映射。
  final bool superAdmin;

  /// 员工档案 ID（employees.id）。Phase 6 起后端 /auth/me 返回，
  /// 自助编辑等场景直接拿这个去查 /api/org/employees/{id}。
  final String? employeeId;

  /// 是否拥有指定角色
  bool hasRole(Role role) => roles.contains(role);

  /// 是否拥有任一指定角色
  bool hasAnyRole(List<Role> roles) =>
      roles.any((r) => this.roles.contains(r));

  /// 是否拥有指定功能权限点（super admin 一律 true）
  bool can(String perm) => superAdmin || isAdmin || permissions.contains(perm);

  /// 是否为管理员（含 super admin）
  bool get isAdmin => superAdmin || hasRole(Role.admin);

  /// 是否为管理层
  bool get isManager => hasRole(Role.manager);
}

/// 当前登录会话
class Session {
  const Session({
    required this.user,
    required this.loggedInAt,
    this.token,
    this.rememberDevice = false,
  });

  final AppUser user;
  final DateTime loggedInAt;
  final String? token; // 后端接入后填
  final bool rememberDevice;

  bool get isLoggedIn => true;
}
