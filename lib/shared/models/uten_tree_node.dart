// 树形分类节点的最小公开契约，供跨 feature 的树组件和纯函数复用。
//
// 契约放在 shared，避免部门、员工等 feature 为复用通用树算法而反向
// 依赖 basic_data。F-bounded 保证 children 与节点自身类型一致。
abstract class UtenTreeNode<T extends UtenTreeNode<T>> {
  String get id;

  String get name;

  String get code;

  List<T> get children;

  bool get hasChildren;
}
