// UtenGoodsPicker - 货品选择器（单据明细/报表选货品用）。
//
// 触发：函数式 showUtenGoodsPicker(context, ref) → 返回 GoodsListItem?。
// 形态仿 UtenDepartmentPicker：compact 底部抽屉（85% 屏高）/ medium+ 右侧滑入面板。
// 宽度跟屏幕自适应（2026-09-24 用户口径：滑窗再大点，约占屏宽 50%，下限 720）。
// 内容：左分类树 + 右货品明细表（名称/编号/系列/型号/规格/颜色/单位，列搜索+分页），中间是可拖分割线（UtenSplitView，
// 与货品资料页同款；默认宽度 = 左侧最长一行内容的实测宽度，可拖可双击复位）。
// 左树用无缩进层级色模式（flatLevelColors）：一级深绿白字、二级浅灰、三级更浅，
// 整库只有「货品资料」一个根分类时自动提升，直接列原材料/半成品/成品等子类。
// 分类树来自 productCategoryRepositoryProvider.tree()，货品来自
// goodsRepositoryProvider.list(分类子树)/search(全库)。
//
// 多选（showUtenGoodsPickerMulti）：底部「已选 N 项」胶囊可点，点开从底部滑出
// 已选清单滑层，可逐项取消；「确定(N)」返回所选列表。
//
// 与旧 sales_goods_picker / goods_picker_dialog（居中搜索框）的区别：带分类树浏览、
// 返回完整 GoodsListItem（含 colorId/unitId 及展示名称；legacy 字段仅供历史只读显示），供调用方
// 自动回填颜色/单位。
import 'dart:async';

import '../../../core/theme/uten_tokens.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../components/layout/uten_picker_footer_layout.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/hierarchy/uten_tree_path.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';
import '../models/master_facet.dart';
import '../models/product_category_node.dart';
import '../repositories/goods_facet_repository.dart';
import '../repositories/goods_repository.dart';
import '../repositories/product_category_repository.dart';
import 'category_tree_search.dart';
import 'goods_related_search_control.dart';
import 'uten_category_tree_view.dart';
import 'master_data_table_view.dart';

/// 货品选择器排除的根分类 legacyId（来自后端 material_categories 种子）：
/// 原材料=2113、辅料=2480、未分类=迁移虚拟孤儿根 -1。
const _excludedLegacyIds = {2113, 2480, -1};

/// 右侧列表默认排序：与货品资料页同款（编号升序，服务端白名单键 code）。
/// 货品资料页对应 product_category_page 的 defaultSortKey: 'code'（升序）。
const _goodsPickerSort = 'code';
const _goodsPickerOrder = 'asc';

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
        remark: n.remark,
        codePrefix: n.codePrefix,
        systemManaged: n.systemManaged,
        goodsCount: n.goodsCount,
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
        remark: n.remark,
        codePrefix: n.codePrefix,
        systemManaged: n.systemManaged,
        goodsCount: n.goodsCount,
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
    remark: n.remark,
    codePrefix: n.codePrefix,
    systemManaged: n.systemManaged,
    goodsCount: n.goodsCount,
    children: [for (final c in n.children) _cloneSubtree(c)],
  );
}

List<ProductCategoryNode> _treeForScope(
  List<ProductCategoryNode> raw,
  UtenGoodsPickerScope scope,
) => switch (scope) {
  UtenGoodsPickerScope.sellable => _filterExcludedTree(raw),
  UtenGoodsPickerScope.material => _keepMaterialTree(raw),
  UtenGoodsPickerScope.all => raw,
  UtenGoodsPickerScope.component => _keepComponentTree(raw),
  UtenGoodsPickerScope.rawMaterial => _keepRawMaterialTree(raw),
  UtenGoodsPickerScope.allExceptUncategorized => _filterUncategorizedTree(raw),
};

/// Approximate candidates obey the same initial business scope as the full picker.
Future<List<GoodsListItem>> loadUtenGoodsPickerSuggestions(
  WidgetRef ref,
  String query, {
  UtenGoodsPickerScope scope = UtenGoodsPickerScope.component,
}) async {
  if (query.trim().isEmpty) return const [];
  final boundary = ref.read(sensitiveReadBoundaryProvider);
  final tree = _treeForScope(
    await ref.read(productCategoryRepositoryProvider).tree(),
    scope,
  );
  if (tree.isEmpty) return const [];
  if (boundary != ref.read(sensitiveReadBoundaryProvider)) {
    throw StateError('查找身份已变化，请重新输入');
  }
  final allowed = <String>{};
  void collect(ProductCategoryNode node) {
    allowed.add(node.id);
    node.children.forEach(collect);
  }

  tree.forEach(collect);
  final result = await ref
      .read(goodsRepositoryProvider)
      .search(
        query,
        size: 8,
        categoryRootIds: {for (final root in tree) root.id},
        excludeDisabled: true,
        excludeStub: true,
        sort: _goodsPickerSort,
        order: _goodsPickerOrder,
      );
  if (boundary != ref.read(sensitiveReadBoundaryProvider)) {
    throw StateError('查找身份已变化，请重新输入');
  }
  if (result.items.any((goods) => !allowed.contains(goods.categoryId))) {
    throw StateError('goods suggestion returned an item outside picker scope');
  }
  return result.items;
}

/// 弹出货品选择器，返回所选货品（完整 GoodsListItem）；取消返回 null。
///
/// 全站选择滑窗统一二次操作：点行只高亮勾选，底部「确定」后才返回。
Future<GoodsListItem?> showUtenGoodsPicker(
  BuildContext context,
  WidgetRef ref, {
  UtenGoodsPickerScope scope = UtenGoodsPickerScope.sellable,
  UtenGoodsPickerDataSource? dataSource,
  String title = '选择货品',
  SensitiveReadBoundary? readBoundary,
  String initialKeyword = '',
}) {
  return _presentSheet<GoodsListItem>(
    context,
    ref,
    scope,
    multiSelect: false,
    dataSource: dataSource,
    title: title,
    readBoundary: readBoundary,
    initialKeyword: initialKeyword,
  ).then((r) => r is GoodsListItem ? r : null);
}

/// 多选货品选择器：点货品行勾选/取消，底部「确定(N)」返回所选列表；取消返回空列表。
/// 供 BOM 组装信息「一个层级添加多个组件」批量录入用。
/// 业务候选可提供独立数据源，复用分类树、多选清单与分页交互。
abstract class UtenGoodsPickerDataSource {
  /// Dedicated inventory/report sources keep their own API and permission scope.
  /// Sources opting in also implement both option-aware search methods below.
  bool get supportsRelatedSearch => false;
  Future<List<ProductCategoryNode>> tree();
  Future<PagedResult<GoodsListItem>> list(
    String categoryId, {
    required int page,
    String? keyword,
  });
  Future<PagedResult<GoodsListItem>> search(
    String keyword, {
    required int page,
  });
  Future<Set<String>> searchCategoryIds(String keyword);

  Future<PagedResult<GoodsListItem>> searchWithOptions(
    String keyword, {
    required int page,
    String? categoryId,
    bool includeRelated = false,
  }) {
    if (includeRelated) {
      throw UnsupportedError('Related search is not supported by this source');
    }
    return categoryId == null
        ? search(keyword, page: page)
        : list(categoryId, page: page, keyword: keyword);
  }

  Future<Set<String>> searchCategoryIdsWithOptions(
    String keyword, {
    String? categoryId,
    bool includeRelated = false,
  }) {
    if (includeRelated) {
      throw UnsupportedError('Related search is not supported by this source');
    }
    return searchCategoryIds(keyword);
  }

  bool isSelectable(GoodsListItem goods) => true;

  /// Source-specific fields keep stock snapshots and historical evidence in
  /// explicit columns. Selection, confirmation and pagination remain shared.
  List<MasterColumnDef<GoodsListItem>>? get pickerColumns => null;
}

String _pickerErrorMessage(Object error, String fallback) =>
    error is ApiException ? error.message : fallback;

Future<List<GoodsListItem>> showUtenGoodsPickerMulti(
  BuildContext context,
  WidgetRef ref, {
  UtenGoodsPickerScope scope = UtenGoodsPickerScope.component,
  UtenGoodsPickerDataSource? dataSource,
  String title = '选择货品',
  SensitiveReadBoundary? readBoundary,
  bool allowScopeExpansion = false,
  String initialKeyword = '',
}) async {
  final r = await _presentSheet<List<GoodsListItem>>(
    context,
    ref,
    scope,
    multiSelect: true,
    dataSource: dataSource,
    title: title,
    readBoundary: readBoundary,
    allowScopeExpansion: allowScopeExpansion,
    initialKeyword: initialKeyword,
  );
  return r ?? const <GoodsListItem>[];
}

Future<T?> _presentSheet<T>(
  BuildContext context,
  WidgetRef ref,
  UtenGoodsPickerScope scope, {
  required bool multiSelect,
  UtenGoodsPickerDataSource? dataSource,
  String title = '选择货品',
  SensitiveReadBoundary? readBoundary,
  bool allowScopeExpansion = false,
  String initialKeyword = '',
}) async {
  // Capture invalidation before awaiting the tree as well as while the panel is
  // open. A revoke/regrant during that await must never reopen an old snapshot.
  var boundaryChanged =
      readBoundary != null &&
      readBoundary != ref.read(sensitiveReadBoundaryProvider);
  final subscription = readBoundary == null
      ? null
      : ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
          if (next != readBoundary) boundaryChanged = true;
        });
  try {
    if (boundaryChanged) return null;
    List<ProductCategoryNode> tree;
    List<ProductCategoryNode>? allTree;
    try {
      final raw =
          await (dataSource?.tree() ??
              ref.read(productCategoryRepositoryProvider).tree());
      if (allowScopeExpansion &&
          dataSource == null &&
          scope == UtenGoodsPickerScope.component) {
        allTree = raw;
      }
      tree = _treeForScope(raw, scope);
    } catch (error) {
      if (context.mounted && !boundaryChanged) {
        context.appError(_pickerErrorMessage(error, '货品分类加载失败，请稍后重试'));
      }
      return null;
    }
    if (!context.mounted || boundaryChanged) return null;
    // 单根提升：整库只有一个「货品资料」包装根时不占一层。
    final scopeTree = tree;
    if (dataSource == null) tree = hoistSingleRootTree(tree);
    if (tree.isEmpty && (allTree?.isEmpty ?? true)) {
      context.appWarning('当前业务范围没有可选择的货品分类');
      return null;
    }
    final sheet = _GoodsPickerSheet(
      tree: tree,
      scopeTree: scopeTree,
      scope: scope,
      multiSelect: multiSelect,
      dataSource: dataSource,
      title: title,
      readBoundary: readBoundary,
      allTree: allTree,
      initialKeyword: initialKeyword,
    );
    // 滑窗宽度口径 2026-10-17：比例优先（browse 档 75% 屏宽），720 只作小屏下限——
    // 旧口径 max(720, 50%) 在大屏上占比缩水，表格列挤成一团。
    final result = await showUtenAdaptivePanel<T>(
      context: context,
      drawerWidth: 720,
      builder: (_) => sheet,
    );
    return boundaryChanged ? null : result;
  } finally {
    subscription?.close();
  }
}

class _GoodsPickerSheet extends ConsumerStatefulWidget {
  const _GoodsPickerSheet({
    required this.tree,
    required this.scopeTree,
    required this.scope,
    this.multiSelect = false,
    this.dataSource,
    this.title = '选择货品',
    this.readBoundary,
    this.allTree,
    this.initialKeyword = '',
  });
  final List<ProductCategoryNode> tree;
  final List<ProductCategoryNode> scopeTree;
  final List<ProductCategoryNode>? allTree;
  final UtenGoodsPickerScope scope;
  final bool multiSelect;
  final UtenGoodsPickerDataSource? dataSource;
  final String title;
  final SensitiveReadBoundary? readBoundary;
  final String initialKeyword;

  @override
  ConsumerState<_GoodsPickerSheet> createState() => _GoodsPickerSheetState();
}

class _GoodsPickerSheetState extends ConsumerState<_GoodsPickerSheet> {
  String? _selectedCategoryId;
  String? _searchCategoryId;
  bool _includeRelated = false;
  bool _expandedScope = false;
  List<ProductCategoryNode> get _tree =>
      _expandedScope ? hoistSingleRootTree(widget.allTree!) : widget.tree;
  List<ProductCategoryNode> get _scopeTree =>
      _expandedScope ? widget.allTree! : widget.scopeTree;
  bool get _supportsRelatedSearch =>
      widget.dataSource?.supportsRelatedSearch ?? true;
  final _keywordCtl = TextEditingController();
  String _query = '';
  Set<String>? _visibleFilterIds;
  bool _showingGlobalResults = false;
  bool _searchLoading = false;
  String? _searchError;
  String? _globalResolutionQuery;
  HierarchySearchResolution? _globalResolution;
  int _requestVersion = 0;
  bool _acceptPendingSearch = false;
  int _page = 1;
  PagedResult<GoodsListItem>? _paged;
  bool _loading = false;
  String? _error;

  /// 多选模式下已勾选的货品（id → 完整 item）。
  final Map<String, GoodsListItem> _selected = {};

  /// 表头筛选下拉的候选桶：随当前查询上下文（所选分类 / 搜索范围 + 列筛选）
  /// 重拉（2026-10-19「滑窗筛选无匹配项」修复——此前滑窗从未接入任何候选来源，
  /// 漏斗下拉恒空）。facets 是可选增强：失败静默，列表与关键字搜索不受影响。
  GoodsFacets? _facets;

  /// 多选模式：底部「已选 N 项」滑层是否展开。
  final _pickerRows = MasterDataTableRowsController<GoodsListItem>();
  final Map<String, String?> _columnFilters = {};
  bool get _supportsColumnSearch => widget.dataSource == null;
  bool _selectedPanelOpen = false;

  /// 左树自然宽度缓存（见 [_treeNaturalWidth]）。
  double? _naturalTreeWidth;
  bool _boundaryChanged = false;
  bool _closeScheduled = false;

  bool get _canRead =>
      !_boundaryChanged &&
      (widget.readBoundary == null ||
          widget.readBoundary == ref.read(sensitiveReadBoundaryProvider));

  void _closeStaleRoute() {
    if (_closeScheduled) return;
    _closeScheduled = true;
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route?.navigator;
      if (route == null || navigator == null || !route.isActive) return;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  void _confirm(Object? value, {required int requestVersion}) {
    if (_canRead &&
        requestVersion == _requestVersion &&
        !_loading &&
        !_searchLoading) {
      Navigator.of(context).pop(value);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.readBoundary != null) {
      _boundaryChanged =
          widget.readBoundary != ref.read(sensitiveReadBoundaryProvider);
      ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
        if (next == widget.readBoundary || !mounted || _boundaryChanged) return;
        ++_requestVersion;
        setState(() {
          _boundaryChanged = true;
          _paged = null;
          _selected.clear();
          _globalResolution = null;
          _globalResolutionQuery = null;
          _selectedPanelOpen = false;
        });
        _closeStaleRoute();
      });
    }
    // 懒载：预选第一个根分类（树高亮，用户有定位感），但不立即加载货品列表。
    // 输关键词或点分类才加载（省资源）。
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
    }
    if (widget.initialKeyword.trim().isNotEmpty) {
      _keywordCtl.text = widget.initialKeyword.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _onKeywordInputChanged(_keywordCtl.text);
        _onKeywordChanged(_keywordCtl.text);
      });
    }
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
  }

  /// 左树默认宽度 = 全树最长一行「名称(编码)」的实测文字宽 + 行内装具
  ///（2026-09-24 用户口径：默认划分就是左边内容最宽那行的宽度；层级多/名字长
  /// 时不再靠 240 固定宽硬截断）。量宽只算一次；超出 maxLeadingWidth 的部分
  /// 交给省略号与可拖分割线。
  double _treeNaturalWidth(ThemeData theme) {
    return _naturalTreeWidth ??= measureCategoryTreeNaturalWidth(
      widget.tree,
      theme.textTheme.bodyMedium,
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

  void _onCategoryTap(ProductCategoryNode node) {
    if (_query.isNotEmpty) {
      setState(() => _searchCategoryId = node.id);
      _restartSearch();
      return;
    }
    _requestVersion++;
    _acceptPendingSearch = false;
    setState(() {
      _selectedCategoryId = node.id;
      _paged = null;
      _showingGlobalResults = false;
      _searchLoading = false;
      _searchError = null;
      _page = 1;
    });
    _reloadCategory();
  }

  /// 输入一变化就让飞行中的旧请求失效（UtenSearchBar 的 300ms 防抖期间旧结果不
  /// 回写），并同步更新左侧树的命中过滤；防抖到期后由 [_onKeywordChanged] 检索。
  void _onKeywordInputChanged(String v) {
    _requestVersion++;
    _acceptPendingSearch = true;
    final query = v.trim();
    setState(() {
      _query = query;
      if (query.isEmpty) {
        _includeRelated = false;
        _searchCategoryId = null;
      }
      _paged = null;
      _page = 1;
      _visibleFilterIds = query.isEmpty ? null : categoryHits(_tree, query);
      _searchLoading = query.isNotEmpty;
      _searchError = null;
      _globalResolutionQuery = null;
      _globalResolution = null;
      if (query.isNotEmpty) _loading = true;
    });
  }

  void _onKeywordChanged(String v) {
    if (!mounted || !_acceptPendingSearch) return;
    _acceptPendingSearch = false;
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
        _selectedCategoryId ??= _tree.isEmpty ? null : _tree.first.id;
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
    await _reloadGlobalSearch();
  }

  void _restartSearch() {
    ++_requestVersion;
    _acceptPendingSearch = false;
    setState(() {
      _page = 1;
      _paged = null;
      _selected.clear();
      _selectedPanelOpen = false;
      _globalResolution = null;
      _globalResolutionQuery = null;
      _showingGlobalResults = _query.isNotEmpty;
    });
    _reloadCurrentPage();
  }

  void _changeScope(bool expand) {
    if (expand == _expandedScope) return;
    setState(() {
      _expandedScope = expand;
      _selectedCategoryId = _tree.isEmpty ? null : _tree.first.id;
      _searchCategoryId = null;
      _visibleFilterIds = null;
      _naturalTreeWidth = null;
    });
    _restartSearch();
  }

  Set<String> get _scopeRootIds => {for (final root in _scopeTree) root.id};

  // Only the explicit BOM expansion can search unclassified goods. An empty
  // default business tree, ordinary picker, or dedicated source stays scoped.
  bool get _searchesAllSelectableGoods =>
      _expandedScope && widget.dataSource == null && _searchCategoryId == null;

  Set<String> get _scopeCategoryIds {
    final ids = <String>{};
    void collect(List<ProductCategoryNode> nodes) {
      for (final node in nodes) {
        ids.add(node.id);
        collect(node.children);
      }
    }

    collect(_scopeTree);
    return ids;
  }

  Set<String> get _searchAllowedCategoryIds {
    if (_searchCategoryId == null) return _scopeCategoryIds;
    ProductCategoryNode? find(List<ProductCategoryNode> nodes) {
      for (final node in nodes) {
        if (node.id == _searchCategoryId) return node;
        final child = find(node.children);
        if (child != null) return child;
      }
      return null;
    }

    final node = find(_scopeTree);
    if (node == null) return const {};
    final ids = <String>{};
    void collect(ProductCategoryNode current) {
      ids.add(current.id);
      for (final child in current.children) {
        collect(child);
      }
    }

    collect(node);
    return ids;
  }

  Future<PagedResult<GoodsListItem>> _categoryPage(
    String categoryId, {
    int page = 1,
    String? keyword,
  }) =>
      widget.dataSource?.list(categoryId, page: page, keyword: keyword) ??
      ref
          .read(goodsRepositoryProvider)
          .list(
            categoryId,
            page: page,
            keyword: keyword,
            filters: _columnFilters,
            sort: _goodsPickerSort,
            order: _goodsPickerOrder,
            excludeDisabled: true,
            excludeStub: true,
          );

  Future<PagedResult<GoodsListItem>> _searchPage(String query, int page) {
    final source = widget.dataSource;
    if (source != null) {
      return source.searchWithOptions(
        query,
        page: page,
        categoryId: _searchCategoryId,
        includeRelated: _includeRelated,
      );
    }
    final repository = ref.read(goodsRepositoryProvider);
    if (_columnFilters.isNotEmpty) {
      if (repository is! GoodsColumnSearchGateway) {
        throw StateError('货品数据源尚未支持列搜索，请刷新后重试');
      }
      return (repository as GoodsColumnSearchGateway).searchColumns(
        query,
        filters: Map.of(_columnFilters),
        page: page,
        size: 100,
        categoryRootIds: _searchesAllSelectableGoods ? const {} : _scopeRootIds,
        categoryId: _searchCategoryId,
        includeRelated: _includeRelated,
        excludeDisabled: true,
        excludeStub: true,
        sort: _goodsPickerSort,
        order: _goodsPickerOrder,
      );
    }
    return repository.search(
      query,
      page: page,
      size: 100,
      categoryRootIds: _searchesAllSelectableGoods ? const {} : _scopeRootIds,
      categoryId: _searchCategoryId,
      includeRelated: _includeRelated,
      excludeDisabled: true,
      excludeStub: true,
      sort: _goodsPickerSort,
      order: _goodsPickerOrder,
    );
  }

  Future<Set<String>> _searchCategoryIds(String query) {
    final source = widget.dataSource;
    if (source != null) {
      return source.searchCategoryIdsWithOptions(
        query,
        categoryId: _searchCategoryId,
        includeRelated: _includeRelated,
      );
    }
    final repository = ref.read(goodsRepositoryProvider);
    if (_columnFilters.isNotEmpty) {
      if (repository is! GoodsColumnSearchGateway) {
        throw StateError('货品数据源尚未支持列搜索，请刷新后重试');
      }
      return (repository as GoodsColumnSearchGateway).searchColumnCategoryIds(
        query,
        filters: Map.of(_columnFilters),
        categoryRootIds: _scopeRootIds,
        categoryId: _searchCategoryId,
        includeRelated: _includeRelated,
        excludeDisabled: true,
        excludeStub: true,
      );
    }
    return repository.searchCategoryIds(
      query,
      categoryRootIds: _scopeRootIds,
      categoryId: _searchCategoryId,
      includeRelated: _includeRelated,
      excludeDisabled: true,
      excludeStub: true,
    );
  }

  Future<void> _reloadCategory({String? keyword}) async {
    if (!_canRead) return;
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
      final result = await _categoryPage(
        categoryId,
        page: requestedPage,
        keyword: keyword,
      );
      if (!mounted ||
          !_canRead ||
          requestVersion != _requestVersion ||
          categoryId != _selectedCategoryId ||
          requestedPage != _page) {
        return;
      }
      setState(() {
        _paged = result;
        _loading = false;
      });
      unawaited(_reloadFacets(requestVersion));
    } catch (error) {
      if (!mounted || !_canRead || requestVersion != _requestVersion) return;
      setState(() {
        _error = _pickerErrorMessage(
          error,
          keyword == null ? '加载货品失败，请稍后重试' : '搜索货品失败，请稍后重试',
        );
        _loading = false;
      });
    }
  }

  Future<void> _reloadGlobalSearch() async {
    if (!_canRead) return;
    final query = _query;
    final requestedPage = _page;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
      _searchLoading = true;
      _searchError = null;
    });
    // An empty business scope is not the repository's unscoped "all" query.
    // BOM can explicitly expand an empty legacy component range afterwards.
    if (_scopeTree.isEmpty) {
      setState(() {
        _paged = PagedResult(
          items: const <GoodsListItem>[],
          page: requestedPage,
          size: 20,
          total: 0,
          totalPages: 0,
        );
        _visibleFilterIds = <String>{};
        _loading = false;
        _searchLoading = false;
      });
      return;
    }
    try {
      final needsLocation =
          _globalResolutionQuery != query || _globalResolution == null;
      final responses = await Future.wait<Object?>([
        _searchPage(query, requestedPage),
        if (needsLocation)
          _searchCategoryIds(
            query,
          ).then<Set<String>?>((ids) => ids, onError: (_) => null),
      ]);
      final result = responses.first as PagedResult<GoodsListItem>;
      if (!mounted ||
          !_canRead ||
          requestVersion != _requestVersion ||
          query != _query ||
          requestedPage != _page) {
        return;
      }

      // Keep the category guard for ordinary/dedicated scopes and unknown
      // non-null categories. Explicit all-goods search also permits genuinely
      // unclassified rows; the repository still owns eligibility and paging.
      final allowedCategoryIds = _searchAllowedCategoryIds;
      if (result.items.any((goods) {
        final categoryId = goods.categoryId;
        return categoryId == null
            ? !_searchesAllSelectableGoods
            : !allowedCategoryIds.contains(categoryId);
      })) {
        throw StateError('goods search returned an item outside picker scope');
      }

      final HierarchySearchResolution resolution;
      if (needsLocation) {
        var matchingCategoryIds =
            responses[1] as Set<String>? ??
            result.items
                .map((goods) => goods.categoryId)
                .whereType<String>()
                .toSet();
        // Some dedicated report APIs offer only global location hints. Keep
        // those hints inside the explicit scope; rows are never filtered here.
        if (widget.dataSource != null) {
          matchingCategoryIds = matchingCategoryIds.intersection(
            allowedCategoryIds,
          );
        }
        if (matchingCategoryIds.any(
          (categoryId) => !allowedCategoryIds.contains(categoryId),
        )) {
          throw StateError(
            'goods location search returned a category outside picker scope',
          );
        }
        resolution = resolveHierarchySearch(
          roots: _tree,
          query: query,
          contentCategoryIds: matchingCategoryIds,
        );
      } else {
        resolution = _globalResolution!;
      }

      setState(() {
        _globalResolutionQuery = query;
        _globalResolution = resolution;
        _visibleFilterIds = resolution.visibleIds;
        _showingGlobalResults = true;
        _paged = result;
        _loading = false;
        _searchLoading = false;
      });
      unawaited(_reloadFacets(requestVersion));
    } catch (error) {
      if (!mounted || !_canRead || requestVersion != _requestVersion) return;
      setState(() {
        _error = _pickerErrorMessage(error, '搜索货品失败，请稍后重试');
        _searchError = _error;
        _loading = false;
        _searchLoading = false;
      });
    }
  }

  Future<void> _reloadCurrentPage() async {
    if (_query.isNotEmpty && _showingGlobalResults) {
      await _reloadGlobalSearch();
    } else {
      await _reloadCategory();
    }
  }

  /// 按当前列表上下文拉表头筛选候选桶：分类浏览态用所选分类子树 facets；
  /// 搜索态用全局 facets 并以业务范围根限定（显式扩全部可选货品时不限）。
  Future<void> _reloadFacets(int requestVersion) async {
    if (!_supportsColumnSearch || !_canRead) return;
    try {
      final repository = ref.read(goodsRepositoryProvider);
      final GoodsFacets result;
      if (_query.isEmpty) {
        final categoryId = _selectedCategoryId;
        if (categoryId == null) return;
        result = await repository.facets(
          categoryId,
          filters: _columnFilters,
          excludeDisabled: true,
          excludeStub: true,
        );
      } else {
        result = await repository.globalFacets(
          keyword: _query,
          includeRelated: _includeRelated,
          filters: _columnFilters,
          excludeDisabled: true,
          excludeStub: true,
          categoryRootIds: _searchesAllSelectableGoods
              ? const {}
              : _scopeRootIds,
        );
      }
      if (!mounted || !_canRead || requestVersion != _requestVersion) return;
      setState(() => _facets = result);
    } catch (_) {
      // 候选桶是可选增强：失败静默为空下拉，不阻塞列表。
    }
  }

  Set<String>? get _treeVisibleIds {
    final ids = _visibleFilterIds;
    if (ids == null || _searchCategoryId == null) return ids;
    final visible = <String>{...ids};
    addAncestors(_tree, _searchCategoryId!, visible);
    return visible;
  }

  @override
  Widget build(BuildContext context) {
    if (!_canRead) {
      _closeStaleRoute();
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final treePane = UtenCategoryTreeView<ProductCategoryNode>(
      nodes: _tree,
      mode: UtenCategoryTreeMode.single,
      selectedIds: {
        ?(_query.isEmpty ? _selectedCategoryId : _searchCategoryId),
      },
      expandOnRowTap: true,
      // 左树默认全部收起（2026-09-24 用户口径）：只显示一级分类，点了再展开。
      initiallyExpandDepth: 0,
      initiallyCollapsedNames: const {'未分类'},
      showSearch: false,
      emptySearchText: '未找到匹配「$_query」的分类',
      visibleFilterIds: _treeVisibleIds,
      externalSearchQuery: _query,
      externalSearchLoading: _searchLoading,
      externalSearchError: _searchError,
      header: _buildUnifiedSearch(),
      flatLevelColors: true,
      onToggleSelect: _onCategoryTap,
    );
    final body = UtenSplitView(
      persistenceKey: 'goodsPicker.categoryTree',
      initialLeadingWidth: _treeNaturalWidth(theme),
      minLeadingWidth: 200,
      maxLeadingWidth: 560,
      selectedLeadingLabel:
          utenTreeSelectionPath(
            _tree,
            _query.isEmpty ? _selectedCategoryId : _searchCategoryId,
          ) ??
          '全部分类',
      selectedLeadingKey: _query.isEmpty
          ? _selectedCategoryId
          : _searchCategoryId,
      compactHeader: treePane.header,
      leading: treePane,
      trailing: _buildRightPane(theme),
    );
    return Stack(
      key: const Key('goods-picker-sheet'),
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
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
            Expanded(child: body),
            _buildConfirmBar(theme),
          ],
        ),
        // 多选：底部「已选 N 项」点开的已选清单滑层（盖住主体与底栏）。
        if (widget.multiSelect)
          Positioned.fill(child: _buildSelectedPanelOverlay(theme)),
      ],
    );
  }

  Widget _buildConfirmBar(ThemeData theme) {
    if (widget.multiSelect) return _buildMultiSelectBar(theme);
    final requestVersion = _requestVersion;
    final single = _selected.isEmpty ? null : _selected.values.first;
    return UtenPickerConfirmBar(
      selectedCount: _selected.length,
      pagination: UtenPickerPageControls(controller: _pickerRows),
      selectedLabel: single == null ? null : _goodsLabel(single),
      onConfirm: () => _confirm(single, requestVersion: requestVersion),
    );
  }

  /// 多选底栏：左侧「已选 N 项」胶囊点开已选清单滑层；右侧 清空/取消/确定(N)。
  Widget _buildMultiSelectBar(ThemeData theme) {
    final count = _selected.length;
    final requestVersion = _requestVersion;
    final summary = InkWell(
      key: const Key('goods-picker-selected-summary'),
      borderRadius: BorderRadius.circular(UtenRadius.md),
      onTap: count == 0
          ? null
          : () => setState(() => _selectedPanelOpen = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: count > 0
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(UtenRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              count > 0 ? Icons.checklist_rounded : Icons.checklist_outlined,
              size: 18,
              color: count > 0
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              count > 0 ? '已选 $count 项' : '未选择',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: count > 0
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_up_rounded,
              size: 18,
              color: count > 0
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
    return UtenPickerConfirmBar(
      selectedCount: count,
      summary: summary,
      pagination: UtenPickerPageControls(controller: _pickerRows),
      onClear: () => setState(_selected.clear),
      onConfirm: () =>
          _confirm(_selected.values.toList(), requestVersion: requestVersion),
      confirmLabel: '确定($count)',
      confirmButtonKey: const Key('goods-picker-multi-confirm'),
    );
  }

  /// 已选清单滑层：从滑窗底部滑出，列出全部已选货品并可逐项取消选择。
  Widget _buildSelectedPanelOverlay(ThemeData theme) {
    final open = _selectedPanelOpen;
    return IgnorePointer(
      ignoring: !open,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final panelHeight = (constraints.maxHeight * 0.55).clamp(
            220.0,
            480.0,
          );
          return Stack(
            children: [
              // 遮罩：点击收起滑层（不清空选择）。
              Positioned.fill(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: open ? 1 : 0,
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedPanelOpen = false),
                    child: const ColoredBox(
                      color: Colors.black38,
                      child: SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: panelHeight,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  offset: open ? Offset.zero : const Offset(0, 1),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerLow,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.checklist_rounded,
                                  size: 20,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '已选货品（${_selected.length}）',
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                UtenButton(
                                  type: UtenButtonType.danger,
                                  size: UtenButtonSize.small,
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : () => setState(_selected.clear),
                                  child: const Text('清空全部'),
                                ),
                                IconButton(
                                  tooltip: '收起',
                                  onPressed: () => setState(
                                    () => _selectedPanelOpen = false,
                                  ),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: _selected.isEmpty
                                ? Center(
                                    child: Text(
                                      '还没有选择货品；收起后在列表点货品行即可勾选',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                : ListView.separated(
                                    itemCount: _selected.length,
                                    separatorBuilder: (_, _) =>
                                        const Divider(height: 1),
                                    itemBuilder: (ctx, i) {
                                      final g = _selected.values.elementAt(i);
                                      return ListTile(
                                        key: ValueKey(
                                          'goods-picker-selected-row-${g.id}',
                                        ),
                                        dense: true,
                                        title: Text(
                                          _goodsLabel(g),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: IconButton(
                                          key: ValueKey(
                                            'goods-picker-selected-remove-${g.id}',
                                          ),
                                          tooltip: '取消选择',
                                          color: theme.colorScheme.error,
                                          icon: const Icon(Icons.close_rounded),
                                          onPressed: () => setState(
                                            () => _selected.remove(g.id),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 已选摘要栏的一行文案：名字(编号) · 颜色（底栏空间窄，保持单行摘要；
  /// 明细表里的名称、编号、颜色各有独立表头）。
  String _goodsLabel(GoodsListItem g) =>
      '${g.name ?? '—'}'
      '${g.code != null && g.code!.isNotEmpty ? '(${g.code})' : ''}'
      '${g.colorName != null && g.colorName!.isNotEmpty ? ' · ${g.colorName}' : ''}';

  Widget _buildRightPane(ThemeData theme) => _buildGoodsList(theme);

  Widget _buildUnifiedSearch() {
    return Padding(
      // 左缘贴 0（2026-10-18 全站分栏口径）：与分类页左栏搜索共缘。
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.allTree != null) ...[
            UtenSegmentRow<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('当前组件范围')),
                ButtonSegment(value: true, label: Text('全部可选货品')),
              ],
              selected: {_expandedScope},
              onSelectionChanged: (values) => _changeScope(values.single),
            ),
            const SizedBox(height: UtenSpacing.s8),
          ],
          UtenSearchBar(
            key: const Key('uten-goods-picker-search'),
            controller: _keywordCtl,
            hint: '搜索分类/货品名称或编号',
            onInputChanged: _onKeywordInputChanged,
            onChanged: _onKeywordChanged,
          ),
          if (_query.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _searchCategoryId == null
                        ? '搜索范围：全部分类'
                        : '搜索范围：${utenTreeSelectionPath(_tree, _searchCategoryId) ?? '所选分类'}',
                    key: const ValueKey('goods-picker-search-scope'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_searchCategoryId != null)
                  IconButton(
                    tooltip: '清除分类范围，搜索全部分类',
                    onPressed: () {
                      setState(() => _searchCategoryId = null);
                      _restartSearch();
                    },
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
              ],
            ),
            if (_supportsRelatedSearch)
              GoodsRelatedSearchControl(
                value: _includeRelated,
                onChanged: (value) {
                  setState(() => _includeRelated = value);
                  _restartSearch();
                },
              ),
          ],
        ],
      ),
    );
  }

  void _onColumnFilterChanged(String key, String? value) {
    if (!_supportsColumnSearch || !_canRead) return;
    ++_requestVersion;
    _acceptPendingSearch = false;
    setState(() {
      if (value == null || value.trim().isEmpty) {
        _columnFilters.remove(key);
      } else {
        _columnFilters[key] = value.trim();
      }
      _page = 1;
      _showingGlobalResults = _query.isNotEmpty;
      _paged = null;
      _globalResolution = null;
      _globalResolutionQuery = null;
    });
    _reloadCurrentPage();
  }

  /// 漏斗下拉的远程候选搜索（列值过多时按关键词翻页取值）：与 [_reloadFacets]
  /// 同一查询上下文——分类浏览态带所选分类，搜索态带搜索词与业务范围根。
  MasterFacetPageLoader? get _facetPageLoader {
    if (!_supportsColumnSearch) return null;
    final facetRepository = ref.read(goodsFacetRepositoryProvider);
    if (facetRepository == null) return null;
    return (column, search, page) => facetRepository.values(
      field: column,
      search: search,
      page: page,
      categoryId: _query.isEmpty ? _selectedCategoryId : _searchCategoryId,
      categoryRootIds:
          _query.isEmpty || _searchCategoryId != null || _searchesAllSelectableGoods
          ? const {}
          : _scopeRootIds,
      keyword: _query.isEmpty ? null : _query,
      includeRelated: _includeRelated,
      filters: _columnFilters,
      excludeDisabled: true,
      excludeStub: true,
    );
  }

  Widget _buildGoodsList(ThemeData theme) {
    final requestVersion = _requestVersion;
    bool selectable(GoodsListItem goods) =>
        _canRead &&
        !_loading &&
        !_searchLoading &&
        (widget.dataSource?.isSelectable(goods) ?? true);
    MasterColumnDef<GoodsListItem> column(
      String key,
      String label,
      double width,
      String? Function(GoodsListItem) value, {
      bool search = true,
    }) => MasterColumnDef(
      key: key,
      label: label,
      width: width,
      value: value,
      columnSearchEnabled: _supportsColumnSearch && search,
    );
    return MasterDataTableView<GoodsListItem>(
      key: const Key('goods-picker-paged-list'),
      singleTapRows: true,
      rowsController: _pickerRows,
      showPaginationControls: false,
      columns: [
        if (widget.dataSource?.pickerColumns case final columns?)
          ...columns
        else ...[
          MasterColumnDef(
            key: 'name',
            label: '货品名称',
            width: 190,
            columnSearchEnabled: _supportsColumnSearch,
            value: (goods) => goods.name,
            cellBuilder: (_, goods) => Text(goods.name ?? '—'),
          ),
          column('code', '编号', 130, (g) => g.code),
          column('series', '系列', 100, (g) => g.series),
          column('model', '型号', 110, (g) => g.model),
          column('spec', '规格', 140, (g) => g.spec),
          column('colorLegacyId', '主颜色', 100, (g) => g.colorName),
          column('unitLegacyId', '单位', 70, (g) => g.unitName),
        ],
        if (_includeRelated)
          MasterColumnDef(
            key: 'searchMatchKind',
            label: '匹配方式',
            width: 110,
            columnSearchEnabled: false,
            value: (goods) => goods.isRelatedSearchMatch ? '相关结果' : '货品匹配',
          ),
      ],
      items: _paged?.items ?? const [],
      rowKeyOf: (goods) => goods.id,
      rowWidgetKeyOf: (goods) => ValueKey('goods-picker-item-${goods.id}'),
      idOf: (goods) => selectable(goods) ? goods.id : null,
      rowForegroundColor: (goods) =>
          widget.dataSource?.isSelectable(goods) == false
          ? theme.disabledColor
          : null,
      selectable: widget.multiSelect,
      showSelectionSummary: false,
      selectedIds: _selected.keys.toSet(),
      onSelectedIdsChanged: (ids) {
        if (!_canRead ||
            requestVersion != _requestVersion ||
            _loading ||
            _searchLoading) {
          return;
        }
        final available = {
          for (final goods in _pickerRows.items) goods.id: goods,
        };
        setState(() {
          _selected.removeWhere((id, _) => !ids.contains(id));
          for (final id in ids) {
            final goods = available[id];
            if (goods != null && selectable(goods)) {
              _selected.putIfAbsent(id, () => goods);
            }
          }
        });
      },
      isSelected: (goods) => _selected.containsKey(goods.id),
      onRowTap: widget.multiSelect
          ? null
          : (goods) {
              if (!selectable(goods) || requestVersion != _requestVersion) {
                return;
              }
              setState(() {
                _selected
                  ..clear()
                  ..[goods.id] = goods;
              });
            },
      facets: _facets?.fields ?? const {},
      nullCounts: _facets?.nullCounts ?? const {},
      filters: _columnFilters,
      serverColumnSearch: true,
      onFilterChanged: _onColumnFilterChanged,
      loadFacetPage: _facetPageLoader,
      currentPage: _paged?.page ?? 1,
      totalPages: _paged?.totalPages ?? 1,
      paginationScope: (
        widget.scope,
        _query,
        _includeRelated,
        _expandedScope,
        _showingGlobalResults,
        _showingGlobalResults ? _searchCategoryId : _selectedCategoryId,
        _columnFilters.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('&'),
      ),
      onPageChange: (page) {
        setState(() => _page = page);
        return _reloadCurrentPage();
      },
      isLoading:
          (_loading || _searchLoading) && (_paged?.items.isEmpty ?? true),
      loadingMore:
          (_loading || _searchLoading) && (_paged?.items.isNotEmpty ?? false),
      error: _error,
      onRetry: _reloadCurrentPage,
      emptyMessage: _paged == null
          ? (_tree.isEmpty ? '没有可选择的货品分类' : '请选择左侧分类或搜索货品')
          : '当前条件下没有可选货品',
      showFullscreenToggle: false,
      showColumnChooser: false,
      enableTextSelection: false,
    );
  }
}
