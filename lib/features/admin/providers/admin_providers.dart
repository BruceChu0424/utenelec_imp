// 权限管理 Provider：权限目录 / 部门权限配置 / 全员基础包 / 员工有效权限 / 部门树。
// 角色体系已删除(ADR-109)，授权来源只剩全员基础包 + 部门 + 个人覆盖 + 负责人委派。
// 账号列表走页面局部状态（搜索防抖 + 加载更多，与员工列表页同模式）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../department/models/department_node.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';

/// 部门树
final adminDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>(
      (ref) => ref.watch(adminRepositoryProvider).departmentTree(),
    );

/// 完整权限目录（按 category 分组；动态目录，前端不硬编码权限清单）
final permissionCatalogProvider =
    FutureProvider.autoDispose<List<PermissionCatalogGroup>>(
      (ref) => ref.watch(adminRepositoryProvider).permissionCatalog(),
    );

/// 指定部门已配置的权限点 code 列表
final adminDepartmentPermissionsProvider = FutureProvider.autoDispose
    .family<List<String>, String>(
      (ref, departmentId) => ref
          .watch(adminRepositoryProvider)
          .departmentPermissions(departmentId),
    );

/// 全员基础包的码(每个在职员工都默认拥有)
final adminPermissionBaselineProvider =
    FutureProvider.autoDispose<List<String>>(
      (ref) => ref.watch(adminRepositoryProvider).permissionBaseline(),
    );

/// 指定员工的有效权限（全员基础 ∪ 部门配置 ± 个人覆盖，后端计算）
final adminEffectivePermissionsProvider = FutureProvider.autoDispose
    .family<EffectivePermissions, String>(
      (ref, userId) =>
          ref.watch(adminRepositoryProvider).effectivePermissions(userId),
    );
