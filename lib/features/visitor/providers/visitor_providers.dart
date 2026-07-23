// 访客端 Provider：申请列表 / 详情 / 被访人目录。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/visitor_application.dart';
import '../repositories/visitor_repository.dart';

/// 我的访客申请（按状态过滤；status=null 全部）。
final visitorApplicationsProvider =
    FutureProvider.autoDispose.family<List<VisitorApplication>, String?>((ref, status) {
  return ref.watch(visitorRepositoryProvider).myApplications(status: status);
});

/// 申请详情（含审批轨迹）。
final visitorApplicationDetailProvider =
    FutureProvider.autoDispose.family<VisitorApplicationDetail, String>((ref, id) {
  return ref.watch(visitorRepositoryProvider).getApplication(id);
});

typedef DirQuery = ({String? departmentId, String? keyword});

/// 被访人目录（按部门/关键字过滤；后端排除离职）。
final visitorDirectoryEmployeesProvider =
    FutureProvider.autoDispose.family<List<EmployeeDirItem>, DirQuery>((ref, q) {
  return ref
      .watch(visitorRepositoryProvider)
      .directoryEmployees(departmentId: q.departmentId, keyword: q.keyword);
});

/// 部门目录。
final visitorDirectoryDepartmentsProvider =
    FutureProvider.autoDispose<List<DeptDirItem>>((ref) {
  return ref.watch(visitorRepositoryProvider).directoryDepartments();
});
