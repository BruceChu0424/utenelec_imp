// 部门树/详情模型（对应后端 DepartmentNode / DepartmentDetail）。

import '../../basic_data/models/uten_tree_node.dart';

/// 可选部门层级（一级部门/二级班组/三级科室）。
const kSelectableDepartmentLevels = {'一级部门', '二级班组', '三级科室'};

/// 骨架层级（决策层/管理中心）：仅作展开骨架，不可选。
const kSkeletonDepartmentLevels = {'决策层', '管理中心'};

/// 公司根层级（选择器中不显示，从决策层开始列）。
const kCompanyDepartmentLevel = '公司';

/// 生产部 code（V07 seed：DEPT_PROD，下挂 6 个车间 WS_*）。用于车间选择器裁剪到生产部子树。
const kDeptCodeProduction = 'DEPT_PROD';

/// 营销与新媒体管理中心 code（V07 seed：MKT_CENTER，下挂 综合营销部/新媒体/轨道事业部及销售组）。
/// 用于跟单员（=销售员）选择器默认收敛到营销体系。
const kDeptCodeMarketing = 'MKT_CENTER';

/// 综合营销部 code（V07 seed：DEPT_SALES，下挂 销售1~4组）。委外（归营销）经办/采购员收敛用。
const kDeptCodeSales = 'DEPT_SALES';

/// 财税部 code（V07 seed：DEPT_FIN）。钱流经办人收敛用。
const kDeptCodeFinance = 'DEPT_FIN';

/// 采购部 code（V07 seed：SUB_PURCHASE，挂 DEPT_PMC 下）。采购员收敛用。
const kDeptCodePurchase = 'SUB_PURCHASE';

/// 部门树节点（递归 children）。
class DepartmentNode implements UtenTreeNode<DepartmentNode> {
  DepartmentNode({
    required this.id,
    required this.code,
    required this.name,
    required this.level,
    required this.children,
    this.parentId,
    this.managerId,
    this.managerName,
    this.sortOrder,
    this.headcount,
  });

  @override
  final String id;
  @override
  final String code;
  @override
  final String name;
  final String level;
  final String? parentId;
  final String? managerId;
  final String? managerName;
  final int? sortOrder;
  final int? headcount;
  @override
  final List<DepartmentNode> children;

  @override
  bool get hasChildren => children.isNotEmpty;

  factory DepartmentNode.fromJson(Map<String, dynamic> json) {
    final list = json['children'] as List<dynamic>? ?? const [];
    return DepartmentNode(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      level: json['level'] as String,
      parentId: json['parentId'] as String?,
      managerId: json['managerId'] as String?,
      managerName: json['managerName'] as String?,
      sortOrder: json['sortOrder'] as int?,
      headcount: json['headcount'] as int?,
      children: list
          .map((e) => DepartmentNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 按 code 在部门树里递归查找节点（如找生产部 DEPT_PROD）。
DepartmentNode? findDepartmentByCode(List<DepartmentNode> nodes, String code) {
  for (final n in nodes) {
    if (n.code == code) return n;
    final hit = findDepartmentByCode(n.children, code);
    if (hit != null) return hit;
  }
  return null;
}

/// 部门详情。
class DepartmentInfo {
  const DepartmentInfo({
    required this.id,
    required this.code,
    required this.name,
    required this.level,
    required this.path,
    required this.childCount,
    required this.employeeCount,
    this.parentId,
    this.parentName,
    this.managerId,
    this.managerName,
    this.sortOrder,
    this.headcount,
  });

  final String id;
  final String code;
  final String name;
  final String level;
  final String? parentId;
  final String? parentName;
  final String? managerId;
  final String? managerName;
  final int? sortOrder;
  final int? headcount;
  final String path;
  final int childCount;
  final int employeeCount;

  factory DepartmentInfo.fromJson(Map<String, dynamic> json) => DepartmentInfo(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    level: json['level'] as String,
    parentId: json['parentId'] as String?,
    parentName: json['parentName'] as String?,
    managerId: json['managerId'] as String?,
    managerName: json['managerName'] as String?,
    sortOrder: json['sortOrder'] as int?,
    headcount: json['headcount'] as int?,
    path: json['path'] as String? ?? '',
    childCount: (json['childCount'] as num?)?.toInt() ?? 0,
    employeeCount: (json['employeeCount'] as num?)?.toInt() ?? 0,
  );
}

/// 新建部门请求。
class DepartmentSaveInput {
  const DepartmentSaveInput({
    required this.code,
    required this.name,
    required this.level,
    this.parentId,
    this.managerId,
    this.sortOrder,
  });

  final String code;
  final String name;
  final String level;
  final String? parentId;
  final String? managerId;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'level': level,
    if (parentId != null) 'parentId': parentId,
    if (managerId != null) 'managerId': managerId,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}

/// 编辑部门请求（后端 DepartmentUpdateRequest）。
class DepartmentUpdateInput {
  const DepartmentUpdateInput({
    required this.name,
    this.parentId,
    this.managerId,
    this.sortOrder,
    this.managerSpecified = false,
  });

  final String name;
  final String? parentId;
  final String? managerId;
  final int? sortOrder;
  final bool managerSpecified;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (parentId != null) 'parentId': parentId,
    if (managerSpecified) 'managerId': managerId,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}
