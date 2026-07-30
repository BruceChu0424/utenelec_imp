// 树形分类节点的最小契约，供 UtenCategoryTreeView<T> 泛化复用。
//
// 任何「id + 名称 + 编码 + 递归 children」形状的分类节点实现本接口，即可复用
// UtenCategoryTreeView 的统一树外观（搜索 / 展开折叠 / 选中高亮 / code 排序 /
// 点行展开 / 子节点数徽标）。F-bounded：children 类型与自身一致，保证回调类型安全。
//
// 现有实现：ProductCategoryNode（货品/模具/客户/供应商分类共用）、
// PaymentStyleNode（收付款类别）。未来部门树亦可收敛到此。

/// 通用分类树节点契约（F-bounded：T 为节点自身类型）。
abstract class UtenTreeNode<T extends UtenTreeNode<T>> {
  /// 节点唯一 id（选中 / 展开 / 搜索命中路径标识）。
  String get id;

  /// 显示名称（搜索匹配文本）。
  String get name;

  /// 编码（排序键 + 行内「名称（编码）」展示；非空）。
  String get code;

  /// 子节点（类型与自身一致，递归渲染）。
  List<T> get children;

  /// 是否有子节点（控制展开 chevron 显隐）。
  bool get hasChildren;
}
