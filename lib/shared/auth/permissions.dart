// 权限点常量（与后端 permissions 表 code 对齐）+ 当前用户权限/角色 Provider。
// 文档：docs/05-架构/全局机制.md §1
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/role.dart';
import '../providers/session_provider.dart';

abstract final class Perm {
  static const employeeView = 'employee:view';
  static const employeeCreate = 'employee:create';
  static const employeeEdit = 'employee:edit';
  static const employeeDelete = 'employee:delete';
  static const departmentView = 'department:view';
  static const departmentEdit = 'department:edit';
  static const userManage = 'user:manage';
  static const payrollViewSelf = 'payroll:view:self';
  static const payrollViewAll = 'payroll:view:all';
  static const payrollGenerate = 'payroll:generate';
  static const payrollReview = 'payroll:review';
  static const expenseApprove = 'expense:approve';
  static const visitorView = 'visitor:view';
  static const visitorApprove = 'visitor:approve';
  static const visitorCheckIn = 'visitor:check-in';
}

/// 当前用户的功能权限集合。
///
/// 超级管理员（[UserProfile.superAdmin] == true）后端已经把全量 permissions 推过来，
/// 因此这里的 Set 已包含所有权限点。如果未来后端没推全，前端也会再 union 一个
/// "所有已知 Perm" 兜底——但主路径以后端为准。
final currentPermissionsProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const <String>{};
  if (user.superAdmin) {
    // 兜底：union 所有已知 Perm 常量。即便后端漏推某个新增权限也能 work。
    return <String>{
      Perm.employeeView,
      Perm.employeeCreate,
      Perm.employeeEdit,
      Perm.employeeDelete,
      Perm.departmentView,
      Perm.departmentEdit,
      Perm.userManage,
      Perm.payrollViewSelf,
      Perm.payrollViewAll,
      Perm.payrollGenerate,
      Perm.payrollReview,
      Perm.expenseApprove,
      Perm.visitorView,
      Perm.visitorApprove,
      Perm.visitorCheckIn,
      ...user.permissions,
    };
  }
  return user.permissions.toSet();
});

/// 当前用户是否为超级管理员（专一字段，便于 UI 短路判定）。
final isSuperAdminProvider = Provider<bool>((ref) {
  final user = ref.watch(sessionProvider).user;
  return user?.superAdmin ?? false;
});

/// 当前用户的角色名集合（如 {'hr','manager'}）。
final currentRolesProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const <String>{};
  return user.roles.map((Role r) => r.name).toSet();
});

/// 通用权限判定快捷函数。super admin 一律短路放行，其他按权限字符串匹配。
bool hasPerm(Ref ref, String code) {
  if (ref.read(isSuperAdminProvider)) return true;
  return ref.read(currentPermissionsProvider).contains(code);
}

/// 仅判断当前用户角色——不引入权限集。
bool hasRole(Ref ref, String code) {
  return ref.read(currentRolesProvider).contains(code);
}
