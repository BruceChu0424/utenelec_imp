// 用户模型（前端阶段简化版）
// 完整模型待 Phase 2 员工档案阶段细化
//
// 角色体系已删除(ADR-109)：用户只有权限点，没有角色。

class AppUser {
  const AppUser({
    required this.id,
    required this.code,
    required this.name,
    this.department,
    this.position,
    this.permissions = const [],
    this.superAdmin = false,
    this.employeeId,
  });

  final String id;
  final String code;
  final String name;
  final String? department;

  /// super admin 该字段为 null（数据库没设 position），显示端展示"系统管理员"。
  final String? position;

  /// 功能权限点(服务端当场按权限目录合成下发；超级管理员已是全部目录码)。
  final List<String> permissions;

  /// 超级管理员（来自后端 users.is_super_admin）。拥有该字段后所有权限检查短路放行。
  final bool superAdmin;

  /// 员工档案 ID（employees.id）。Phase 6 起后端 /auth/me 返回，
  /// 自助编辑等场景直接拿这个去查 /api/org/employees/{id}。
  final String? employeeId;

  /// 是否拥有指定功能权限点（super admin 一律 true）。
  bool can(String perm) => superAdmin || permissions.contains(perm);

  /// 是否拥有任一指定功能权限点（super admin 一律 true）。
  /// 用于"多级权限任一满足即可见/可进"的场景（如客户资料 self/department/all）。
  bool canAny(List<String> perms) => perms.any(can);
}
