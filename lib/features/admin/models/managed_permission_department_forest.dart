import '../../../shared/auth/page_permission_delegation_models.dart';

import '../../department/models/department_node.dart';

/// 把服务端按权限裁剪后的扁平组织范围还原为人事部门树组件可直接使用的 forest。
///
/// 服务端是组织范围的唯一来源：这里只连接返回行之间的父子关系，不读取完整公司部门树，
/// 因此不会在负责人界面暴露范围外部门。缺失父节点的行作为 forest 根显示。
class ManagedPermissionDepartmentForest {
  const ManagedPermissionDepartmentForest({
    required this.roots,
    required this.selectableIds,
  });

  factory ManagedPermissionDepartmentForest.fromRows(
    List<ManagedPermissionDepartment> rows,
  ) {
    final byId = <String, ManagedPermissionDepartment>{
      for (final row in rows) row.departmentId: row,
    };
    final nodes = <String, DepartmentNode>{
      for (final row in byId.values)
        row.departmentId: DepartmentNode(
          id: row.departmentId,
          code: row.code.trim().isEmpty ? row.departmentId : row.code,
          name: row.departmentName,
          level: row.level,
          parentId: row.parentId,
          sortOrder: row.sortOrder,
          children: <DepartmentNode>[],
        ),
    };
    final roots = <DepartmentNode>[];
    final cyclicIds = _cyclicDepartmentIds(byId);
    for (final row in byId.values) {
      final node = nodes[row.departmentId]!;
      final parentId = row.parentId;
      final parent = parentId == null ? null : nodes[parentId];
      if (parentId == null ||
          parent == null ||
          cyclicIds.contains(row.departmentId)) {
        roots.add(node);
      } else {
        parent.children.add(node);
      }
    }

    int compare(DepartmentNode left, DepartmentNode right) {
      final byOrder = (left.sortOrder ?? 0).compareTo(right.sortOrder ?? 0);
      if (byOrder != 0) return byOrder;
      final byName = left.name.compareTo(right.name);
      return byName != 0 ? byName : left.id.compareTo(right.id);
    }

    void sortTree(List<DepartmentNode> nodes) {
      nodes.sort(compare);
      for (final node in nodes) {
        sortTree(node.children);
      }
    }

    sortTree(roots);
    return ManagedPermissionDepartmentForest(
      roots: roots,
      selectableIds: {
        for (final row in byId.values)
          if (row.selectable) row.departmentId,
      },
    );
  }

  final List<DepartmentNode> roots;
  final Set<String> selectableIds;
}

Set<String> _cyclicDepartmentIds(
  Map<String, ManagedPermissionDepartment> byId,
) {
  final cyclic = <String>{};
  final completed = <String>{};
  for (final start in byId.keys) {
    if (completed.contains(start)) continue;
    final path = <String>[];
    final pathIndex = <String, int>{};
    var cursor = start;
    while (byId.containsKey(cursor) &&
        !completed.contains(cursor) &&
        !pathIndex.containsKey(cursor)) {
      pathIndex[cursor] = path.length;
      path.add(cursor);
      final parentId = byId[cursor]!.parentId;
      if (parentId == null || !byId.containsKey(parentId)) break;
      cursor = parentId;
    }
    final cycleStart = pathIndex[cursor];
    if (cycleStart != null) {
      cyclic.addAll(path.skip(cycleStart));
    }
    completed.addAll(path);
  }
  return cyclic;
}
