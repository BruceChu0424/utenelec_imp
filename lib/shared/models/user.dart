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
  });

  final String id;
  final String code;
  final String name;
  final List<Role> roles;
  final String? department;
  final String? position;
  final String? avatarUrl;

  /// 功能权限点（来自后端 JWT；admin 视为通配）
  final List<String> permissions;

  /// 是否拥有指定角色
  bool hasRole(Role role) => roles.contains(role);

  /// 是否拥有任一指定角色
  bool hasAnyRole(List<Role> roles) =>
      roles.any((r) => this.roles.contains(r));

  /// 是否拥有指定功能权限点
  bool can(String perm) => isAdmin || permissions.contains(perm);

  /// 是否为管理员
  bool get isAdmin => hasRole(Role.admin);

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
