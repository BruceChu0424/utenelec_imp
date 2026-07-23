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

/// 当前用户的功能权限集合（admin 视为通配）。
final currentPermissionsProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const {};
  return user.permissions.toSet();
});

/// 当前用户的角色名集合（如 {'hr','manager'}）。
final currentRolesProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const {};
  return user.roles.map((Role r) => r.name).toSet();
});
