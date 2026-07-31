// 分类树「统一搜索定位」共享辅助（泛型，适用于任意 UtenTreeNode 树）。
//
// 供各「分类树 + 主档列表」页（货品/模具/客户/供应商资料页、即时库存、部门管理）复用：
// 用户在分类栏顶部搜索框输入关键词 → ① 分类名命中（本文件算）+ ② 主档命中（各页调各自
// repository.search 取 categoryId/departmentId）→ 合并为 visibleFilterIds 喂给树组件，
// 命中分类自动展开+定位。纯函数，无副作用，不持有状态。
import '../models/uten_tree_node.dart';

/// 分类名含 q 的节点 + 其全部祖先 +（自身命中时）其全部后代 的 id 集合。
///
/// 用于驱动 `UtenCategoryTreeView.visibleFilterIds`（或部门树同款参数）：命中分类的祖先链
/// 也要在集合里，树组件据此自动展开路径。自身命中的节点其整子树都算相关（子分类也显示）。
Set<String> categoryHits<T extends UtenTreeNode<T>>(List<T> roots, String q) {
  final ids = <String>{};
  bool walk(List<T> nodes, List<String> ancestors) {
    var anyHit = false;
    for (final n in nodes) {
      final selfHit = n.name.contains(q);
      final childHit = walk(n.children, [...ancestors, n.id]);
      if (selfHit || childHit) {
        ids.addAll(ancestors); // 祖先链（用于展开路径）
        ids.add(n.id);
        if (selfHit) addAllSubtree(n, ids); // 命中分类下所有子分类都相关
        anyHit = true;
      }
    }
    return anyHit;
  }

  walk(roots, const []);
  return ids;
}

/// 把节点及其全部后代的 id 加入集合。
void addAllSubtree<T extends UtenTreeNode<T>>(T n, Set<String> ids) {
  ids.add(n.id);
  for (final c in n.children) {
    addAllSubtree(c, ids);
  }
}

/// 把 id 的祖先链（含自身）加入 set。用于主档命中后，把其所在分类的展开路径补进集合。
void addAncestors<T extends UtenTreeNode<T>>(
  List<T> roots,
  String id,
  Set<String> set,
) {
  List<String>? path(List<T> nodes, List<String> acc) {
    for (final n in nodes) {
      if (n.id == id) return [...acc, n.id];
      final p = path(n.children, [...acc, n.id]);
      if (p != null) return p;
    }
    return null;
  }

  final p = path(roots, const []);
  if (p != null) set.addAll(p);
}

/// 命中集合里 name 含 q 的最浅节点 id（用于「仅分类命中」时自动定位选中）。
String? shallowestHit<T extends UtenTreeNode<T>>(
  List<T> roots,
  String q,
  Set<String> hits,
) {
  String? found;
  void walk(List<T> nodes) {
    for (final n in nodes) {
      if (found == null && hits.contains(n.id) && n.name.contains(q)) {
        found = n.id;
      }
      walk(n.children);
    }
  }

  walk(roots);
  return found;
}
