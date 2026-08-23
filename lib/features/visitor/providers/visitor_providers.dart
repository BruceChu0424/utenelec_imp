// 访客端 Provider：申请列表 / 详情 / 被访人目录。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../department/models/department_node.dart';
import '../../../shared/models/paged_result.dart';
import '../models/visitor_application.dart';
import '../repositories/visitor_repository.dart';

/// 我的访客申请（按状态过滤；status=null 全部）。
typedef VisitorApplicationsQuery = ({String? status, int page});

final visitorApplicationsProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorApplication>, VisitorApplicationsQuery>((
      ref,
      q,
    ) {
      return ref
          .watch(visitorRepositoryProvider)
          .myApplications(status: q.status, page: q.page);
    });

/// 申请详情（含审批轨迹）。
final visitorApplicationDetailProvider = FutureProvider.autoDispose
    .family<VisitorApplicationDetail, String>((ref, id) {
      return ref.watch(visitorRepositoryProvider).getApplication(id);
    });

/// 部门目录。
final visitorDirectoryDepartmentsProvider =
    FutureProvider.autoDispose<List<DeptDirItem>>((ref) {
      return ref.watch(visitorRepositoryProvider).directoryDepartments();
    });

/// 部门目录树（DepartmentNode 形式，供 UtenDepartmentPicker 复用）。
/// 公司根已被后端排除：parentId 为 null 或指向被排除公司根的节点作为树顶层。
final visitorDirectoryDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>((ref) async {
      final items = await ref.watch(visitorDirectoryDepartmentsProvider.future);
      return buildVisitorDepartmentTree(items);
    });

/// 扁平部门目录 → DepartmentNode 树（保持后端返回顺序）。
List<DepartmentNode> buildVisitorDepartmentTree(List<DeptDirItem> items) {
  final ids = items.map((d) => d.id).toSet();
  final byId = {
    for (final d in items)
      d.id: DepartmentNode(
        id: d.id,
        code: '',
        name: d.name,
        level: d.level ?? '',
        parentId: d.parentId,
        children: [],
      ),
  };
  final roots = <DepartmentNode>[];
  for (final d in items) {
    final node = byId[d.id]!;
    final pid = d.parentId;
    if (pid == null || !ids.contains(pid)) {
      roots.add(node);
    } else {
      byId[pid]!.children.add(node);
    }
  }
  return roots;
}
