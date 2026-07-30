// 生产部子树 provider：供生产计划/日报编辑页的车间选择器 treeOverride，
// 只暴露生产部（DEPT_PROD）下的车间（V07 seed 的 6 个 WS_*），而非整棵组织树。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';

/// 生产部子车间列表（不含生产部本身，避免误选一级部门）。
/// 树加载前为空（picker 回退默认整树），加载后只显示车间。
final productionWorkshopTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>((ref) async {
  final tree = await ref.read(departmentRepositoryProvider).tree();
  final prod = findDepartmentByCode(tree, kDeptCodeProduction);
  return prod?.children ?? const [];
});
