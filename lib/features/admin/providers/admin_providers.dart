// 权限管理 Provider：权限目录 / 部门权限配置 / 全员基础包 / 员工有效权限 / 部门树。
// 角色体系已删除(ADR-109)，授权来源只剩全员基础包 + 部门 + 个人覆盖 + 负责人委派。
// 账号列表走页面局部状态；以下共享读取由 provider 管理完整生命周期。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/paging/shared_read_provider_owner.dart';
import '../../../shared/models/department_node.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';

Future<T> _readPermissions<T>(
  Ref ref,
  Future<T> Function(AdminRepository repository) read,
) {
  final boundary = ref.watch(sensitiveReadBoundaryProvider);
  final repository = ref.watch(adminRepositoryProvider);
  // autoDispose alone drops a late value but leaves its HTTP request alive.
  // Retire transport when the last consumer leaves or the authority changes.
  // Shared catalog reads own their fence, so one departing consumer cannot
  // lend its page/request cancellation to the remaining consumers.
  return runSharedProviderRead(
    ref,
    () => read(repository),
    isCurrent: () => ref.read(sensitiveReadBoundaryProvider) == boundary,
  );
}

/// 部门树
final adminDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>(
      (ref) =>
          _readPermissions(ref, (repository) => repository.departmentTree()),
    );

/// 完整权限目录（按 category 分组；动态目录，前端不硬编码权限清单）
final permissionCatalogProvider =
    FutureProvider.autoDispose<List<PermissionCatalogGroup>>(
      (ref) =>
          _readPermissions(ref, (repository) => repository.permissionCatalog()),
    );

/// 指定部门已配置的权限点 code 列表
final adminDepartmentPermissionsProvider = FutureProvider.autoDispose
    .family<List<String>, String>(
      (ref, departmentId) => _readPermissions(
        ref,
        (repository) => repository.departmentPermissions(departmentId),
      ),
    );

/// 全员基础包的码(每个在职员工都默认拥有)
final adminPermissionBaselineProvider =
    FutureProvider.autoDispose<List<String>>(
      (ref) => _readPermissions(
        ref,
        (repository) => repository.permissionBaseline(),
      ),
    );

/// 指定员工的有效权限（全员基础 ∪ 部门配置 ± 个人覆盖，后端计算）
final adminEffectivePermissionsProvider = FutureProvider.autoDispose
    .family<EffectivePermissions, String>(
      (ref, userId) => _readPermissions(
        ref,
        (repository) => repository.effectivePermissions(userId),
      ),
    );
