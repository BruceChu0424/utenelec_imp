// 部门 model（Phase 2）
// 文档：docs/04-数据模型/实体字典.md#department

class Department {
  const Department({
    required this.id,
    required this.code,
    required this.name,
    this.parentId,
    this.managerName,
    this.sortOrder = 0,
    this.headcount = 0,
    this.children = const [],
  });

  final String id;
  final String code;
  final String name;
  final String? parentId;
  final String? managerName;
  final int sortOrder;
  final int headcount;
  final List<Department> children;
}
