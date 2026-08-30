// 生产组织树 provider：供生产计划/日报编辑页的车间和人员选择器使用。
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

const _kManufacturingCenterCode = 'MFG_CENTER';

/// 生产人员选择专用层级：只展示“制造与研发管理中心 → 生产部 → 车间/班组”。
///
/// 其它同属制造中心的工程、PMC、品质部门不会混入生产工候选范围；车间是否合法
/// 仍由服务端按 DEPT_PROD 直属关系再次校验。
class ProductionWorkforceTree {
  const ProductionWorkforceTree({
    required this.tree,
    required this.productionDepartmentId,
    required this.initiallyExpandedIds,
  });

  final List<DepartmentNode> tree;
  final String? productionDepartmentId;
  final Set<String> initiallyExpandedIds;
}

final productionWorkforceTreeProvider =
    FutureProvider.autoDispose<ProductionWorkforceTree>((ref) async {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      final center = findDepartmentByCode(tree, _kManufacturingCenterCode);
      final production = center == null
          ? findDepartmentByCode(tree, kDeptCodeProduction)
          : findDepartmentByCode(center.children, kDeptCodeProduction);
      if (center == null || production == null) {
        return ProductionWorkforceTree(
          tree: production == null ? const [] : [production],
          productionDepartmentId: production?.id,
          initiallyExpandedIds: production == null ? const {} : {production.id},
        );
      }
      final scopedCenter = DepartmentNode(
        id: center.id,
        code: center.code,
        name: center.name,
        level: center.level,
        parentId: center.parentId,
        managerId: center.managerId,
        managerName: center.managerName,
        sortOrder: center.sortOrder,
        headcount: center.headcount,
        children: [production],
      );
      return ProductionWorkforceTree(
        tree: [scopedCenter],
        productionDepartmentId: production.id,
        initiallyExpandedIds: {center.id, production.id},
      );
    });
