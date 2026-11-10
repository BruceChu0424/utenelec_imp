import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/paging/shared_read_provider_owner.dart';
// “我的部门”安全花名册 providers。页面级权限委派使用 shared/auth 下的独立 providers。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/department_node.dart';
import '../models/my_department.dart';
import '../repositories/my_department_repository.dart';

/// 当前用户所在大部门分支树（任意已登录员工）。
final myDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>((ref) {
      final readBoundary = ref.watch(sensitiveReadBoundaryProvider);
      return runSharedProviderRead(
        ref,
        () async {
          return ref.watch(myDepartmentRepositoryProvider).myBranchTree();
        },
        isCurrent: () =>
            ref.read(sensitiveReadBoundaryProvider) == readBoundary,
      );
    });

/// 指定部门的花名册（按 departmentId 缓存）。
final myDepartmentRosterProvider = FutureProvider.autoDispose
    .family<MyDepartmentRoster, String>((ref, deptId) {
      final readBoundary = ref.watch(sensitiveReadBoundaryProvider);
      return runSharedProviderRead(
        ref,
        () async {
          return ref.watch(myDepartmentRepositoryProvider).roster(deptId);
        },
        isCurrent: () =>
            ref.read(sensitiveReadBoundaryProvider) == readBoundary,
      );
    });
