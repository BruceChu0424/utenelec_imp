// CategoryPageShell - 基础资料分类页壳层（审计 §4.1 第 3 批）。
//
// client/mould/product/supplier 四个 *_category_page 的顶层 State 曾逐字重复
// 约 460 行编排：树加载、顶部统一搜索四件套（输入/提交/应用/选分类）、
// 分类增改删（CategoryEditDialog + prefix 预览）、树渲染 trailing、
// loading/error/empty/compact/split 的 build 骨架与 endDrawer。
// 本 mixin 收敛这些编排；页面只声明配置钩子（文案/图标/权限/仓储调用）
// 并提供右栏 DetailPane 构造。
//
// 页面差异经钩子保留：
//  - product 页 keepTreeMounted=true（树常驻不卸载，保展开状态）+
//    initiallyCollapseUncategorized + appBar 撤回导入 + 搜索改走
//    repo.searchCategoryIds 分批 + 级联删除预览/显式错误弹窗；
//  - mould/product 的级联删除确认（红框计数）覆盖 shellDeleteNode；
//  - client/supplier 用默认的简版删除确认。
//
// 不改任何业务语义/文案/TODO(l10n)；渲染与交互只在这一处维护。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/action_feedback.dart';
import '../models/product_category_node.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/system_master_category_guard.dart';
import '../widgets/uten_category_tree_view.dart';

/// 分类页壳层 mixin：与 ConsumerState 组合使用。
///
/// 页面 State `extends ConsumerState<XxxPage> with CategoryPageShell<XxxPage>`
/// （泛型参数取页面 widget 类型，避免与 ConsumerState 的多实例化冲突），
/// 实现全部 `shell*` 抽象成员后即可使用 [buildShell] 作为 build 主体。
mixin CategoryPageShell<W extends ConsumerStatefulWidget> on ConsumerState<W> {
  // ---- 页面配置（子类必须实现） -------------------------------------------

  /// AppBar 标题，如「客户资料」。
  String get shellTitle;

  /// 顶部统一搜索框 hint，如「搜索分类/客户名称或编号」。
  String get shellSearchHint;

  /// 内容名词（客户/模具/货品/供应商）：搜索失败文案前缀、空态文案。
  String get shellContentNoun;

  /// 树空态/compact 空态图标。
  IconData get shellEmptyIcon;

  /// UtenSplitView 分栏持久化 key，如 'basicData.client'。
  String get shellPersistenceKey;

  bool get shellCanCreate;
  bool get shellCanEdit;
  bool get shellCanDelete;
  bool get shellCanMove;
  bool get shellCanReorder;

  /// 拉分类树。
  Future<List<ProductCategoryNode>> shellLoadTree();

  /// 创建分类（由 CategoryEditResult 组装页面自己的 SaveInput）。
  Future<void> shellCreateCategory(CategoryEditResult r);

  /// 更新分类。
  Future<void> shellUpdateCategory(String id, CategoryEditResult r);

  /// 删除分类（已过确认框）。
  Future<void> shellDeleteCategory(String id);

  /// 编码前缀预览（编辑对话框联动，返回对话框要的预览对象）。
  Future<CategoryPrefixPreview> shellPrefixPreview(
    String id,
    String prefix,
    String? parentId,
  );

  /// 内容搜索命中的分类 id 集合（null=请求已过期放弃应用）。
  /// client/mould/supplier 用 collectPagedHierarchyCategoryIds；
  /// product 用 repo.searchCategoryIds 按 32 个根分批。
  Future<Set<String>?> shellContentCategoryIds(
    String q,
    bool Function() isCurrent,
  );

  // ---- 可选钩子（默认值对应 client/supplier 行为） -------------------------

  /// 树常驻不卸载（product=true：增删改/刷新保树挂载与展开状态）。
  bool get shellKeepTreeMounted => false;

  /// 初始折叠「未分类」子树（product=true）。
  bool get shellInitiallyCollapseUncategorized => false;

  /// AppBar 额外动作（product：撤回导入）。
  List<Widget> shellExtraAppBarActions(
    BuildContext context, {
    required bool compact,
    required bool treeNotEmpty,
  }) => const [];

  /// 分类创建/更新成功后的额外收尾（shellReload 之后调用）。
  /// 默认无操作；product 页重写为自增 _detailEpoch 重挂右栏——shellReload 只重载
  /// 分类树，右栏详情卡片（名称/前缀）与货品列表若不重挂会停留在编辑前的旧数据。
  void shellAfterCategorySaved() {}

  /// 删除分类节点（含确认框）。默认 = client/supplier 简版确认；
  /// mould/product 覆盖为级联预览红框版本。
  Future<void> shellDeleteNode(ProductCategoryNode node) async {
    if (isSystemUncategorizedCategory(systemManaged: node.systemManaged)) {
      context.appInfo(systemUncategorizedCategoryProtectionMessage);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${node.name}」吗？若存在子分类或$shellContentNoun引用，删除可能失败。', // TODO(l10n): 补 arb
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final deleted = await guardShellAction(
      () async => shellDeleteCategory(node.id),
      success: '分类已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    shellAfterCategoryDeleted(node.id);
    await shellReload();
  }

  // ---- 共享状态 -----------------------------------------------------------

  final _searchRequests = LatestRequestGuard();
  List<ProductCategoryNode>? _tree;
  String? _selectedId;
  bool _loading = true;
  String? _error;

  // 顶部统一搜索（分类名 + 内容名）→ 定位分类：visibleFilterIds 驱动树只显示命中分类 + 祖先链。
  Set<String>? _visibleFilterIds;
  String _globalQuery = '';
  Set<String> _contentMatchCategoryIds = {};
  bool _searchLoading = false;
  String? _searchError;
  bool _acceptPendingSearch = false;

  // 顶部搜索命中内容时，右侧内容列表同步按该关键词过滤（只显示搜索结果，而非该分类全部）；
  // 清空搜索 / 仅分类名命中 / 手动点树节点时复位为 null。
  String? _treeSearchKeyword;

  // ---- 树加载 -------------------------------------------------------------

  /// 拉分类树（页面 onDataChanged / 刷新按钮 / CRUD 成功后都会走这里）。
  Future<void> shellReload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tree = await shellLoadTree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        // 不预选分类：默认右侧空态「请选择左侧分类」，点了分类才拉内容（省资源）。
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载分类树失败，请稍后重试'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  // ---- 顶部统一搜索（分类名 + 内容名 → 定位分类）----------------------------

  void _onGlobalSearchInput(String raw) {
    _searchRequests.begin();
    final tree = _tree;
    if (!mounted || tree == null || tree.isEmpty) return;
    final q = raw.trim();
    _acceptPendingSearch = true;
    setState(() {
      _globalQuery = q;
      _contentMatchCategoryIds = {};
      _treeSearchKeyword = null;
      _searchError = null;
      _visibleFilterIds = q.isEmpty ? null : categoryHits(tree, q);
      _searchLoading = q.isNotEmpty;
    });
  }

  void _onGlobalSearch(String raw) {
    final q = raw.trim();
    if (!_acceptPendingSearch || q != _globalQuery) return;
    _acceptPendingSearch = false;
    _applyGlobalSearch(q);
  }

  Future<void> _applyGlobalSearch(String q) async {
    final tree = _tree;
    if (tree == null || tree.isEmpty) return;
    final generation = _searchRequests.begin();
    if (q.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null; // 清空：恢复全树
        _treeSearchKeyword = null; // 同时解除右侧列表的搜索过滤
        _contentMatchCategoryIds = {};
        _searchLoading = false;
        _searchError = null;
      });
      return;
    }
    final catHits = categoryHits(tree, q);
    setState(() {
      _globalQuery = q;
      _visibleFilterIds = catHits;
      _contentMatchCategoryIds = {};
      _treeSearchKeyword = null;
      _searchLoading = true;
      _searchError = null;
    });
    try {
      final contentCategoryIds = await shellContentCategoryIds(
        q,
        () => mounted && _searchRequests.isCurrent(generation),
      );
      if (contentCategoryIds == null) return;
      final resolution = resolveHierarchySearch(
        roots: tree,
        query: q,
        contentCategoryIds: contentCategoryIds,
      );
      setState(() {
        _visibleFilterIds = resolution.visibleIds;
        _contentMatchCategoryIds = resolution.contentCategoryIds;
        _treeSearchKeyword = resolution.hasContentMatches ? q : null;
        _searchLoading = false;
        _searchError = null;
        if (resolution.selectedId != null) {
          _selectedId = resolution.selectedId;
        }
      });
    } on ApiException catch (e) {
      if (!mounted || !_searchRequests.isCurrent(generation)) return;
      setState(() {
        _searchLoading = false;
        _searchError =
            '$shellContentNoun搜索失败：${e.message}'; // TODO(l10n): 补 arb
      });
    } catch (_) {
      if (!mounted || !_searchRequests.isCurrent(generation)) return;
      setState(() {
        _searchLoading = false;
        _searchError = '$shellContentNoun搜索失败，请稍后重试'; // TODO(l10n): 补 arb
      });
    }
  }

  void _selectCategory(String id) {
    _searchRequests.begin();
    _acceptPendingSearch = false;
    final keepKeyword =
        _globalQuery.isNotEmpty &&
        hierarchyBranchContainsAny(
          _tree ?? const <ProductCategoryNode>[],
          id,
          _contentMatchCategoryIds,
        );
    setState(() {
      _selectedId = id;
      _treeSearchKeyword = keepKeyword ? _globalQuery : null;
      _searchLoading = false;
    });
  }

  Widget _buildGlobalSearchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: UtenSearchBar(
        initialValue: _globalQuery,
        hint: shellSearchHint, // TODO(l10n): 补 arb
        onInputChanged: _onGlobalSearchInput,
        onChanged: _onGlobalSearch,
      ),
    );
  }

  ProductCategoryNode? _findById(List<ProductCategoryNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  // ---- 创建/编辑/删除 -----------------------------------------------------

  void shellShowCreateDialog({ProductCategoryNode? parent}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => CategoryEditDialog(
        tree: _tree ?? const <ProductCategoryNode>[],
        initialParent: parent,
        onSubmit: (r) => _doCreate(r),
      ),
    );
  }

  Future<bool> _doCreate(CategoryEditResult r) async {
    final ok = await guardShellAction(
      () async => shellCreateCategory(r),
      success: '分类已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await shellReload();
    shellAfterCategorySaved();
    return true;
  }

  void shellShowEditDialog(ProductCategoryDetail detail) {
    if (isSystemUncategorizedCategory(systemManaged: detail.systemManaged)) {
      context.appInfo(systemUncategorizedCategoryProtectionMessage);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => CategoryEditDialog(
        tree: _tree ?? const <ProductCategoryNode>[],
        editing: detail,
        canEditFields: shellCanEdit,
        canMove: shellCanMove,
        canReorder: shellCanReorder,
        onPreviewPrefixChange: (prefix, parentId) =>
            shellPrefixPreview(detail.id, prefix, parentId),
        onSubmit: (r) => _doUpdate(detail.id, r),
      ),
    );
  }

  Future<bool> _doUpdate(String id, CategoryEditResult r) async {
    final ok = await guardShellAction(
      () async => shellUpdateCategory(id, r),
      success: '分类已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await shellReload();
    shellAfterCategorySaved();
    return true;
  }

  /// 删除成功后的收尾：清掉指向已删分类的选中态（调用方随后 shellReload）。
  void shellAfterCategoryDeleted(String nodeId) {
    if (_selectedId == nodeId) _selectedId = null;
  }

  /// 顶部搜索命中内容时的右栏同步关键词（DetailPane externalKeyword 用）。
  String? get shellTreeSearchKeyword => _treeSearchKeyword;

  /// 当前分类树（product 页分批搜索钩子需要根节点列表；其它页面一般用不到）。
  List<ProductCategoryNode>? get shellTree => _tree;

  /// guardRun 的薄封装：mixin 里不便引用页面层的 action_feedback 扩展别名。
  Future<bool> guardShellAction(
    Future<void> Function() action, {
    required String success,
    required String errorFallback,
  }) {
    return context.guardRun(
      action,
      success: success,
      errorFallback: errorFallback,
    );
  }

  // ---- 树渲染 -------------------------------------------------------------

  Widget _buildTree({required void Function(String id) onSelect}) {
    final theme = Theme.of(context);
    final canDelete = shellCanDelete;
    return UtenCategoryTreeView(
      nodes: _tree ?? const <ProductCategoryNode>[],
      nodeEnabledPredicate: (_) => true,
      selectedIds: {?_selectedId},
      expandOnRowTap: true,
      showSearch: false,
      initiallyCollapsedNames: shellInitiallyCollapseUncategorized
          ? const {'未分类'}
          : const {},
      visibleFilterIds: _visibleFilterIds,
      externalSearchQuery: _globalQuery,
      externalSearchLoading: _searchLoading,
      externalSearchError: _searchError,
      header: _buildGlobalSearchBox(),
      onNodeTap: (node) => onSelect(node.id),
      trailingBuilder: (node) {
        final isSystemRoot = isSystemUncategorizedCategory(
          systemManaged: node.systemManaged,
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (node.hasChildren)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${node.children.length}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w400,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (canDelete && isSystemRoot)
              const SystemMasterCategoryProtectionNotice(compact: true),
            if (canDelete && !isSystemRoot)
              InkWell(
                onTap: () => shellDeleteNode(node),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ---- build 骨架 ---------------------------------------------------------

  /// 页面 build 主体。[detailPaneBuilder] 构造选中分类的右栏（页面私有
  /// DetailPane；onAddChild/onEdit/onDelete 已由壳层接好分类 CRUD）。
  Widget buildShell(
    BuildContext context, {
    required Widget Function(ProductCategoryNode selected) detailPaneBuilder,
  }) {
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final tree = _tree ?? const <ProductCategoryNode>[];
    final selected = _selectedId == null ? null : _findById(tree, _selectedId!);
    final canCreate = shellCanCreate;

    Widget detailPaneOf(ProductCategoryNode selectedNode) =>
        detailPaneBuilder(selectedNode);

    Widget mainLayout() {
      if (bp == UtenBreakpoint.compact) {
        final compactDetail = selected == null
            ? UtenEmpty(
                icon: shellEmptyIcon,
                message: '请选择左侧分类查看详情', // TODO(l10n): 补 arb
              )
            : UtenContentContainer(child: detailPaneOf(selected));
        return Column(
          children: [
            _buildGlobalSearchBox(),
            Expanded(child: compactDetail),
          ],
        );
      }
      return UtenSplitView(
        persistenceKey: shellPersistenceKey,
        leading: _buildTree(onSelect: _selectCategory),
        trailing: selected == null
            ? Center(
                child: Text(
                  '请选择左侧分类查看详情', // TODO(l10n): 补 arb
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : detailPaneOf(selected),
      );
    }

    Widget body;
    if (shellKeepTreeMounted && tree.isNotEmpty) {
      // 已有分类树时，增删改 / 手动刷新都保持树挂载（不切全屏 spinner），
      // 否则 UtenCategoryTreeView 会被卸载、重挂载后展开状态丢失。
      body = mainLayout();
    } else if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: shellReload,
      );
    } else if (tree.isEmpty) {
      body = UtenEmpty(
        icon: shellEmptyIcon,
        message: '暂无$shellContentNoun分类', // TODO(l10n): 补 arb
        description: canCreate ? '还没有任何分类，新建第一个吧' : null, // TODO(l10n): 补 arb
        actionLabel: canCreate ? '新建分类' : null, // TODO(l10n): 补 arb
        onAction: canCreate ? () => shellShowCreateDialog() : null,
      );
    } else {
      body = mainLayout();
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: shellTitle, // TODO(l10n): 补 arb
        // 显式返回到基础资料 hub（默认返回会因 context.go 不压栈而兜底回工作台）。
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          ...shellExtraAppBarActions(
            context,
            compact: bp == UtenBreakpoint.compact,
            treeNotEmpty: tree.isNotEmpty,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: shellReload,
          ),
          if (bp == UtenBreakpoint.compact && tree.isNotEmpty)
            Builder(
              builder: (scaffoldCtx) => IconButton(
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: '分类树', // TODO(l10n): 补 arb
                onPressed: () => Scaffold.of(scaffoldCtx).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: bp == UtenBreakpoint.compact && tree.isNotEmpty
          ? Drawer(
              child: SafeArea(
                child: _buildTree(
                  onSelect: (id) {
                    _selectCategory(id);
                    Navigator.of(context).pop();
                  },
                ),
              ),
            )
          : null,
      body: SafeArea(child: body),
    );
  }
}
