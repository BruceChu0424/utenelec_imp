// 部门树/详情模型（对应后端 DepartmentNode / DepartmentDetail）。

/// 部门树节点（递归 children）。
class DepartmentNode {
  DepartmentNode({
    required this.id,
    required this.code,
    required this.name,
    required this.level,
    required this.children,
    this.parentId,
    this.managerName,
    this.sortOrder,
    this.headcount,
  });

  final String id;
  final String code;
  final String name;
  final String level;
  final String? parentId;
  final String? managerName;
  final int? sortOrder;
  final int? headcount;
  final List<DepartmentNode> children;

  bool get hasChildren => children.isNotEmpty;

  factory DepartmentNode.fromJson(Map<String, dynamic> json) {
    final list = json['children'] as List<dynamic>? ?? const [];
    return DepartmentNode(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      level: json['level'] as String,
      parentId: json['parentId'] as String?,
      managerName: json['managerName'] as String?,
      sortOrder: json['sortOrder'] as int?,
      headcount: json['headcount'] as int?,
      children: list.map((e) => DepartmentNode.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
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
  });

  final String name;
  final String? parentId;
  final String? managerId;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (parentId != null) 'parentId': parentId,
        if (managerId != null) 'managerId': managerId,
        if (sortOrder != null) 'sortOrder': sortOrder,
      };
}
