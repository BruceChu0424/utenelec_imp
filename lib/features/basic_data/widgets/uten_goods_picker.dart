// UtenGoodsPicker - 货品选择器（单据明细/报表选货品用）。
//
// 触发：函数式 showUtenGoodsPicker(context, ref) → 返回 GoodsListItem?。
// 形态仿 UtenDepartmentPicker：compact 底部抽屉（85% 屏高）/ medium+ 右侧滑入 720 宽面板。
// 内容：左分类树（UtenCategoryTreeView，排除原材料/辅料/未分类）+ 右货品列表（搜索+分页）。
// 点货品行即选中返回。分类树来自 productCategoryRepositoryProvider.tree()，货品来自
// goodsRepositoryProvider.list(分类子树)/search(全库)。
//
// 与旧 sales_goods_picker / goods_picker_dialog（居中搜索框）的区别：带分类树浏览、
// 返回完整 GoodsListItem（含 colorId/unitId 及展示名称；legacy 字段仅供历史只读显示），供调用方
// 自动回填颜色/单位。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';
import '../models/product_category_node.dart';
import '../repositories/goods_repository.dart';
import '../repositories/product_category_repository.dart';
import 'category_tree_search.dart';
import 'uten_category_tree_view.dart';

/// 货品选择器排除的根分类 legacyId（来自后端 material_categories 种子）：
/// 原材料=2113、辅料=2480、未分类=迁移虚拟孤儿根 -1。
const _excludedLegacyIds = {2113, 2480, -1};

/// 滑窗显示范围（按单据场景分流；默认 sellable 保持历史行为，零回归）。
enum UtenGoodsPickerScope {
  /// 成品/可售卖类：排除原材料/辅料/未分类（销售/生产/委外进仓等）。
  sellable,

  /// 原材料/辅料类：只保留原材料/辅料子树（采购/领料/物料反查等）。
  material,

  /// 全部：不过滤（调拨/其它出入库/盘点）。
  all,

  /// 组件选择（BOM 组装信息用）：只保留 原材料/半成品/辅料/OEM成品/OEM物料/OEM功能件 子树。
  component,

  /// 仅原材料（不含辅料）：货品「包装」字段选材料专用，比 [material] 更窄。
  rawMaterial,

  /// 除未分类外全部：只排除"未分类"孤儿根，原材料/辅料/半成品等其余分类都保留
  /// （问题 #17：销售订货明细选货品此前误用 [sellable] 把原材料也过滤掉了）。
  allExceptUncategorized,
}

/// 未分类（迁移虚拟孤儿根）legacyId。
const _uncategorizedLegacyId = -1;

/// 节点是否为"未分类"根。
bool _isUncategorizedRoot(ProductCategoryNode n) {
  if (n.legacyId == _uncategorizedLegacyId) return true;
  return n.name.contains('未分类');
}

/// allExceptUncategorized 范围：过滤掉"未分类"子树，其余原样保留。
List<ProductCategoryNode> _filterUncategorizedTree(
  List<ProductCategoryNode> nodes,
) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isUncategorizedRoot(n)) continue;
    out.add(
      ProductCategoryNode(
        id: n.id,
        code: n.code,
        name: n.name,
        level: n.level,
        parentId: n.parentId,
        sortOrder: n.sortOrder,
        legacyId: n.legacyId,
        children: _filterUncategorizedTree(n.children),
      ),
    );
  }
  return out;
}

/// material 范围保留的根分类 legacyId（原材料/辅料）。
/// 扩展点：若包装材料/五金配件是独立根且采购/领料需要，再加 legacyId 与下方关键字。
const _materialRootLegacyIds = {2113, 2480};
const _materialRootNameKeywords = {'原材料', '辅料'};

/// component 范围保留的根分类 legacyId（BOM 组件选择器）：
/// 原材料 2113 / 半成品 2149 / 辅料 2480 / OEM成品 2304 / OEM物料 2305 / OEM功能件 2460。
/// legacyId 源：docs/数据迁移/02-货品分类-老库溯源.md §3.1 九根节点。
const _componentRootLegacyIds = {2113, 2149, 2480, 2304, 2305, 2460};
const _componentRootNameKeywords = {'原材料', '半成品', '辅料', 'OEM'};

/// 名称兜底判断（legacyId 缺失或新增同名分类时仍能排除）。
bool _isExcludedCategory(ProductCategoryNode n) {
  if (n.legacyId != null && _excludedLegacyIds.contains(n.legacyId)) {
    return true;
  }
  final name = n.name;
  return name.contains('原材料') || name.contains('辅料') || name.contains('未分类');
}

/// 递归过滤分类树：命中排除规则的节点整子树丢弃；其余保留并对 children 递归过滤。
/// 返回新森林副本，不影响调用方原树（如货品资料页直接用 productCategoryRepositoryProvider.tree()）。
List<ProductCategoryNode> _filterExcludedTree(List<ProductCategoryNode> nodes) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isExcludedCategory(n)) continue; // 整子树丢弃
    out.add(
      ProductCategoryNode(
        id: n.id,
        code: n.code,
        name: n.name,
        level: n.level,
        parentId: n.parentId,
        sortOrder: n.sortOrder,
        legacyId: n.legacyId,
        children: _filterExcludedTree(n.children),
      ),
    );
  }
  return out;
}

/// 节点是否属于 material 范围根（原材料/辅料）。
bool _isMaterialRoot(ProductCategoryNode n) {
  if (n.legacyId != null && _materialRootLegacyIds.contains(n.legacyId)) {
    return true;
  }
  final name = n.name;
  return _materialRootNameKeywords.any(name.contains);
}

/// material 范围：只保留命中（原材料/辅料）的节点整子树。
/// 命中节点的非命中祖先丢弃（命中节点升为新森林的根）。是 _filterExcludedTree 的逆操作。
List<ProductCategoryNode> _keepMaterialTree(List<ProductCategoryNode> nodes) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isMaterialRoot(n)) {
      // 命中：整子树保留（命中节点下所有子分类都算材料，不再过滤 children）。
      out.add(_cloneSubtree(n));
    } else {
      // 未命中：递归往下找命中的后代（后代升为新森林根）。
      out.addAll(_keepMaterialTree(n.children));
    }
  }
  return out;
}

/// 节点是否属于 component 范围根（原材料/半成品/辅料/OEM 系列）。
bool _isComponentRoot(ProductCategoryNode n) {
  if (n.legacyId != null && _componentRootLegacyIds.contains(n.legacyId)) {
    return true;
  }
  final name = n.name;
  return _componentRootNameKeywords.any(name.contains);
}

/// component 范围（BOM 组件选择器）：只保留命中的节点整子树，与 _keepMaterialTree 同构。
List<ProductCategoryNode> _keepComponentTree(List<ProductCategoryNode> nodes) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isComponentRoot(n)) {
      out.add(_cloneSubtree(n));
    } else {
      out.addAll(_keepComponentTree(n.children));
    }
  }
  return out;
}

/// rawMaterial 范围保留的根分类 legacyId（原材料，不含辅料）。
const _rawMaterialRootLegacyIds = {2113};

/// 节点是否属于原材料根（不含辅料，与名称含"辅料"区分）。
bool _isRawMaterialRoot(ProductCategoryNode n) {
  if (n.legacyId != null && _rawMaterialRootLegacyIds.contains(n.legacyId)) {
    return true;
  }
  return n.name.contains('原材料');
}

/// rawMaterial 范围：只保留原材料子树，与 _keepMaterialTree 同构但排除辅料。
List<ProductCategoryNode> _keepRawMaterialTree(
  List<ProductCategoryNode> nodes,
) {
  final out = <ProductCategoryNode>[];
  for (final n in nodes) {
    if (_isRawMaterialRoot(n)) {
      out.add(_cloneSubtree(n));
    } else {
      out.addAll(_keepRawMaterialTree(n.children));
    }
  }
  return out;
}

/// 深拷贝整子树（命中节点保留全部后代用）。
ProductCategoryNode _cloneSubtree(ProductCategoryNode n) {
  return ProductCategoryNode(
    id: n.id,
    code: n.code,
    name: n.name,
    level: n.level,
    parentId: n.parentId,
    sortOrder: n.sortOrder,
    legacyId: n.legacyId,
    children: [for (final c in n.children) _cloneSubtree(c)],
  );
}

/// 弹出货品选择器，返回所选货品（完整 GoodsListItem）；取消返回 null。
///
/// [requireConfirm]：默认 true（全站滑窗统一二次操作契约：点行只高亮勾选，
/// 底部「取消/确定」确认后才返回）。传 false 恢复点行即选中并关闭的历史行为。
Future<GoodsListItem?> showUtenGoodsPicker(
  BuildContext context,
  WidgetRef ref, {
  UtenGoodsPickerScope scope = UtenGoodsPickerScope.sellable,
  bool requireConfirm = true,
}) {
  return _presentSheet<GoodsListItem>(
    context,
    ref,
    scope,
    multiSelect: false,
    requireConfirm: requireConfirm,
  ).then((r) => r is GoodsListItem ? r : null);
}

/// 多选货品选择器：点货品行勾选/取消，底部「确定(N)」返回所选列表；取消返回空列表。
/// 供 BOM 组装信息「一个层级添加多个组件」批量录入用。
Future<List<GoodsListItem>> showUtenGoodsPickerMulti(
  BuildContext context,
  WidgetRef ref, {
  UtenGoodsPickerScope scope = UtenGoodsPickerScope.component,
}) async {
  final r = await _presentSheet<List<GoodsListItem>>(
    context,
    ref,
    scope,
    multiSelect: true,
  );
  return r ?? const <GoodsListItem>[];
}

Future<T?> _presentSheet<T>(
  BuildContext context,
  WidgetRef ref,
  UtenGoodsPickerScope scope, {
  required bool multiSelect,
  bool requireConfirm = false,
}) async {
  List<ProductCategoryNode> tree;
  try {
    final raw = await ref.read(productCategoryRepositoryProvider).tree();
    tree = switch (scope) {
      UtenGoodsPickerScope.sellable => _filterExcludedTree(raw),
      UtenGoodsPickerScope.material => _keepMaterialTree(raw),
      UtenGoodsPickerScope.all => raw,
      UtenGoodsPickerScope.component => _keepComponentTree(raw),
      UtenGoodsPickerScope.rawMaterial => _keepRawMaterialTree(raw),
      UtenGoodsPickerScope.allExceptUncategorized => _filterUncategorizedTree(
        raw,
      ),
    };
  } catch (_) {
    if (context.mounted) context.appError('货品分类加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  if (tree.isEmpty) {
    context.appWarning('当前业务范围没有可选择的货品分类');
    return null;
  }
  final sheet = _GoodsPickerSheet(
    tree: tree,
    scope: scope,
    multiSelect: multiSelect,
    requireConfirm: requireConfirm,
  );
  return showUtenAdaptivePanel<T>(
    context: context,
    drawerWidth: 720,
    builder: (_) => sheet,
  );
}

class _GoodsPickerSheet extends ConsumerStatefulWidget {
  const _GoodsPickerSheet({
    required this.tree,
    required this.scope,
    this.multiSelect = false,
    this.requireConfirm = false,
  });
  final List<ProductCategoryNode> tree;
  final UtenGoodsPickerScope scope;
  final bool multiSelect;

  /// 单选模式下是否需要底部「确定」二次确认（而非点行即关闭）。多选模式恒需确认，此项无效。
  final bool requireConfirm;

  @override
  ConsumerState<_GoodsPickerSheet> createState() => _GoodsPickerSheetState();
}

class _GoodsPickerSheetState extends ConsumerState<_GoodsPickerSheet> {
  String? _selectedCategoryId;
  final _keywordCtl = TextEditingController();
  String _query = '';
  Set<String>? _visibleFilterIds;
  bool _showingGlobalResults = false;
  bool _searchLoading = false;
  String? _searchError;
  String? _globalResolutionQuery;
  HierarchySearchResolution? _globalResolution;
  int _requestVersion = 0;
  int _page = 1;
  PagedResult<GoodsListItem>? _paged;
  bool _loading = false;
  String? _error;

  /// 多选模式下已勾选的货品（id → 完整 item）。
  final Map<String, GoodsListItem> _selected = {};

  @override
  void initState() {
    super.initState();
    // 懒载：预选第一个根分类（树高亮，用户有定位感），但不立即加载货品列表。
    // 输关键词或点分类才加载（省资源）。
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
    }
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
  }

  void _onCategoryTap(ProductCategoryNode node) {
    _requestVersion++;
    final categoryKeyword = _keywordForCategoryBranch(node.id);
    setState(() {
      _selectedCategoryId = node.id;
      _showingGlobalResults = false;
      _searchLoading = false;
      _searchError = null;
      _page = 1;
    });
    _reloadCategory(keyword: categoryKeyword);
  }

  /// 输入一变化就让飞行中的旧请求失效（UtenSearchBar 的 300ms 防抖期间旧结果不
  /// 回写），并同步更新左侧树的命中过滤；防抖到期后由 [_onKeywordChanged] 检索。
  void _onKeywordInputChanged(String v) {
    _requestVersion++;
    final query = v.trim();
    setState(() {
      _query = query;
      _page = 1;
      _visibleFilterIds = query.isEmpty
          ? null
          : categoryHits(widget.tree, query);
      _searchLoading = query.isNotEmpty;
      _searchError = null;
      _globalResolutionQuery = null;
      _globalResolution = null;
      if (query.isNotEmpty) _loading = true;
    });
  }

  void _onKeywordChanged(String v) {
    if (!mounted) return;
    _applySearch(v.trim());
  }

  Future<void> _applySearch(String query) async {
    if (!mounted || query != _keywordCtl.text.trim()) return;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _visibleFilterIds = null;
        _showingGlobalResults = false;
        _searchLoading = false;
        _searchError = null;
        _globalResolutionQuery = null;
        _globalResolution = null;
        _selectedCategoryId ??= widget.tree.isEmpty
            ? null
            : widget.tree.first.id;
        _page = 1;
      });
      await _reloadCategory();
      return;
    }

    setState(() {
      _query = query;
      _showingGlobalResults = true;
      _searchLoading = true;
      _page = 1;
    });
    await _reloadGlobalSearch(allowCategoryFallback: true);
  }

  Set<String> get _scopeRootIds => {for (final root in widget.tree) root.id};

  Set<String> get _scopeCategoryIds {
    final ids = <String>{};
    void collect(List<ProductCategoryNode> nodes) {
      for (final node in nodes) {
        ids.add(node.id);
        collect(node.children);
      }
    }

    collect(widget.tree);
    return ids;
  }

  /// 分类名称/编号本身命中时，点分类应展示该分类的全部可选货品；只有该分支
  /// 确实包含货品字段命中时才继续携带关键词做子树内过滤。
  String? _keywordForCategoryBranch(String? categoryId) {
    if (categoryId == null ||
        _query.isEmpty ||
        _globalResolutionQuery != _query) {
      return null;
    }
    final contentCategoryIds =
        _globalResolution?.contentCategoryIds ?? const <String>{};
    return hierarchyBranchContainsAny(
          widget.tree,
          categoryId,
          contentCategoryIds,
        )
        ? _query
        : null;
  }

  Future<void> _reloadCategory({String? keyword}) async {
    final categoryId = _selectedCategoryId;
    final requestedPage = _page;
    final requestVersion = ++_requestVersion;
    if (categoryId == null) {
      if (!mounted) return;
      setState(() {
        _paged = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(goodsRepositoryProvider)
          .list(
            categoryId,
            page: requestedPage,
            keyword: keyword,
            excludeDisabled: true,
            excludeStub: true,
          );
      if (!mounted ||
          requestVersion != _requestVersion ||
          categoryId != _selectedCategoryId ||
          requestedPage != _page) {
        return;
      }
      setState(() {
        _paged = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = keyword == null ? '加载货品失败，请稍后重试' : '搜索货品失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<void> _reloadGlobalSearch({
    required bool allowCategoryFallback,
  }) async {
    final query = _query;
    final requestedPage = _page;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
      _searchLoading = true;
      _searchError = null;
    });
    try {
      final repo = ref.read(goodsRepositoryProvider);
      final needsLocation =
          _globalResolutionQuery != query || _globalResolution == null;
      final responses = await Future.wait<Object>([
        repo.search(
          query,
          page: requestedPage,
          size: 100,
          categoryRootIds: _scopeRootIds,
          excludeDisabled: true,
          excludeStub: true,
        ),
        if (needsLocation)
          repo.searchCategoryIds(
            query,
            categoryRootIds: _scopeRootIds,
            excludeDisabled: true,
            excludeStub: true,
          ),
      ]);
      final result = responses.first as PagedResult<GoodsListItem>;
      if (!mounted ||
          requestVersion != _requestVersion ||
          query != _query ||
          requestedPage != _page) {
        return;
      }

      // 服务端 categoryRootIds 是权威分页范围；客户端再做 fail-closed 校验，避免旧服务端
      // 忽略新参数或旧 DTO 缺 categoryId 时把 scope 外货品展示给当前业务选择器。
      final allowedCategoryIds = _scopeCategoryIds;
      if (result.items.any((goods) {
        final categoryId = goods.categoryId;
        return categoryId == null || !allowedCategoryIds.contains(categoryId);
      })) {
        throw StateError('goods search returned an item outside picker scope');
      }

      final pageResolution = resolveHierarchySearch(
        roots: widget.tree,
        query: query,
        contentCategoryIds: result.items.map((goods) => goods.categoryId),
      );
      final HierarchySearchResolution resolution;
      if (needsLocation) {
        final matchingCategoryIds = responses[1] as Set<String>;
        if (matchingCategoryIds.any(
          (categoryId) => !allowedCategoryIds.contains(categoryId),
        )) {
          throw StateError(
            'goods location search returned a category outside picker scope',
          );
        }
        resolution = resolveHierarchySearch(
          roots: widget.tree,
          query: query,
          contentCategoryIds: matchingCategoryIds,
        );
      } else {
        resolution = _globalResolution!;
      }
      if (result.items.isEmpty &&
          allowCategoryFallback &&
          requestedPage == 1 &&
          resolution.selectedId != null) {
        final categoryId = resolution.selectedId!;
        // 只命中分类名称/编号时，右侧展示该分类内容；分类词不强行套到货品字段上。
        final categoryPage = await repo.list(
          categoryId,
          excludeDisabled: true,
          excludeStub: true,
        );
        if (!mounted ||
            requestVersion != _requestVersion ||
            query != _query ||
            requestedPage != _page) {
          return;
        }
        setState(() {
          _globalResolutionQuery = query;
          _globalResolution = resolution;
          _selectedCategoryId = categoryId;
          _visibleFilterIds = resolution.visibleIds;
          _showingGlobalResults = false;
          _paged = categoryPage;
          _loading = false;
          _searchLoading = false;
        });
        return;
      }

      setState(() {
        _globalResolutionQuery = query;
        _globalResolution = resolution;
        _selectedCategoryId =
            pageResolution.selectedId ?? resolution.selectedId;
        _visibleFilterIds = resolution.visibleIds;
        _showingGlobalResults = true;
        _paged = result;
        _loading = false;
        _searchLoading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '搜索货品失败，请稍后重试';
        _searchError = _error;
        _loading = false;
        _searchLoading = false;
      });
    }
  }

  void _reloadCurrentPage() {
    if (_query.isNotEmpty && _showingGlobalResults) {
      _reloadGlobalSearch(allowCategoryFallback: false);
    } else {
      _reloadCategory(keyword: _keywordForCategoryBranch(_selectedCategoryId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final treeWidth = context.breakpoint.isCompact ? 176.0 : 240.0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选择货品',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: treeWidth,
                child: UtenCategoryTreeView<ProductCategoryNode>(
                  nodes: widget.tree,
                  mode: UtenCategoryTreeMode.single,
                  selectedIds: _selectedCategoryId == null
                      ? const <String>{}
                      : <String>{_selectedCategoryId!},
                  expandOnRowTap: true,
                  initiallyCollapsedNames: const {'未分类'},
                  showSearch: false,
                  visibleFilterIds: _visibleFilterIds,
                  externalSearchQuery: _query,
                  externalSearchLoading: _searchLoading,
                  externalSearchError: _searchError,
                  header: _buildUnifiedSearch(),
                  onToggleSelect: _onCategoryTap,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildRightPane(theme)),
            ],
          ),
        ),
        if (widget.multiSelect || widget.requireConfirm)
          _buildConfirmBar(theme),
      ],
    );
  }

  Widget _buildConfirmBar(ThemeData theme) {
    final single = _selected.isEmpty ? null : _selected.values.first;
    return UtenPickerConfirmBar(
      selectedCount: _selected.length,
      selectedLabel: widget.multiSelect || single == null
          ? null
          : _goodsLabel(single),
      onClear: widget.multiSelect ? () => setState(_selected.clear) : null,
      confirmLabel: widget.multiSelect ? '确定(${_selected.length})' : '确定',
      onConfirm: () =>
          Navigator.of(context)
              .pop(widget.multiSelect ? _selected.values.toList() : single),
    );
  }

  String _goodsLabel(GoodsListItem g) =>
      '${g.name ?? '—'}'
      '${g.code != null && g.code!.isNotEmpty ? '(${g.code})' : ''}';

  Widget _buildRightPane(ThemeData theme) {
    return Column(
      children: [
        Expanded(child: _buildGoodsList(theme)),
        if (_paged != null && _paged!.totalPages > 1) _buildPager(theme),
      ],
    );
  }

  Widget _buildUnifiedSearch() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.breakpoint.isCompact ? 8 : 16,
        8,
        context.breakpoint.isCompact ? 8 : 16,
        8,
      ),
      child: UtenSearchBar(
        key: const Key('uten-goods-picker-search'),
        controller: _keywordCtl,
        hint: '搜索分类/货品名称或编号',
        onInputChanged: _onKeywordInputChanged,
        onChanged: _onKeywordChanged,
      ),
    );
  }

  Widget _buildGoodsList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final page = _paged;
    if (page == null) {
      return Center(
        child: Text(
          widget.tree.isEmpty ? '没有可选择的货品分类' : '请选择左侧分类或搜索货品',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    if (page.items.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? '该分类暂无可选货品' : '未找到匹配「$_query」的货品',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: page.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final g = page.items[i];
        final sub = [
          // 库位号放最前：仓库按挂牌拣货/上架时第一眼要看的就是位置。
          if (g.stockPlace != null && g.stockPlace!.isNotEmpty)
            '库位 ${g.stockPlace}',
          g.spec,
          g.colorName,
          g.unitName,
        ].where((s) => s != null && s.isNotEmpty).join(' · ');
        final picked = _selected.containsKey(g.id);
        final showPicked =
            (widget.multiSelect || widget.requireConfirm) && picked;
        return ListTile(
          selected: showPicked,
          title: Text(
            '${g.name ?? '—'}'
            '${g.code != null && g.code!.isNotEmpty ? '(${g.code})' : ''}',
          ),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: theme.textTheme.bodySmall),
          trailing: showPicked
              ? Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                )
              : null,
          onTap: () {
            if (widget.multiSelect) {
              setState(() {
                if (_selected.containsKey(g.id)) {
                  _selected.remove(g.id);
                } else {
                  _selected[g.id] = g;
                }
              });
            } else if (widget.requireConfirm) {
              setState(() {
                _selected
                  ..clear()
                  ..[g.id] = g;
              });
            } else {
              Navigator.of(context).pop(g);
            }
          },
        );
      },
    );
  }

  Widget _buildPager(ThemeData theme) {
    final page = _paged!;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: page.page > 1
                ? () {
                    setState(() => _page = page.page - 1);
                    _reloadCurrentPage();
                  }
                : null,
          ),
          Text('${page.page} / ${page.totalPages}'),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: page.page < page.totalPages
                ? () {
                    setState(() => _page = page.page + 1);
                    _reloadCurrentPage();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
