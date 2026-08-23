// “我的部门”安全花名册 providers。页面级权限委派使用 shared/auth 下的独立 providers。
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
final myDepartmentRosterProvider = FutureProvider.autoDispose
    .family<MyDepartmentRoster, String>((ref, deptId) {
      return ref.watch(myDepartmentRepositoryProvider).roster(deptId);
    });
