// 模具「车间」选择器专用部门树 provider：只暴露"制造与研发管理中心"(MFG_CENTER)整棵子树
// （PMC运营部/品质管理部/工程研发部/生产部及其下属班组），不含公司根、决策层与其它管理中心；
// 附带生产部 id，供选择器默认只展开生产部（问题 #5：车间选择器范围+默认展开+确认按钮）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';

const _kMfgCenterCode = 'MFG_CENTER';
const _kDeptProdCode = 'DEPT_PROD';

class MouldWorkshopTree {
  const MouldWorkshopTree({required this.tree, required this.prodDeptId});

  /// 单根数组：仅"制造与研发管理中心"（找不到时兜底空数组）。
  final List<DepartmentNode> tree;

  /// 生产部 id（找不到时为 null，选择器不做默认展开）。
  final String? prodDeptId;
}

final mouldWorkshopTreeProvider =
    FutureProvider.autoDispose<MouldWorkshopTree>((ref) async {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      final center = findDepartmentByCode(tree, _kMfgCenterCode);
      final prod = center == null
          ? null
          : findDepartmentByCode(center.children, _kDeptProdCode);
      return MouldWorkshopTree(
        tree: center == null ? const [] : [center],
        prodDeptId: prod?.id,
      );
    });
