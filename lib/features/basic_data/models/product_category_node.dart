// 货品资料分类树/详情模型（对应后端 MaterialCategoryNode / MaterialCategoryDetail）。
//
// 与部门模型的差异：
// - level 是 int（层级深度），不再是部门那套字符串枚举（公司/决策层/...）；
// - 去掉 manager/headcount（分类不挂人）；
// - 新增 legacyId（旧系统编码，迁移用）。
//
// 实现 UtenTreeNode<ProductCategoryNode>：货品/模具/客户/供应商四份分类主档
// 节点形状一致，共用本类型，统一喂给 UtenCategoryTreeView<ProductCategoryNode>。

import 'uten_tree_node.dart';

/// 货品分类树节点（递归 children）。
class ProductCategoryNode implements UtenTreeNode<ProductCategoryNode> {
  ProductCategoryNode({
    required this.id,
    required this.code,
    required this.name,
    required this.level,
    required this.children,
    this.parentId,
    this.sortOrder,
    this.legacyId,
  });

  @override
  final String id;
  @override
  final String code;
  @override
  final String name;

  /// 层级深度（0 = 顶级）。
  final int level;
  final String? parentId;
  final int? sortOrder;
  final int? legacyId;
  @override
  final List<ProductCategoryNode> children;

  @override
  bool get hasChildren => children.isNotEmpty;

  factory ProductCategoryNode.fromJson(Map<String, dynamic> json) {
    final list = json['children'] as List<dynamic>? ?? const [];
    return ProductCategoryNode(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      level: (json['level'] as num?)?.toInt() ?? 0,
      parentId: json['parentId'] as String?,
      sortOrder: (json['sortOrder'] as num?)?.toInt(),
      legacyId: (json['legacyId'] as num?)?.toInt(),
      children: list
          .map((e) => ProductCategoryNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 货品分类详情。
class ProductCategoryDetail {
  const ProductCategoryDetail({
    required this.id,
    required this.code,
    required this.name,
    required this.level,
    required this.path,
    required this.childCount,
    this.parentId,
    this.parentName,
    this.sortOrder,
    this.legacyId,
  });

  final String id;
  final String code;
  final String name;
  final int level;
  final String? parentId;
  final String? parentName;
  final int? sortOrder;
  final int? legacyId;

  /// 完整路径文案（如「原材料 > 钢材 > 不锈钢」）。
  final String path;
  final int childCount;

  factory ProductCategoryDetail.fromJson(Map<String, dynamic> json) =>
      ProductCategoryDetail(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
        level: (json['level'] as num?)?.toInt() ?? 0,
        parentId: json['parentId'] as String?,
        parentName: json['parentName'] as String?,
        sortOrder: (json['sortOrder'] as num?)?.toInt(),
        legacyId: (json['legacyId'] as num?)?.toInt(),
        path: json['path'] as String? ?? '',
        childCount: (json['childCount'] as num?)?.toInt() ?? 0,
      );
}

/// 新建分类请求体：{code?,name,parentId?,sortOrder?}。
/// code 留空 → 后端 FL 前缀原子取号自动生成；非空 → 后端查重（须唯一）。
class ProductCategorySaveInput {
  const ProductCategorySaveInput({
    this.code,
    required this.name,
    this.parentId,
    this.sortOrder,
  });

  final String? code;
  final String name;
  final String? parentId;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
    if (code != null && code!.isNotEmpty) 'code': code,
    'name': name,
    if (parentId != null) 'parentId': parentId,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}

/// 编辑分类请求体：{name,parentId?,sortOrder?}（code 不可改，不在体内）。
class ProductCategoryUpdateInput {
  const ProductCategoryUpdateInput({
    required this.name,
    this.parentId,
    this.sortOrder,
  });

  final String name;
  final String? parentId;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (parentId != null) 'parentId': parentId,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}
