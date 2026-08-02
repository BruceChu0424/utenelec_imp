// 「我的部门」卡片用 providers。后端 /api/my-department/** 与 /api/department-staff-permissions/**。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/department_node.dart';
import '../models/my_department.dart';
import '../repositories/my_department_repository.dart';

/// 当前用户所在大部门分支树（任意已登录员工）。
final myDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>((ref) {
  return ref.watch(myDepartmentRepositoryProvider).myBranchTree();
});

/// 指定部门的花名册（按 departmentId 缓存）。
final myDepartmentRosterProvider =
    FutureProvider.autoDispose.family<MyDepartmentRoster, String>((
  ref,
  deptId,
) {
  return ref.watch(myDepartmentRepositoryProvider).roster(deptId);
});

/// 部门负责人的本部门员工权限面板（非负责人 403——前端据此隐藏面板）。
final managedStaffPermissionsProvider =
    FutureProvider.autoDispose<DepartmentStaffPermissions>((ref) {
  return ref.watch(myDepartmentRepositoryProvider).managed();
});
