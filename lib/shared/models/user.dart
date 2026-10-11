// 用户模型（前端阶段简化版）
// 完整模型待 Phase 2 员工档案阶段细化
//
// 角色体系已删除(ADR-109)：用户只有权限点，没有角色。

/// 档案快照按值比较：access token 静默刷新（约每 15 分钟一次）会带回一份
/// 新解析的 [AppUser]，内容与当前一致时必须判等，否则 SessionState 会被
/// 换成"内容相同的新对象"，全站身份栅栏将 token 刷新误判为换号。
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
    this.businessResetGeneration = 0,
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
  final int businessResetGeneration;

  /// 是否拥有指定功能权限点（super admin 一律 true）。
  bool can(String perm) => superAdmin || permissions.contains(perm);

  /// 是否拥有任一指定功能权限点（super admin 一律 true）。
  /// 用于"多级权限任一满足即可见/可进"的场景(如客户资料 self/department/all)。
  bool canAny(List<String> perms) => perms.any(can);

  @override
  bool operator ==(Object other) =>
      other is AppUser &&
      other.id == id &&
      other.code == code &&
      other.name == name &&
      other.department == department &&
      other.position == position &&
      other.superAdmin == superAdmin &&
      other.employeeId == employeeId &&
      other.businessResetGeneration == businessResetGeneration &&
      _samePermissions(other.permissions);

  /// 权限点按集合比较：服务端合成顺序不稳定，同内容不同序仍是同一份档案。
  bool _samePermissions(List<String> other) {
    if (other.length != permissions.length) return false;
    final owned = permissions.toSet();
    return other.every(owned.contains);
  }

  @override
  int get hashCode => Object.hash(
    id,
    code,
    name,
    department,
    position,
    superAdmin,
    employeeId,
    businessResetGeneration,
    Object.hashAllUnordered(permissions),
  );
}
