// 权限管理 Provider：角色 / 权限点 / 部门角色 / 部门树。
// 账号列表走页面局部状态（搜索防抖 + 加载更多，与员工列表页同模式）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../department/models/department_node.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';

/// 全部角色
final adminRolesProvider = FutureProvider.autoDispose<List<AdminRole>>(
  (ref) => ref.watch(adminRepositoryProvider).listRoles(),
);

/// 全部权限点
final adminPermissionsProvider =
    FutureProvider.autoDispose<List<AdminPermission>>(
      (ref) => ref.watch(adminRepositoryProvider).listPermissions(),
    );

/// 部门-角色配置
final adminDepartmentRolesProvider =
    FutureProvider.autoDispose<List<DepartmentRoleEntry>>(
      (ref) => ref.watch(adminRepositoryProvider).listDepartmentRoles(),
    );

/// 部门树
final adminDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>(
      (ref) => ref.watch(adminRepositoryProvider).departmentTree(),
    );
