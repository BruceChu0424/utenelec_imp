// 货品资料分类树/详情模型（对应后端 MaterialCategoryNode / MaterialCategoryDetail）。
//
// 与部门模型的差异：
// - level 是 int（层级深度），不再是部门那套字符串枚举（公司/决策层/...）；
// - 去掉 manager/headcount（分类不挂人）；
// - legacyId 是旧库数字主键快照，只用于迁移溯源，不是旧编码或在线关联键；
// - code 是分类自身的系统只读显示号，codePrefix 才控制子树主档编号。
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
    this.remark,
    this.codePrefix,
    this.systemManaged = false,
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
  final String? remark;
  final String? codePrefix;
  final bool systemManaged;
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
      remark: json['remark'] as String?,
      codePrefix: json['codePrefix'] as String?,
      systemManaged: json['systemManaged'] as bool? ?? false,
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
    this.remark,
    this.legacyCodeSnapshot,
    this.codePrefix,
    this.effectivePrefix,
    this.version = 0,
    this.systemManaged = false,
  });

  final String id;
  final String code;
  final String name;
  final int level;
  final String? parentId;
  final String? parentName;
  final int? sortOrder;
  final int? legacyId;
  final String? remark;
  final String? legacyCodeSnapshot;
  final String? codePrefix;
  final String? effectivePrefix;
  final int version;
  final bool systemManaged;

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
        remark: json['remark'] as String?,
        legacyCodeSnapshot: json['legacyCodeSnapshot'] as String?,
        codePrefix: json['codePrefix'] as String?,
        effectivePrefix: json['effectivePrefix'] as String?,
        version: (json['version'] as num?)?.toInt() ?? 0,
        systemManaged: json['systemManaged'] as bool? ?? false,
        path: json['path'] as String? ?? '',
        childCount: (json['childCount'] as num?)?.toInt() ?? 0,
      );
}

/// 分类删除预览：子树规模（删除前红色确认框用）。
/// [descendantCount] = 子树内除自身外的后代分类数；[goodsCount] = 子树（含自身）下未软删货品数。
class ProductCategoryDeletePreview {
  const ProductCategoryDeletePreview({
    required this.id,
    required this.descendantCount,
    required this.goodsCount,
  });

  final String id;
  final int descendantCount;
  final int goodsCount;

  factory ProductCategoryDeletePreview.fromJson(Map<String, dynamic> json) =>
      ProductCategoryDeletePreview(
        id: json['id'] as String,
        descendantCount: (json['descendantCount'] as num?)?.toInt() ?? 0,
        goodsCount: (json['goodsCount'] as num?)?.toInt() ?? 0,
      );
}

/// 新建分类请求体。分类身份由 UUID 决定；codePrefix 只控制展示编号且由服务端全局终身预约。
class ProductCategorySaveInput {
  const ProductCategorySaveInput({
    required this.name,
    this.remark,
    this.codePrefix,
    this.parentId,
    this.sortOrder,
  });

  final String name;
  final String? remark;
  final String? codePrefix;
  final String? parentId;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (remark != null && remark!.isNotEmpty) 'remark': remark,
    if (codePrefix != null && codePrefix!.isNotEmpty) 'codePrefix': codePrefix,
    if (parentId != null) 'parentId': parentId,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}

/// 编辑分类请求体。codePrefix/remark 始终上送，空串分别表示继承/清空。
class ProductCategoryUpdateInput {
  const ProductCategoryUpdateInput({
    required this.name,
    required this.codePrefix,
    required this.remark,
    required this.version,
    this.parentId,
    this.sortOrder,
  });

  final String name;
  final String codePrefix;
  final String remark;
  final int version;
  final String? parentId;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
    'name': name,
    'codePrefix': codePrefix,
    'remark': remark,
    'version': version,
    if (parentId != null) 'parentId': parentId,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}

/// 修改分类编号前缀前的服务端影响预览。
class CategoryPrefixPreview {
  const CategoryPrefixPreview({
    required this.categoryId,
    required this.currentPrefix,
    required this.requestedPrefix,
    required this.resultingEffectivePrefix,
    required this.affectedRecords,
    required this.customOrLegacyRecords,
    required this.descendantOverrides,
    required this.conflicts,
    required this.conflictSamples,
  });

  final String categoryId;
  final String? currentPrefix;
  final String? requestedPrefix;
  final String resultingEffectivePrefix;
  final int affectedRecords;
  final int customOrLegacyRecords;
  final int descendantOverrides;
  final int conflicts;
  final List<String> conflictSamples;

  factory CategoryPrefixPreview.fromJson(
    Map<String, dynamic> json,
  ) => CategoryPrefixPreview(
    categoryId: json['categoryId'] as String,
    currentPrefix: json['currentPrefix'] as String?,
    requestedPrefix: json['requestedPrefix'] as String?,
    resultingEffectivePrefix: json['resultingEffectivePrefix'] as String? ?? '',
    affectedRecords: (json['affectedRecords'] as num?)?.toInt() ?? 0,
    customOrLegacyRecords:
        (json['customOrLegacyRecords'] as num?)?.toInt() ?? 0,
    descendantOverrides: (json['descendantOverrides'] as num?)?.toInt() ?? 0,
    conflicts: (json['conflicts'] as num?)?.toInt() ?? 0,
    conflictSamples: (json['conflictSamples'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(),
  );
}
