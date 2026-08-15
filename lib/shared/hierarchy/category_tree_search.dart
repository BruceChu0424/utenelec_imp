// 分类树「统一搜索定位」共享辅助（泛型，适用于任意 UtenTreeNode 树）。
//
// 供各「分类树 + 主档列表」页（货品/模具/客户/供应商资料页、即时库存、部门管理）复用：
// 用户在分类栏顶部搜索框输入关键词 → ① 分类名命中（本文件算）+ ② 主档命中（各页调各自
// repository.search 取 categoryId/departmentId）→ 合并为 visibleFilterIds 喂给树组件，
// 命中分类自动展开+定位。纯函数，无副作用，不持有状态。
import '../models/uten_tree_node.dart';
import '../models/paged_result.dart';

/// 节点名称或编号含 q 的节点 + 其全部祖先 +（自身命中时）其全部后代 的 id 集合。
///
/// 用于驱动 `UtenCategoryTreeView.visibleFilterIds`（或部门树同款参数）：命中分类的祖先链
/// 也要在集合里，树组件据此自动展开路径。自身命中的节点其整子树都算相关（子分类也显示）。
/// 名称/编号统一做 trim + 小写比较，避免桌面端输入英文编号时受大小写影响。
Set<String> categoryHits<T extends UtenTreeNode<T>>(List<T> roots, String q) {
  final normalized = q.trim().toLowerCase();
  if (normalized.isEmpty) return <String>{};
  final ids = <String>{};
  bool walk(List<T> nodes, List<String> ancestors) {
    var anyHit = false;
    for (final n in nodes) {
      final selfHit =
          n.name.toLowerCase().contains(normalized) ||
          n.code.toLowerCase().contains(normalized);
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

/// 命中集合里名称或编号含 q 的最浅节点 id（用于「仅分类命中」时自动定位选中）。
String? shallowestHit<T extends UtenTreeNode<T>>(
  List<T> roots,
  String q,
  Set<String> hits,
) {
  final normalized = q.trim().toLowerCase();
  if (normalized.isEmpty) return null;
  String? found;
  void walk(List<T> nodes) {
    for (final n in nodes) {
      final selfHit =
          n.name.toLowerCase().contains(normalized) ||
          n.code.toLowerCase().contains(normalized);
      if (found == null && hits.contains(n.id) && selfHit) {
        found = n.id;
      }
      walk(n.children);
    }
  }

  walk(roots);
  return found;
}

/// 一次「树节点 + 具体内容」关联搜索的纯函数结果。
///
/// [contentCategoryIds] 来自服务端主档搜索结果（货品/模具/客户/供应商/员工等）。
/// 只采纳当前可见树中真实存在的分类 id，避免旧后端、脏数据或受限 scope 返回树外 id
/// 后把页面选到一个无法展示的分类。调用方可依据 [ignoredContentCategoryCount] 给出提示。
class HierarchySearchResolution {
  const HierarchySearchResolution({
    required this.visibleIds,
    required this.contentCategoryIds,
    required this.selectedId,
    required this.ignoredContentCategoryCount,
  });

  final Set<String> visibleIds;
  final Set<String> contentCategoryIds;
  final String? selectedId;
  final int ignoredContentCategoryCount;

  bool get hasContentMatches => contentCategoryIds.isNotEmpty;
  bool get hasAnyMatches => visibleIds.isNotEmpty;
}

HierarchySearchResolution resolveHierarchySearch<T extends UtenTreeNode<T>>({
  required List<T> roots,
  required String query,
  Iterable<String?> contentCategoryIds = const <String?>[],
}) {
  final categoryMatches = categoryHits(roots, query);
  final allIds = <String>{};
  void collect(List<T> nodes) {
    for (final node in nodes) {
      allIds.add(node.id);
      collect(node.children);
    }
  }

  collect(roots);
  final validContentIds = <String>{};
  var ignored = 0;
  for (final rawId in contentCategoryIds) {
    final id = rawId?.trim();
    if (id == null || id.isEmpty || !allIds.contains(id)) {
      ignored++;
      continue;
    }
    validContentIds.add(id);
  }

  final visible = <String>{...categoryMatches};
  for (final id in validContentIds) {
    addAncestors(roots, id, visible);
  }
  return HierarchySearchResolution(
    visibleIds: visible,
    contentCategoryIds: validContentIds,
    selectedId: validContentIds.isNotEmpty
        ? validContentIds.first
        : shallowestHit(roots, query, categoryMatches),
    ignoredContentCategoryCount: ignored,
  );
}

/// 返回 [branchId] 所在子树是否包含任一 [targetIds]。
///
/// 统一搜索态点树节点时用它判断是否应保留业务关键词：命中分类本身或其祖先都应继续
/// 在右侧展示“该分类子树内的匹配内容”；无关的纯分类命中则仍展示该分类全部内容。
bool hierarchyBranchContainsAny<T extends UtenTreeNode<T>>(
  List<T> roots,
  String branchId,
  Set<String> targetIds,
) {
  if (targetIds.isEmpty) return false;

  T? find(List<T> nodes) {
    for (final node in nodes) {
      if (node.id == branchId) return node;
      final nested = find(node.children);
      if (nested != null) return nested;
    }
    return null;
  }

  bool contains(T node) {
    if (targetIds.contains(node.id)) return true;
    return node.children.any(contains);
  }

  final branch = find(roots);
  return branch != null && contains(branch);
}

/// 分页收集统一搜索结果所属的全部分类 id。
///
/// 页面只用这些 id 展开/定位左侧树；右侧列表仍保留自己的首屏或当前页，避免为了定位
/// 把全部主档对象留在内存中。[isCurrent] 在每次请求前后检查 request generation；一旦
/// 用户继续输入或离开当前搜索，立即停止后续分页并返回 `null`，调用方不得回写旧结果。
///
/// [seedPage] 可复用调用方已经拉到的首屏/当前页，防止重复请求该页。返回值去除空 id
/// 并按首次出现顺序去重；完整搜索但无内容命中时返回空集合。
Future<Set<String>?> collectPagedHierarchyCategoryIds<T>({
  required Future<PagedResult<T>> Function(int page) loadPage,
  required String? Function(T item) categoryIdOf,
  required bool Function() isCurrent,
  PagedResult<T>? seedPage,
}) async {
  if (!isCurrent()) return null;

  var firstPage = seedPage;
  if (firstPage == null) {
    firstPage = await loadPage(1);
    if (!isCurrent()) return null;
  }

  final ids = <String>{};
  void collect(PagedResult<T> page) {
    for (final item in page.items) {
      final id = categoryIdOf(item)?.trim();
      if (id != null && id.isNotEmpty) ids.add(id);
    }
  }

  collect(firstPage);
  final seedPageNumber = firstPage.page < 1 ? 1 : firstPage.page;
  var totalPages = firstPage.totalPages < 1 ? 1 : firstPage.totalPages;
  for (var page = 1; page <= totalPages; page++) {
    if (page == seedPageNumber) continue;
    if (!isCurrent()) return null;
    final result = await loadPage(page);
    if (!isCurrent()) return null;
    collect(result);
    if (result.totalPages > totalPages) totalPages = result.totalPages;
  }
  return ids;
}
