// CategoryPageShell - 基础资料分类页壳层（审计 §4.1 第 3 批）。
//
// client/mould/product/supplier 四个 *_category_page 的顶层 State 曾逐字重复
// 约 460 行编排：树加载、顶部统一搜索四件套（输入/提交/应用/选分类）、
// 分类增改删(CategoryEditDialog + prefix 预览)、树渲染(详情卡菜单与
// 右键菜单）、loading/error/empty 与按局部宽度切换的两栏/完整目录。
// 本 mixin 收敛这些编排；页面只声明配置钩子（文案/图标/权限/仓储调用）
// 并提供右栏 DetailPane 构造。
//
// 页面差异经钩子保留：
//  - product 页 keepTreeMounted=true（树常驻不卸载，保展开状态）+
//    initiallyCollapseUncategorized + appBar 操作历史 + 搜索改走
//    repo.searchCategoryIds 分批 + 级联删除预览/显式错误弹窗；
//  - mould/product 的级联删除确认（红框计数）覆盖 shellDeleteNode；
//  - client/supplier 用默认的简版删除确认。
//
// 不改任何业务语义/文案/TODO(l10n)；渲染与交互只在这一处维护。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../components/data_display/uten_selection_lifecycle.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_motion.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../shared/hierarchy/uten_tree_path.dart';
import '../../../shared/widgets/uten_hierarchy_search_header.dart';
import '../../../shared/widgets/uten_hierarchy_node_actions.dart';
import '../../../shared/widgets/uten_hierarchy_detail_menu.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../models/product_category_node.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/system_master_category_guard.dart';
import '../widgets/uten_category_tree_view.dart';
import 'basic_data_l10n.dart';
import 'master_inline_edit.dart';
import 'master_operation_history_panel.dart';

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

  FormDraftDescriptor get shellCategoryDraftDescriptor;
  String get shellCategoryViewPermission;

  /// Only a specifically reviewed action may keep the mounted read shell.
  String? get shellReadStableWritePermission => null;
  bool get shellCanViewCategories =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(shellCategoryViewPermission);

  bool get shellCanCreate;
  bool get shellCanEdit;
  bool get shellCanDelete;
  bool get shellCanMove;
  bool get shellCanReorder;

  /// 拉分类树。
  Future<List<ProductCategoryNode>> shellLoadTree();

  /// 创建分类（由 CategoryEditResult 组装页面自己的 SaveInput）。
  Future<ProductCategoryDetail> shellCreateCategory(CategoryEditResult r);

  /// 更新分类。
  Future<void> shellUpdateCategory(String id, CategoryEditResult r);

  /// 删除分类（已过确认框）。
  Future<void> shellDeleteCategory(String id);

  /// 创建/编辑分类时实时检查编号前缀的全局占用。
  Future<CategoryPrefixAvailability> shellPrefixAvailability(
    String prefix, {
    String? categoryId,
  });

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

  /// 拉分类详情：树行「编辑」动作用——编辑弹窗要 Detail（前缀/层级等），树节点
  /// 只有名称/编码骨架。各页仓储的 detail(id) 即此（与明细区 loadCategory 同源）。
  Future<ProductCategoryDetail> shellLoadCategoryDetail(String id);

  /// 虚拟节点谓词：树里不对应真实分类的行（如模具页「全部模具」系统视图）。
  /// 这类行不出现增/改/删图标、不挂锁提示，也不弹右键菜单。默认无虚拟节点。
  bool shellIsVirtualNode(ProductCategoryNode node) => false;

  // ---- 可选钩子（默认值对应 client/supplier 行为） -------------------------

  /// 树常驻不卸载（product=true：增删改/刷新保树挂载与展开状态）。
  bool get shellKeepTreeMounted => false;

  /// 初始折叠「未分类」子树（product=true）。
  bool get shellInitiallyCollapseUncategorized => false;

  List<Widget> shellSearchOptions(BuildContext context) => const [];

  void shellSearchQueryChanged(String query) {}

  /// AppBar 额外动作（product：操作历史中的撤回与取消撤回）。
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
      builder: (ctx) => UtenAlertDialog(
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
  final _treeRequests = LatestRequestGuard();
  List<ProductCategoryNode>? _tree;
  String? _selectedId;

  /// 右栏当前跟随的分类 id（比 [_selectedId] 晚一帧，见 [_syncPaneSelectionNextFrame]）。
  String? _paneSelectedId;
  bool _loading = true;
  String? _error;

  /// 右栏整体重挂代际（2026-09-05 刷新按钮=整页刷新）：shellReloadAll 递增，
  /// detailPaneBuilder 结果包 KeyedSubtree——右栏内容/facets 全部随代际重拉，
  /// 四个分类页无需各自维护 epoch。
  int _shellDetailEpoch = 0;

  // 顶部统一搜索（分类名 + 内容名）→ 定位分类：visibleFilterIds 驱动树只显示命中分类 + 祖先链。
  Set<String>? _visibleFilterIds;
  String _globalQuery = '';
  String? _searchCategoryId;
  int _searchRevision = 0;
  bool _searchLoading = false;
  String? _searchError;
  bool _acceptPendingSearch = false;
  Timer? _shellSearchDebounce;

  // 顶部搜索命中内容时，右侧内容列表同步按该关键词过滤（只显示搜索结果，而非该分类全部）；
  // 清空搜索 / 仅分类名命中 / 手动点树节点时复位为 null。
  String? _treeSearchKeyword;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous != next &&
          !canRetainMasterReadShell(
            previous,
            next,
            writeOnlyPermission: shellReadStableWritePermission,
          )) {
        _categoryAccessChanged(next);
      }
    });
  }

  void _categoryAccessChanged(SensitiveReadBoundary next) {
    _treeRequests.begin();
    _searchRequests.begin();
    _shellSearchDebounce?.cancel();
    if (!mounted) return;
    setState(() {
      _tree = null;
      _selectedId = null;
      _paneSelectedId = null;
      _searchCategoryId = null;
      _visibleFilterIds = null;
      _searchLoading = false;
      _acceptPendingSearch = false;
      _error = null;
      _searchError = null;
      _loading = shellCanViewCategories;
      _shellDetailEpoch++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(sensitiveReadBoundaryProvider) == next) {
        shellReload();
      }
    });
  }

  // ---- 树加载 -------------------------------------------------------------

  /// 整页刷新（2026-09-05 用户口径：右上角刷新=刷新整个页面）：分类树 +
  /// 选中分类的右栏（内容列表/facets/结算方式等）整体重拉重挂。
  Future<void> shellReloadAll() async {
    if (!mounted) return;
    if (!await confirmMasterInlineLeave(context) || !mounted) return;
    setState(() => _shellDetailEpoch++);
    await shellReload();
  }

  /// 拉分类树（页面 onDataChanged / 刷新按钮 / CRUD 成功后都会走这里）。
  Future<void> shellReload() async {
    if (!mounted) return;
    final generation = _treeRequests.begin();
    if (!shellCanViewCategories) {
      setState(() {
        _tree = const [];
        _selectedId = null;
        _paneSelectedId = null;
        _searchCategoryId = null;
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
      final tree = await shellLoadTree();
      if (!mounted ||
          !_treeRequests.isCurrent(generation) ||
          !shellCanViewCategories) {
        return;
      }
      setState(() {
        _tree = tree;
        // 不预选分类：默认右侧空态「请选择左侧分类」，点了分类才拉内容（省资源）。
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_treeRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_treeRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载分类树失败，请稍后重试'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  // ---- 顶部统一搜索（分类名 + 内容名 → 定位分类）----------------------------

  bool _inlineLeavePrompt = false;
  int _searchFieldRevision = 0;

  void _onGlobalSearchInput(String raw) async {
    if (_inlineLeavePrompt) return;
    _inlineLeavePrompt = true;
    final canLeave = await confirmMasterInlineLeave(context);
    _inlineLeavePrompt = false;
    if (!mounted) return;
    if (!canLeave) {
      setState(() => _searchFieldRevision++);
      return;
    }
    _shellSearchDebounce?.cancel();
    _searchRequests.begin();
    if (!mounted) return;
    final q = raw.trim();
    shellSearchQueryChanged(q);
    _acceptPendingSearch = true;
    setState(() {
      if (q.isEmpty) _searchCategoryId = null;
      _globalQuery = q;
      _searchError = null;
      // Only invalidate commands here. Tree matching/ranking waits for the
      // same committed query as the right pane, rather than scanning per key.
      if (q.isEmpty) _visibleFilterIds = null;
      _searchLoading = q.isNotEmpty;
    });
    // Keep debounce alive when the input moves between an empty state, the
    // split view and a compact hierarchy panel.
    if (q.isEmpty) {
      _onGlobalSearch(q);
    } else {
      _shellSearchDebounce = Timer(
        const Duration(milliseconds: 300),
        () => _onGlobalSearch(q),
      );
    }
  }

  @override
  void dispose() {
    _shellSearchDebounce?.cancel();
    super.dispose();
  }

  void _onGlobalSearch(String raw) {
    final q = raw.trim();
    if (!mounted || !_acceptPendingSearch || q != _globalQuery) return;
    _shellSearchDebounce?.cancel();
    _acceptPendingSearch = false;
    _applyGlobalSearch(q);
  }

  Future<void> _applyGlobalSearch(String q) async {
    final tree = _tree;
    final generation = _searchRequests.begin();
    if (!shellCanViewCategories) {
      setState(() {
        _globalQuery = q;
        _treeSearchKeyword = q;
        _searchCategoryId = null;
        _visibleFilterIds = null;
        _searchLoading = false;
        _searchError = null;
      });
      return;
    }
    if (q.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null; // 清空：恢复全树
        _treeSearchKeyword = null; // 同时解除右侧列表的搜索过滤
        _searchLoading = false;
        _searchError = null;
      });
      return;
    }
    final catHits = categoryHits(tree ?? const <ProductCategoryNode>[], q);
    setState(() {
      _globalQuery = q;
      _visibleFilterIds = catHits;
      _treeSearchKeyword = q;
      _searchLoading = true;
      _searchError = null;
    });
    try {
      final contentCategoryIds = await shellContentCategoryIds(
        q,
        () => mounted && _searchRequests.isCurrent(generation),
      );
      if (contentCategoryIds == null ||
          !mounted ||
          !_searchRequests.isCurrent(generation)) {
        return;
      }
      final resolution = resolveHierarchySearch(
        roots: tree ?? const <ProductCategoryNode>[],
        query: q,
        contentCategoryIds: contentCategoryIds,
      );
      setState(() {
        _visibleFilterIds = resolution.visibleIds;
        _treeSearchKeyword = q;
        _searchLoading = false;
        _searchError = null;
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

  void _selectCategory(String id) async {
    if (_inlineLeavePrompt) return;
    _inlineLeavePrompt = true;
    final canLeave = await confirmMasterInlineLeave(context);
    _inlineLeavePrompt = false;
    if (!mounted || !canLeave) return;
    if (_globalQuery.isNotEmpty) {
      setState(() => _searchCategoryId = id);
      shellRefreshSearch();
      return;
    }
    _searchRequests.begin();
    _acceptPendingSearch = false;
    setState(() {
      _selectedId = id;
      _treeSearchKeyword = null;
      _searchLoading = false;
    });
    _syncPaneSelectionNextFrame();
  }

  /// 右栏跟随选中但**延后一帧**换挂（2026-10-19 用户口径「点击前端不卡」）：
  /// 点击帧只重建左树（选中高亮 + 色块滑入动画起步），右栏详情/列表下一帧再
  /// 换挂并发起数据请求——「树重建 + 右栏重挂 + 折叠布局」不再挤同一帧把
  /// 动画吃掉。选中本身（`_selectedId`）仍即时生效，树高亮不延迟。
  void _syncPaneSelectionNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _paneSelectedId == _selectedId) return;
      setState(() => _paneSelectedId = _selectedId);
    });
  }

  Future<void> _deleteCategoryAfterDraft(ProductCategoryNode node) async {
    if (!shellCanDelete) return;
    if (!await confirmMasterInlineLeave(context) || !mounted) return;
    if (!shellCanDelete) return;
    await shellDeleteNode(node);
  }

  /// A deliberate scope or search-mode change invalidates the whole query,
  /// including facets, selection and exports, even for an A -> B -> A toggle.
  void shellRefreshSearch() {
    if (!mounted || _globalQuery.isEmpty) return;
    _shellSearchDebounce?.cancel();
    _searchRequests.begin();
    setState(() {
      _searchRevision++;
      _acceptPendingSearch = false;
    });
    _applyGlobalSearch(_globalQuery);
  }

  Widget _buildGlobalSearchBox() {
    final showScope = _globalQuery.isNotEmpty && shellCanViewCategories;
    return Padding(
      padding: const EdgeInsets.only(
        top: UtenSpacing.s12,
        bottom: UtenSpacing.s8,
      ),
      child: UtenMotion(
        duration: UtenAnim.fast,
        builder: (context, duration) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenHierarchySearchHeader(
              search: UtenSearchBar(
                key: ValueKey('master-search-$_searchFieldRevision'),
                initialValue: _globalQuery,
                hint: shellCanViewCategories
                    ? shellSearchHint
                    : basicDataL10n(context).masterEntitySearchHint,
                onInputChanged: _onGlobalSearchInput,
                onChanged: _onGlobalSearch,
              ),
              trailing: shellCanViewCategories && shellCanCreate
                  ? IconButton.filledTonal(
                      key: const ValueKey('category-add-root'),
                      tooltip: '新增最外层分类',
                      constraints: BoxConstraints(
                        minWidth: UtenControlMetrics.minimumHitExtent(
                          context,
                          desktop: 36,
                        ),
                        minHeight: UtenControlMetrics.minimumHitExtent(
                          context,
                          desktop: 36,
                        ),
                      ),
                      style: IconButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                          borderRadius: UtenRadius.controlAll,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: _loading
                          ? null
                          : () => shellShowCreateDialog(),
                      icon: const Icon(Icons.create_new_folder_outlined),
                    )
                  : null,
            ),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: showScope ? 1 : 0),
              duration: duration,
              curve: UtenAnim.standard,
              builder: (context, factor, child) => ClipRect(
                child: Align(
                  alignment: Alignment.topLeft,
                  heightFactor: factor,
                  child: child,
                ),
              ),
              child: ExcludeFocus(
                excluding: !showScope,
                child: ExcludeSemantics(
                  excluding: !showScope,
                  child: IgnorePointer(
                    ignoring: !showScope,
                    child: TickerMode(
                      enabled: showScope,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: UtenSpacing.s8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _searchCategoryId == null
                                      ? '搜索范围：全部分类'
                                      : '搜索范围：${utenTreeSelectionPath(_tree ?? const <ProductCategoryNode>[], _searchCategoryId) ?? '所选分类'}',
                                  key: const ValueKey('category-search-scope'),
                                  softWrap: true,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              if (_searchCategoryId != null)
                                IconButton(
                                  tooltip: '清除分类范围，搜索全部分类',
                                  onPressed: () async {
                                    if (!await confirmMasterInlineLeave(
                                          context,
                                        ) ||
                                        !mounted) {
                                      return;
                                    }
                                    setState(() => _searchCategoryId = null);
                                    shellRefreshSearch();
                                  },
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                ),
                            ],
                          ),
                          ...shellSearchOptions(context),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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

  Future<void> shellShowCreateDialog({ProductCategoryNode? parent}) async {
    if (!shellCanCreate) return;
    if (!await confirmMasterInlineLeave(context) || !mounted) return;
    final descriptor = shellCategoryDraftDescriptor;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => CategoryEditDialog(
        draftSpec: descriptor.spec(parentId: parent?.id),
        resumeDraftId: dialogDraftId(context, kind: 'category'),
        routerPageKey: dialogDraftPageKey(context),
        tree: _tree ?? const <ProductCategoryNode>[],
        initialParent: parent,
        onCheckPrefix: (prefix) => shellPrefixAvailability(prefix),
        onSubmit: (r) => _doCreate(r),
      ),
    );
  }

  Future<bool> _doCreate(CategoryEditResult r) async {
    if (!shellCanCreate) {
      context.appInfo('当前没有新增分类权限');
      return false;
    }
    final created = await shellCreateCategory(r);
    if (mounted) {
      _shellSearchDebounce?.cancel();
      _searchRequests.begin();
      setState(() {
        _globalQuery = '';
        shellSearchQueryChanged('');
        _searchCategoryId = null;
        _treeSearchKeyword = null;
        _visibleFilterIds = null;
        _searchLoading = false;
        _searchError = null;
        _acceptPendingSearch = false;
        _selectedId = created.id;
      });
      _syncPaneSelectionNextFrame();
      context.appSuccess('分类已创建');
      await shellReload();
      if (mounted) shellAfterCategorySaved();
    }
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
        onCheckPrefix: (prefix) =>
            shellPrefixAvailability(prefix, categoryId: detail.id),
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

  /// 树行「编辑」动作：先按 id 拉分类详情（编辑弹窗要 Detail，树节点没有），
  /// 拉取失败走统一错误提示；成功后再开 [shellShowEditDialog]。
  Future<void> _editCategoryNode(ProductCategoryNode node) async {
    if (!shellCanEdit) return;
    if (!await confirmMasterInlineLeave(context) || !mounted) return;
    ProductCategoryDetail? loaded;
    final ok = await context.guardRun(
      () async {
        loaded = await shellLoadCategoryDetail(node.id);
      },
      errorFallback: '加载分类详情失败，请稍后重试', // TODO(l10n): 补 arb
    );
    // 闭包里赋值的局部变量不做流提升，先落非空再传。
    final detail = loaded;
    if (!ok || detail == null || !mounted || !shellCanEdit) return;
    shellShowEditDialog(detail);
  }

  /// 删除成功后的收尾：清掉指向已删分类的选中态（调用方随后 shellReload）。
  void shellAfterCategoryDeleted(String nodeId) {
    if (_selectedId == nodeId) {
      _selectedId = null;
      _syncPaneSelectionNextFrame();
    }
  }

  /// 顶部搜索命中内容时的右栏同步关键词（DetailPane externalKeyword 用）。
  String? get shellTreeSearchKeyword => _treeSearchKeyword;

  bool get shellSearchPending => _acceptPendingSearch;

  String get shellSearchQuery => _globalQuery;
  String? get shellSelectedId {
    if (!shellCanViewCategories) return null;
    final id = _globalQuery.isEmpty ? _selectedId : _searchCategoryId;
    final node = id == null ? null : _findById(_tree ?? const [], id);
    return node == null || shellIsVirtualNode(node) ? null : id;
  }

  String? get shellSearchCategoryId =>
      shellCanViewCategories ? _searchCategoryId : null;

  /// 当前分类树（product 页分批搜索钩子需要根节点列表；其它页面一般用不到）。
  List<ProductCategoryNode>? get shellTree =>
      shellCanViewCategories ? _tree : null;

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

  Set<String>? get _treeVisibleIds {
    final ids = _visibleFilterIds;
    if (ids == null || _searchCategoryId == null) return ids;
    final visible = <String>{...ids};
    addAncestors(
      _tree ?? const <ProductCategoryNode>[],
      _searchCategoryId!,
      visible,
    );
    return visible;
  }

  Widget _buildTree({required void Function(String id) onSelect}) {
    return UtenCategoryTreeView(
      // Management receives persisted UUID roots. A sole business root is still
      // a real category, so adding its peer must not change the existing depth.
      nodes: _tree ?? const <ProductCategoryNode>[],
      flatLevelColors: true,
      nodeEnabledPredicate: (_) => true,
      selectedIds: {?(_globalQuery.isEmpty ? _selectedId : _searchCategoryId)},
      expandOnRowTap: true,
      showSearch: false,
      initiallyExpandDepth: shellInitiallyExpandDepth,
      initiallyCollapsedNames: shellInitiallyCollapseUncategorized
          ? const {'未分类'}
          : const {},
      visibleFilterIds: _treeVisibleIds,
      externalSearchQuery: _treeSearchKeyword,
      externalSearchLoading: _searchLoading,
      externalSearchError: _searchError,
      header: _buildGlobalSearchBox(),
      onNodeTap: (node) => onSelect(node.id),
      trailingBuilder: _treeRowActionsCached,
      rowMenuBuilder: _treeRowMenu,
    );
  }

  /// 左树初始展开深度（depth < 该值的节点展开）。默认 1；挂了虚拟总根的页
  /// （如模具页「全部模具」）真实分类整体下沉一层，覆写为 2 保持原有初始视野。
  int get shellInitiallyExpandDepth => 1;

  // ---- 分类动作 ---------------------------------------------------------
  // 管理动作在详情卡右上角菜单与树右键/长按菜单复用；左树只留系统保护提示。
  // 系统根保留新增，禁止改删；虚拟节点没有写动作。
  bool _isSystemRoot(ProductCategoryNode node) =>
      isSystemUncategorizedCategory(systemManaged: node.systemManaged);

  /// 保护提示按树快照和权限缓存，菜单在打开时重新解析当前动作。
  final _rowActionsCache = <String, Widget>{};
  final _rowOperationsCache = <String, UtenHierarchyNodeOperations>{};
  List<ProductCategoryNode>? _rowActionsTree;

  String _treeRowCacheKey(ProductCategoryNode node) {
    if (!identical(_rowActionsTree, _tree)) {
      _rowActionsTree = _tree;
      _rowActionsCache.clear();
      _rowOperationsCache.clear();
    }
    return '${Theme.of(context).brightness}'
        '|$shellCanCreate|$shellCanEdit|$shellCanDelete|${node.id}';
  }

  UtenHierarchyNodeOperations _treeOperationsCached(ProductCategoryNode node) =>
      _rowOperationsCache[_treeRowCacheKey(node)] ??= _treeOperations(node);

  Widget _treeRowActionsCached(ProductCategoryNode node) =>
      _rowActionsCache[_treeRowCacheKey(node)] ??= UtenHierarchyNodeActions(
        operations: _treeOperationsCached(node),
      );

  /// 权限、系统保护与草稿离开流程只定义一次，详情卡和右键共享同一动作。
  UtenHierarchyNodeOperations _treeOperations(ProductCategoryNode node) {
    if (shellIsVirtualNode(node)) return const UtenHierarchyNodeOperations();
    final systemRoot = _isSystemRoot(node);
    return UtenHierarchyNodeOperations(
      add: shellCanCreate
          ? UtenHierarchyNodeOperation(
              label: '新增子分类', // TODO(l10n): 补 arb
              tooltip: '新增${node.name}的子分类', // TODO(l10n): 补 arb
              buttonKey: const ValueKey('category-node-add'),
              icon: Icons.add_outlined,
              onInvoke: () => shellShowCreateDialog(parent: node),
            )
          : null,
      edit: shellCanEdit && !systemRoot
          ? UtenHierarchyNodeOperation(
              label: '编辑分类', // TODO(l10n): 补 arb
              tooltip: '编辑${node.name}', // TODO(l10n): 补 arb
              buttonKey: const ValueKey('category-node-edit'),
              icon: Icons.edit_outlined,
              onInvoke: () => _editCategoryNode(node),
            )
          : null,
      delete: shellCanDelete && !systemRoot
          ? UtenHierarchyNodeOperation(
              label: '删除分类', // TODO(l10n): 补 arb
              tooltip: '删除${node.name}', // TODO(l10n): 补 arb
              buttonKey: const ValueKey('category-node-delete'),
              icon: Icons.delete_outline,
              destructive: true,
              onInvoke: () => _deleteCategoryAfterDraft(node),
            )
          : null,
      deleteReplacement: shellCanDelete && systemRoot
          ? const SystemMasterCategoryProtectionNotice(compact: true)
          : null,
    );
  }

  List<UtenContextMenuEntry> _treeRowMenu(ProductCategoryNode node) => [
    ..._treeOperations(node).menuEntries,
    if (_treeOperations(node).menuEntries.isNotEmpty) const UtenMenuDivider(),
    ...utenHierarchyCopyEntries(
      context,
      name: node.name,
      path: utenTreeSelectionPath(
        _tree ?? const <ProductCategoryNode>[],
        node.id,
      ),
    ),
  ];

  // ---- build 骨架 ---------------------------------------------------------

  /// 页面 build 主体；选中分类的详情卡与左树复用同一份分类操作菜单。
  Widget buildShell(
    BuildContext context, {
    required Widget Function(ProductCategoryNode selected) detailPaneBuilder,
    Widget Function(String query)? searchPaneBuilder,
  }) => FormDraftDialogResume(
    descriptor: shellCategoryDraftDescriptor,
    ready: shellCanViewCategories && _tree != null && !_loading,
    onResume: (parameters) async {
      final parentId = parameters['parentId'];
      final parent = parentId == null ? null : _findById(_tree ?? [], parentId);
      if (parentId != null && parent == null) {
        throw StateError('草稿的上级分类已不存在');
      }
      await shellShowCreateDialog(parent: parent);
    },
    child: _buildDraftCategoryHost(
      context,
      detailPaneBuilder: detailPaneBuilder,
      searchPaneBuilder: searchPaneBuilder,
    ),
  );

  Widget _buildDraftCategoryHost(
    BuildContext context, {
    required Widget Function(ProductCategoryNode selected) detailPaneBuilder,
    Widget Function(String query)? searchPaneBuilder,
  }) {
    ref.watch(currentPermissionsProvider);
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final tree = _tree ?? const <ProductCategoryNode>[];
    // 右栏跟随延后一帧的选中（[_syncPaneSelectionNextFrame]）：点击帧树高亮
    // 与色块动画先上屏，右栏下一帧再换挂。
    final selected = _paneSelectedId == null
        ? null
        : _findById(tree, _paneSelectedId!);
    final canCreate = shellCanCreate;

    Widget detailPaneOf(ProductCategoryNode selectedNode) => KeyedSubtree(
      // 壳层代际重挂（shellReloadAll 递增）：右栏随刷新按钮整体重拉，
      // 各分类页私有的 detail epoch 机制保留不动（保存后局部重挂仍有效）。
      key: ValueKey('shell-detail-${selectedNode.id}-$_shellDetailEpoch'),
      child: UtenHierarchyDetailMenu(
        entriesBuilder: () => _treeRowMenu(selectedNode),
        child: detailPaneBuilder(selectedNode),
      ),
    );

    Widget mainLayout() {
      return UtenSplitView(
        persistenceKey: shellPersistenceKey,
        minTwoPaneWidth: 840,
        selectedLeadingLabel: _globalQuery.isEmpty
            ? utenTreeSelectionPath(tree, _selectedId)
            : _searchCategoryId == null
            ? '全部分类'
            : utenTreeSelectionPath(tree, _searchCategoryId),
        selectedLeadingKey: _globalQuery.isEmpty
            ? _selectedId
            : _searchCategoryId,
        compactHeader: _buildGlobalSearchBox(),
        leading: _buildTree(onSelect: _selectCategory),
        trailing: _treeSearchKeyword != null && searchPaneBuilder != null
            ? KeyedSubtree(
                key: ValueKey(
                  'shell-global-search-$_shellDetailEpoch-$_searchRevision',
                ),
                child: searchPaneBuilder(_treeSearchKeyword!),
              )
            : selected == null
            ? Center(
                child: Text(
                  '请选择分类查看详情', // TODO(l10n): 补 arb
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : detailPaneOf(selected),
      );
    }

    Widget body;
    if (!shellCanViewCategories && searchPaneBuilder != null) {
      body = Column(
        children: [
          _buildGlobalSearchBox(),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(
                'shell-entity-list-$_shellDetailEpoch-$_searchRevision',
              ),
              child: searchPaneBuilder(_treeSearchKeyword ?? ''),
            ),
          ),
        ],
      );
    } else if (shellKeepTreeMounted && tree.isNotEmpty) {
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
      // Keep the input in the same slot when the first character starts a
      // global search. Switching this Column to SplitView disposes its active
      // text input connection before the next character can arrive.
      body = Column(
        children: [
          _buildGlobalSearchBox(),
          Expanded(
            child: _treeSearchKeyword != null && searchPaneBuilder != null
                ? KeyedSubtree(
                    key: ValueKey(
                      'shell-global-search-$_shellDetailEpoch-$_searchRevision',
                    ),
                    child: searchPaneBuilder(_treeSearchKeyword!),
                  )
                : UtenEmpty(
                    icon: shellEmptyIcon,
                    message: '暂无$shellContentNoun分类', // TODO(l10n): 补 arb
                    description: canCreate
                        ? '还没有任何分类，新建第一个吧'
                        : null, // TODO(l10n): 补 arb
                    actionLabel: canCreate ? '新建分类' : null, // TODO(l10n): 补 arb
                    onAction: canCreate ? () => shellShowCreateDialog() : null,
                  ),
          ),
        ],
      );
    } else {
      body = mainLayout();
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: shellTitle, // TODO(l10n): 补 arb
        // 显式返回到基础资料 hub（默认返回会因 context.go 不压栈而兜底回工作台）。
        leading: UtenBackButton(
          onPressed: () async {
            if (!await confirmMasterInlineLeave(context) || !context.mounted) {
              return;
            }
            backTo(context, defaultPath: RouteName.basicinfo);
          },
        ),
        actions: [
          if (const {
                'basicData.client': 'clients',
                'basicData.supplier': 'suppliers',
                'basicData.mould': 'moulds',
              }[shellPersistenceKey]
              case final entityType?)
            MasterOperationHistoryActions(
              entityType: entityType,
              categoryId: shellSelectedId,
              onChanged: shellReloadAll,
            ),
          ...shellExtraAppBarActions(
            context,
            compact: bp == UtenBreakpoint.compact,
            treeNotEmpty: tree.isNotEmpty,
          ),
          UtenRefreshButton(busy: _loading, onRefresh: shellReloadAll),
        ],
      ),
      // 页面级局部 SelectionArea：分类树/详情面板/空态文字可框选复制（准则 §3.4）。
      // 内嵌 MasterDataTableView 自带更深层 region，嵌套各管各的；AppBar 不进选择区。
      body: SafeArea(child: UtenSelectionArea(child: body)),
    );
  }
}
