// 模具资料分类树管理页（基础资料）
//
// 与 product_category_page.dart（货品资料）同构：
// - 详情面板调 mouldCategoryRepository.detail + mouldRepository 分类下分页（子树范围）；
// - 编辑类按钮（新增/编辑/删除）按 mould_category:edit 权限显隐；查看全员可见（路由不设守卫）；
// - 复用 UtenCategoryTreeView / CategoryEditDialog / ProductCategoryNode（分类节点形状一致）；
// - 右侧用通用 MasterDataTableView（Excel 风格：搜索 + 横排 autofilter + 列对齐 + 分页）。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/05-模具资料-新库与迁移.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/mould_node.dart';
import '../models/product_category_node.dart';
import '../repositories/mould_category_repository.dart';
import '../repositories/mould_repository.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/system_master_category_guard.dart';
import '../widgets/uten_category_tree_view.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/widgets/department_employee_picker.dart';
import '../providers/mould_workshop_tree.dart';

class MouldCategoryPage extends ConsumerStatefulWidget {
  const MouldCategoryPage({super.key});

  @override
  ConsumerState<MouldCategoryPage> createState() => _MouldCategoryPageState();
}

class _MouldCategoryPageState extends ConsumerState<MouldCategoryPage> {
  final _searchRequests = LatestRequestGuard();
  List<ProductCategoryNode>? _tree;
  String? _selectedId;
  bool _loading = true;
  String? _error;

  // 顶部统一搜索（分类名 + 模具名）→ 定位分类：visibleFilterIds 驱动树只显示命中分类 + 祖先链。
  Set<String>? _visibleFilterIds;
  String _globalQuery = '';
  Set<String> _contentMatchCategoryIds = {};
  bool _searchLoading = false;
  String? _searchError;
  bool _acceptPendingSearch = false;

  // 顶部搜索命中模具时，右侧模具列表同步按该关键词过滤（只显示搜索结果，而非该分类全部）；
  // 清空搜索 / 仅分类名命中 / 手动点树节点时复位为 null。
  String? _treeSearchKeyword;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tree = await ref.read(mouldCategoryRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        // 不预选分类：默认右侧空态「请选择左侧分类」，点了分类才拉模具（省资源）。
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

  // ---- 顶部统一搜索（分类名 + 模具名 → 定位分类）----------------------------

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
    // ① 同步：分类名称/编号命中（+祖先+子树），先渲染即时结果。
    final catHits = categoryHits(tree, q);
    setState(() {
      _globalQuery = q;
      _visibleFilterIds = catHits;
      _contentMatchCategoryIds = {};
      _treeSearchKeyword = null;
      _searchLoading = true;
      _searchError = null;
    });
    // ② 异步：模具名称/编号等命中 → categoryId 补全祖先并定位首个有效分类。
    try {
      final repository = ref.read(mouldRepositoryProvider);
      final contentCategoryIds =
          await collectPagedHierarchyCategoryIds<MouldListItem>(
            loadPage: (page) => repository.search(q, page: page, size: 100),
            categoryIdOf: (item) => item.categoryId,
            isCurrent: () => mounted && _searchRequests.isCurrent(generation),
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
        _searchError = '模具搜索失败：${e.message}'; // TODO(l10n): 补 arb
      });
    } catch (_) {
      if (!mounted || !_searchRequests.isCurrent(generation)) return;
      setState(() {
        _searchLoading = false;
        _searchError = '模具搜索失败，请稍后重试'; // TODO(l10n): 补 arb
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

  /// 树顶部统一搜索框（搜分类名 + 搜模具定位分类；UtenSearchBar 已自带防抖与清除）。
  Widget _buildGlobalSearchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: UtenSearchBar(
        initialValue: _globalQuery,
        hint: '搜索分类/模具名称或编号', // TODO(l10n): 补 arb
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

  bool get _canEdit {
    final perms = ref.read(currentPermissionsProvider);
    return perms.contains(Perm.mouldCategoryEdit);
  }

  // ---- 创建/编辑/删除 -----------------------------------------------------

  void _showCreateDialog({ProductCategoryNode? parent}) {
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
    final ok = await context.guardRun(
      () async {
        await ref
            .read(mouldCategoryRepositoryProvider)
            .create(
              ProductCategorySaveInput(
                name: r.name,
                remark: r.remark,
                codePrefix: r.codePrefix,
                parentId: r.parentId,
              ),
            );
      },
      success: '分类已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _load();
    return true;
  }

  void _showEditDialog(ProductCategoryDetail detail) {
    if (isSystemUncategorizedCategory(systemManaged: detail.systemManaged)) {
      context.appInfo(systemUncategorizedCategoryProtectionMessage);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => CategoryEditDialog(
        tree: _tree ?? const <ProductCategoryNode>[],
        editing: detail,
        onPreviewPrefixChange: (prefix, parentId) => ref
            .read(mouldCategoryRepositoryProvider)
            .prefixPreview(detail.id, prefix, parentId: parentId),
        onSubmit: (r) => _doUpdate(detail.id, r),
      ),
    );
  }

  Future<bool> _doUpdate(String id, CategoryEditResult r) async {
    final ok = await context.guardRun(
      () async {
        await ref
            .read(mouldCategoryRepositoryProvider)
            .update(
              id,
              ProductCategoryUpdateInput(
                name: r.name,
                codePrefix: r.codePrefix,
                remark: r.remark,
                version: r.version ?? 0,
                parentId: r.parentId,
              ),
            );
      },
      success: '分类已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _load();
    return true;
  }

  Future<void> _delete(ProductCategoryNode node) async {
    if (isSystemUncategorizedCategory(systemManaged: node.systemManaged)) {
      context.appInfo(systemUncategorizedCategoryProtectionMessage);
      return;
    }
    // 先拉子树规模预览（后代分类数 + 模具数），用于红色确认框提示级联影响（问题 #7）。
    MouldCategoryDeletePreview? preview;
    try {
      preview = await ref
          .read(mouldCategoryRepositoryProvider)
          .deletePreview(node.id);
    } catch (_) {
      preview = null; // 预览失败不阻塞：退回无计数的通用确认。
    }
    if (!mounted) return;

    final hasCascade =
        preview != null &&
        (preview.descendantCount > 0 || preview.mouldCount > 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: UtenColors.error),
            SizedBox(width: UtenSpacing.s8),
            Text('删除分类'), // TODO(l10n): 补 arb
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定删除分类「${node.name}」吗？'), // TODO(l10n): 补 arb
            if (hasCascade) ...[
              const SizedBox(height: UtenSpacing.s12),
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: UtenColors.error.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: UtenColors.error.withValues(alpha: 0.45),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview!.descendantCount > 0)
                      Text(
                        '• ${preview.descendantCount} 个子分类',
                      ), // TODO(l10n): 补 arb
                    if (preview.mouldCount > 0)
                      Text('• ${preview.mouldCount} 个模具'), // TODO(l10n): 补 arb
                    const SizedBox(height: UtenSpacing.s4),
                    const Text(
                      '以上将随该分类一并删除，且不可恢复。', // TODO(l10n): 补 arb
                      style: TextStyle(color: UtenColors.error),
                    ),
                  ],
                ),
              ),
            ],
          ],
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
    final deleted = await context.guardRun(
      () async {
        await ref.read(mouldCategoryRepositoryProvider).delete(node.id);
      },
      success: '分类已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    if (_selectedId == node.id) _selectedId = null;
    await _load();
  }

  // ---- 树渲染 -------------------------------------------------------------

  Widget _buildTree({required void Function(String id) onSelect}) {
    final theme = Theme.of(context);
    final canEdit = _canEdit;
    return UtenCategoryTreeView(
      nodes: _tree ?? const <ProductCategoryNode>[],
      nodeEnabledPredicate: (_) => true,
      selectedIds: {?_selectedId},
      expandOnRowTap: true,
      showSearch: false,
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
            if (canEdit && isSystemRoot)
              const SystemMasterCategoryProtectionNotice(compact: true),
            if (canEdit && !isSystemRoot)
              InkWell(
                onTap: () => _delete(node),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final tree = _tree ?? const <ProductCategoryNode>[];
    final selected = _selectedId == null ? null : _findById(tree, _selectedId!);
    final canEdit = _canEdit;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: _load,
      );
    } else if (tree.isEmpty) {
      body = UtenEmpty(
        icon: Icons.precision_manufacturing_outlined,
        message: '暂无模具分类', // TODO(l10n): 补 arb
        description: canEdit ? '还没有任何分类，新建第一个吧' : null, // TODO(l10n): 补 arb
        actionLabel: canEdit ? '新建分类' : null, // TODO(l10n): 补 arb
        onAction: canEdit ? () => _showCreateDialog() : null,
      );
    } else if (bp == UtenBreakpoint.compact) {
      final compactDetail = selected == null
          ? const UtenEmpty(
              icon: Icons.precision_manufacturing_outlined,
              message: '请选择左侧分类查看详情', // TODO(l10n): 补 arb
            )
          : UtenContentContainer(
              child: _DetailPane(
                ref: ref,
                nodeId: selected.id,
                canEdit: canEdit,
                externalKeyword: _treeSearchKeyword,
                onAddChild: () => _showCreateDialog(parent: selected),
                onEdit: (detail) => _showEditDialog(detail),
                onDelete: () => _delete(selected),
              ),
            );
      body = Column(
        children: [
          _buildGlobalSearchBox(),
          Expanded(child: compactDetail),
        ],
      );
    } else {
      body = UtenSplitView(
        persistenceKey: 'basicData.mould',
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
            : _DetailPane(
                ref: ref,
                nodeId: selected.id,
                canEdit: canEdit,
                externalKeyword: _treeSearchKeyword,
                onAddChild: () => _showCreateDialog(parent: selected),
                onEdit: (detail) => _showEditDialog(detail),
                onDelete: () => _delete(selected),
              ),
      );
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '模具资料', // TODO(l10n): 补 arb
        // 显式返回到基础资料 hub（默认返回会因 context.go 不压栈而兜底回工作台）。
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: _load,
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

/// 模具分类详情面板：分类信息卡 + 该分类（子树）下的模具 Excel 表格。
class _DetailPane extends StatefulWidget {
  const _DetailPane({
    required this.ref,
    required this.nodeId,
    required this.canEdit,
    required this.externalKeyword,
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
  });

  final WidgetRef ref;
  final String nodeId;
  final bool canEdit;

  /// 顶部树搜索命中模具时传入的过滤词：详情面板把它采纳为本地模具列表的搜索词，
  /// 使右侧只显示本次搜索结果；为 null 时不过滤（显示该分类全部）。
  final String? externalKeyword;
  final VoidCallback onAddChild;
  final void Function(ProductCategoryDetail detail) onEdit;
  final VoidCallback onDelete;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
  final _detailRequests = LatestRequestGuard();
  final _listRequests = LatestRequestGuard();
  ProductCategoryDetail? _detail;
  bool _loading = true;
  String? _error;

  // 该分类（子树）下的模具分页；父分类也加载（子树汇总）。
  PagedResult<MouldListItem>? _mouldPage;
  int _mouldPageNum = 1;
  bool _mouldLoading = false;
  String? _mouldError;

  // 字段筛选 + 搜索 + facet（筛选栏用）。切换分类时重置。
  Map<String, String?> _filters = {};
  String _keyword = '';
  MouldFacets? _facets;

  // 搜索框重建种子：外部关键词（树搜索）变化时自增，驱动 UtenSearchBar 用新 initialValue 重建。
  int _kwSeed = 0;

  /// 详情弹窗加载中（防并发）。
  /// 注意：与 [_mouldLoading]（模具分页列表的加载状态）是两回事，不可混用——
  /// 列表加载完后 [_mouldLoading] 恒为 false，无法防止详情弹窗被并发触发。
  bool _detailLoading = false;

  /// 多选选中集（业务 id，跨页保留；批量禁用/删除用）。切换分类时清空。
  Set<String> _selectedMouldIds = {};

  /// 行操作进行中（启停/删除等）防并发。
  bool _rowOpBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_DetailPane old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) {
      _load();
      return;
    }
    // 同一分类下外部搜索词变化（树搜索命中/解除）：采纳为本地关键词并重查第 1 页。
    if (old.externalKeyword != widget.externalKeyword) {
      setState(() {
        _kwSeed++;
        _keyword = widget.externalKeyword ?? '';
      });
      _loadMoulds(1);
    }
  }

  Future<void> _load() async {
    final generation = _detailRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.ref
          .read(mouldCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置模具分页 + 筛选状态 + facet。
        _mouldPage = null;
        _mouldPageNum = 1;
        _mouldError = null;
        _filters = {};
        // 外部搜索词（树搜索命中）随分类切换一并带入：搜索定位时右侧只显示搜索结果。
        _keyword = widget.externalKeyword ?? '';
        _kwSeed++;
        _facets = null;
        _selectedMouldIds = {}; // 切分类清空多选（选中的是旧分类的行）
      });
      // 父分类也加载（后端按子树汇总）；并行拉模具列表与字段 facet。
      await Future.wait([_loadMoulds(1), _loadFacets()]);
    } on ApiException catch (e) {
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载分类详情失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  // ---- 模具分页 ----------------------------------------------------------

  Future<void> _loadMoulds(int page) async {
    final generation = _listRequests.begin();
    setState(() {
      _mouldLoading = true;
      _mouldError = null;
      _mouldPageNum = page;
    });
    try {
      final result = await widget.ref
          .read(mouldRepositoryProvider)
          .list(
            widget.nodeId,
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
          );
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _mouldPage = result;
      });
    } on ApiException catch (e) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _mouldError = e.message;
      });
    } catch (_) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _mouldError = '加载模具列表失败'; // TODO(l10n): 补 arb
      });
    } finally {
      if (mounted && _listRequests.isCurrent(generation)) {
        setState(() => _mouldLoading = false);
      }
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    try {
      final f = await widget.ref
          .read(mouldRepositoryProvider)
          .facets(widget.nodeId);
      if (!mounted) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key); // 选"所有"= 不筛
      } else {
        next[key] = value; // 具体值 或 kMasterFilterNullValue（空值）
      }
      _filters = next;
    });
    _loadMoulds(1); // 任一筛选变化回到第 1 页
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadMoulds(1);
  }

  /// 模具主档可编辑字段（与后端 MouldSaveRequest 对齐）。
  ///
  /// custom 字段（制造年月/车间/保管人）经 [MasterFieldDef.customBuilder] 嵌入
  /// UtenDateField / UtenDepartmentPicker / DepartmentEmployeePickerField（右滑入滑窗）。
  /// 闭包捕获 [iv]（初值 map）与 [widget.ref]，故为实例方法而非 static const。
  ///
  /// [workshop] 由调用方（_showMouldCreate/_showMouldEdit）提前 await 拿到，避免在这里
  /// 用 .read 读到还没 resolve 的 FutureProvider（autoDispose 首次打开必是 loading，
  /// .valueOrNull 永远 null，车间选择器会静默退化成全公司组织树——问题 #5 根因之一）。
  List<MasterFieldDef> _buildMouldFields(
    Map<String, String> iv,
    MouldWorkshopTree workshop,
  ) {
    return [
      const MasterFieldDef(
        key: 'name',
        label: '名称',
        required: true,
        group: '基础',
      ),
      const MasterFieldDef(
        key: 'code',
        label: '编号',
        group: '基础',
        hint: '留空自动生成',
      ),
      // 分类：只读显示外面选中分类名（添加模具即在当前分类下）；categoryId 走 fixedValues。
      const MasterFieldDef(
        key: 'categoryName',
        label: '分类',
        group: '基础',
        readOnly: true,
        hint: '当前分类',
      ),
      const MasterFieldDef(key: 'mnumber', label: '备用编号', group: '基础'),
      const MasterFieldDef(
        key: 'status',
        label: '状态',
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        required: true,
        group: '基础',
      ),
      const MasterFieldDef(key: 'qty', label: '数量', group: '制造'),
      const MasterFieldDef(
        key: 'tqty',
        label: '总数量',
        type: MasterFieldType.money,
        group: '制造',
      ),
      // 制造年月：日期选择窗（UtenDateField）；存 yyyy-MM-dd，兼容老库「2018年7月」初值。
      MasterFieldDef(
        key: 'mstatus',
        label: '制造年月',
        type: MasterFieldType.custom,
        group: '制造',
        customBuilder: (ctx) => UtenDateField(
          label: '制造年月',
          value: _parseMstatus(ctx.initialValue),
          onChanged: (date) => ctx.onChanged(_formatYmd(date)),
        ),
      ),
      // 车间：部门选择滑窗（仅制造与研发管理中心子树，默认只展开生产部，需点确定才生效，
      // 问题 #5）；落 departmentId，后端按 id 解析 place 文本。
      MasterFieldDef(
        key: 'departmentId',
        label: '车间',
        type: MasterFieldType.custom,
        group: '制造',
        customBuilder: (ctx) {
          final id = ctx.initialValue;
          return UtenDepartmentPicker(
            mode: UtenDepartmentPickerMode.single,
            label: '车间',
            hint: '选择生产车间',
            selectablePredicate: isBusinessDepartmentNode,
            treeOverride: workshop.tree.isEmpty ? null : workshop.tree,
            requireConfirm: true,
            expandOnRowTap: true,
            initiallyExpandedIds: workshop.prodDeptId == null
                ? const {}
                : {workshop.prodDeptId!},
            initialSelection: (id == null || id.isEmpty)
                ? const []
                : [
                    DeptSelection(
                      id: id,
                      name: iv['departmentName'] ?? '',
                      fullPath: '',
                      level: '',
                    ),
                  ],
            onChanged: (sel) =>
                ctx.onChanged(sel.isEmpty ? null : sel.first.id),
          );
        },
      ),
      // 保管人：先选部门（未展开的分类树）再挑人，也可跨部门搜姓名/工号（问题 #6）；
      // 落 keeperId，后端按 id 解析 keeper 文本。
      MasterFieldDef(
        key: 'keeperId',
        label: '保管人',
        type: MasterFieldType.custom,
        group: '制造',
        customBuilder: (ctx) {
          final id = ctx.initialValue;
          return DepartmentEmployeePickerField(
            label: '保管人',
            hint: '请选择保管人',
            initialId: id,
            initialName: iv['keeperName'],
            onChanged: ctx.onChanged,
            onPick: () => showUtenDepartmentEmployeePicker(
              context,
              widget.ref,
              title: '选择保管人',
            ),
          );
        },
      ),
      const MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
    ];
  }

  /// 解析制造年月初值：「2018-07-01」(ISO) / 「2018年7月」(老库中文) → DateTime；失败 null。
  DateTime? _parseMstatus(String? s) {
    if (s == null || s.isEmpty) return null;
    final iso = RegExp(r'^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$').firstMatch(s);
    if (iso != null) {
      return DateTime(
        int.parse(iso.group(1)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(3) ?? '1'),
      );
    }
    final cn = RegExp(r'(\d{4})\s*年\s*(\d{1,2})\s*月?').firstMatch(s);
    if (cn != null) {
      return DateTime(int.parse(cn.group(1)!), int.parse(cn.group(2)!));
    }
    return null;
  }

  /// DateTime → yyyy-MM-dd（提交/存储格式）。
  String _formatYmd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.mouldEdit);

  // ---- 模具 新建/编辑/删除 ------------------------------------------------

  /// 车间树需要先 await（FutureProvider 首次读永远是 loading，同步 .read 会拿到 null，
  /// 见 [_buildMouldFields] 上的注释），失败兜底空树（picker 退回全公司组织树，不阻断填表）。
  Future<MouldWorkshopTree> _loadWorkshopTree() async {
    try {
      return await widget.ref.read(mouldWorkshopTreeProvider.future);
    } catch (_) {
      return const MouldWorkshopTree(tree: [], prodDeptId: null);
    }
  }

  Future<void> _showMouldCreate() async {
    final workshop = await _loadWorkshopTree();
    if (!mounted) return;
    final iv = {'status': '使用', 'categoryName': _detail?.name ?? ''};
    showMasterEditDialog(
      context: context,
      title: '新增模具', // TODO(l10n): 补 arb
      fields: _buildMouldFields(iv, workshop),
      initialValues: iv,
      fixedValues: {'categoryId': widget.nodeId},
      onSubmit: _doCreateMould,
    );
  }

  Future<bool> _doCreateMould(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await widget.ref.read(mouldRepositoryProvider).create(body);
      },
      success: '模具已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadMoulds(_mouldPageNum);
    return true;
  }

  Future<void> _showMouldEdit(MouldDetail d) async {
    final workshop = await _loadWorkshopTree();
    if (!mounted) return;
    final iv = {
      'name': d.name ?? '',
      'code': d.code ?? '',
      'categoryName': d.categoryName ?? '',
      'mnumber': d.mnumber ?? '',
      'qty': d.qty ?? '',
      'tqty': d.tqty?.toString() ?? '',
      'mstatus': d.mstatus ?? '',
      'status': d.status ?? '',
      'departmentId': d.departmentId ?? '',
      'departmentName': d.departmentName ?? '',
      'keeperId': d.keeperId ?? '',
      'keeperName': d.keeperName ?? '',
      'remark': d.remark ?? '',
    };
    showMasterEditDialog(
      context: context,
      title: '编辑模具', // TODO(l10n): 补 arb
      fields: _buildMouldFields(iv, workshop),
      initialValues: iv,
      fixedValues: {'categoryId': d.categoryId ?? widget.nodeId},
      onSubmit: (body) => _doUpdateMould(d.id, body),
    );
  }

  Future<bool> _doUpdateMould(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await widget.ref.read(mouldRepositoryProvider).update(id, body);
      },
      success: '模具已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadMoulds(_mouldPageNum);
    return true;
  }

  Future<void> _deleteMould(MouldDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模具'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该模具')}」吗？', // TODO(l10n): 补 arb
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
    final deleted = await context.guardRun(
      () async {
        await widget.ref.read(mouldRepositoryProvider).delete(d.id);
      },
      success: '模具已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadMoulds(_mouldPageNum);
    // 删空当前页时回退上一页，避免列表显示空白
    if (mounted &&
        _mouldPage != null &&
        _mouldPage!.items.isEmpty &&
        _mouldPage!.page > 1) {
      await _loadMoulds(_mouldPage!.page - 1);
    }
  }

  // ---- 行菜单（右击/长按）+ 多选批量 --------------------------------------

  /// 详情 → 保存请求体（启停用；字段与编辑表单/后端 MouldSaveRequest 对齐，
  /// 全量回传仅改状态）。
  Map<String, dynamic> _mouldSaveBody(MouldDetail d, {String? status}) =>
      <String, dynamic>{
        'categoryId': d.categoryId ?? widget.nodeId,
        'name': d.name ?? '',
        'code': d.code,
        'mnumber': d.mnumber,
        'qty': d.qty,
        'tqty': d.tqty,
        'mstatus': d.mstatus,
        'status': status ?? d.status ?? '使用',
        'departmentId': d.departmentId,
        'keeperId': d.keeperId,
        'remark': d.remark,
      };

  /// 启用/禁用模具：拉详情全量回传、仅改状态。
  Future<void> _toggleMouldStatus(MouldListItem m) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    MouldDetail? d;
    try {
      d = await widget.ref.read(mouldRepositoryProvider).detail(m.id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载模具详情失败'); // TODO(l10n): 补 arb
    }
    if (d == null || !mounted) {
      _rowOpBusy = false;
      return;
    }
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => widget.ref
          .read(mouldRepositoryProvider)
          .update(d!.id, _mouldSaveBody(d, status: next)),
      success: next == '禁用' ? '模具已禁用' : '模具已启用', // TODO(l10n): 补 arb
    );
    if (ok && mounted) await _loadMoulds(_mouldPageNum);
    _rowOpBusy = false;
  }

  /// 菜单「编辑/删除」：先拉详情再走既有流程（编辑弹窗自带车间树加载）。
  Future<void> _withMouldDetail(
    String id,
    Future<void> Function(MouldDetail d) action,
  ) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    MouldDetail? d;
    try {
      d = await widget.ref.read(mouldRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载模具详情失败'); // TODO(l10n): 补 arb
    }
    _rowOpBusy = false;
    if (d != null && mounted) await action(d);
  }

  /// 行菜单条目（右击/长按弹出）。可用性按权限 + 行状态实时决定。
  List<UtenContextMenuEntry> _mouldMenuItems(MouldListItem m) {
    final inUse = m.status == '使用';
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _showMouldDetail(m.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: inUse ? '禁用模具' : '启用模具',
        icon: inUse
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        enabled: _canEditMaster,
        destructive: inUse,
        onTap: () => _toggleMouldStatus(m),
      ),
      UtenMenuItem(
        label: '编辑模具',
        icon: Icons.edit_outlined,
        enabled: _canEditMaster,
        onTap: () => _withMouldDetail(m.id, _showMouldEdit),
      ),
      UtenMenuItem(
        label: '删除模具',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canEditMaster,
        onTap: () => _withMouldDetail(m.id, _deleteMould),
      ),
    ];
  }

  List<Widget> _mouldBatchActions(BuildContext context, Set<String> ids) {
    if (!_canEditMaster) return const [];
    return [
      UtenButton(
        size: UtenButtonSize.small,
        type: UtenButtonType.tonal,
        icon: Icons.pause_circle_outline_rounded,
        onPressed: _rowOpBusy ? null : () => _batchSetMouldStatus(ids, '禁用'),
        child: const Text('批量禁用'), // TODO(l10n): 补 arb
      ),
      UtenButton(
        size: UtenButtonSize.small,
        type: UtenButtonType.danger,
        icon: Icons.delete_outline_rounded,
        onPressed: _rowOpBusy ? null : () => _batchDeleteMoulds(ids),
        child: const Text('批量删除'), // TODO(l10n): 补 arb
      ),
    ];
  }

  /// 批量启停：逐条拉详情全量回传、仅改状态（无专用批量接口，复用单条更新）。
  Future<void> _batchSetMouldStatus(Set<String> ids, String status) async {
    if (_rowOpBusy || ids.isEmpty) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(mouldRepositoryProvider);
    var okCount = 0;
    var skipped = 0;
    for (final id in ids) {
      try {
        final d = await repo.detail(id);
        if (d.status == status) {
          skipped++;
          continue;
        }
        await repo.update(id, _mouldSaveBody(d, status: status));
        okCount++;
      } catch (_) {
        skipped++;
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    setState(() => _selectedMouldIds = {});
    context.appSuccess(
      status == '禁用'
          ? '已禁用 $okCount 个模具${skipped > 0 ? '，$skipped 个跳过' : ''}'
          : '已启用 $okCount 个模具${skipped > 0 ? '，$skipped 个跳过' : ''}',
    );
    await _loadMoulds(_mouldPageNum);
  }

  /// 批量删除：确认后逐个删（容忍单条失败，如被生产引用）。
  Future<void> _batchDeleteMoulds(Set<String> ids) async {
    if (_rowOpBusy || ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除模具'), // TODO(l10n): 补 arb
        content: Text('确定删除选中的 ${ids.length} 个模具吗？被生产引用的模具会删除失败。'),
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
    if (ok != true || !mounted) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(mouldRepositoryProvider);
    var okCount = 0;
    final failed = <String>{};
    for (final id in ids) {
      try {
        await repo.delete(id);
        okCount++;
      } on ApiException catch (e) {
        failed.add(e.message);
      } catch (_) {
        failed.add('删除失败');
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    setState(() => _selectedMouldIds = {});
    context.appSuccess(
      '已删除 $okCount 个模具${failed.isNotEmpty ? '，${ids.length - okCount} 个失败' : ''}',
    );
    if (failed.isNotEmpty) context.appError(failed.first);
    await _loadMoulds(_mouldPageNum);
  }

  /// 点模具行：拉详情弹框展示核心字段。
  ///
  /// 用独立的 [_detailLoading] 防并发——不能用 [_mouldLoading]（那是分页列表
  /// 加载状态，列表加载完即恒为 false，起不到防连点作用）。否则并发触发
  /// showDialog 会让 Navigator 上多个对话框路由交错 push/pop，触发 element
  /// 生命周期断言（framework `_activateRecursively`：
  /// `_lifecycleState == _ElementLifecycle.inactive is not true`）。
  Future<void> _showMouldDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    // 预取 root navigator：showDialog 默认 useRootNavigator:true 把对话框 push 到
    // root navigator，pop 也必须用同一个 root。go_router 用嵌套 navigator 管理页面，
    // Navigator.of(context)（rootNavigator:false）会拿到 go_router 那层，误把当前页面
    // 本身 pop 掉（"popped the last page off of the stack" 断言 → 白屏）。
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    MouldDetail? d;
    try {
      d = await widget.ref.read(mouldRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) {
        context.appError('加载模具详情失败'); // TODO(l10n): 补 arb
      }
    }
    if (!mounted) {
      nav.pop(); // 页面已销毁：关闭可能残留的 loading 对话框
      return;
    }
    nav.pop(); // 关 loading
    if (d == null) {
      _detailLoading = false; // 失败：loading 已关，复位
      return;
    }
    // 成功：开详情面板，关闭后再复位 flag（面板期间继续禁止并发）。
    // 用局部 detail 捕获 non-null：d 是 nullable，跨闭包边界不再提升，
    // 直接在 onEdit/onDelete 里用 d 会报类型错。
    final detail = d;
    await showMasterDetailSheet(
      context: context,
      title: detail.name?.isNotEmpty == true
          ? detail.name!
          : (detail.code ?? '模具详情'),
      rows: _mouldDetailRows(detail),
      canEdit: _canEditMaster,
      onEdit: () => _showMouldEdit(detail),
      onDelete: () => _deleteMould(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _mouldDetailRows(MouldDetail d) => [
    MasterDetailRow('编号', d.code), // TODO(l10n): 补 arb
    MasterDetailRow('名称', d.name), // TODO(l10n): 补 arb
    MasterDetailRow('备用编号', d.mnumber), // TODO(l10n): 补 arb
    MasterDetailRow('数量', d.qty), // TODO(l10n): 补 arb
    MasterDetailRow('总数量', d.tqty?.toStringAsFixed(2)), // TODO(l10n): 补 arb
    MasterDetailRow('状态', d.status), // TODO(l10n): 补 arb
    MasterDetailRow('车间', d.place), // TODO(l10n): 补 arb
    MasterDetailRow('保管人', d.keeper), // TODO(l10n): 补 arb
    MasterDetailRow('制造年月', d.mstatus), // TODO(l10n): 补 arb
    MasterDetailRow('分类', d.categoryName), // TODO(l10n): 补 arb
    MasterDetailRow('备注', d.remark), // TODO(l10n): 补 arb
    MasterDetailRow('旧系统 ID', d.legacyId?.toString()), // TODO(l10n): 补 arb
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: _load,
      );
    }
    final d = _detail;
    if (d == null) {
      return Center(
        child: Text(
          '未选择分类', // TODO(l10n): 补 arb
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final isSystemRoot = isSystemUncategorizedCategory(
      systemManaged: d.systemManaged,
    );
    final canMutateCategory = canMutateMasterCategory(
      hasEditPermission: widget.canEdit,
      systemManaged: d.systemManaged,
    );
    // compact：容器 gutter 已提供水平留白；medium+：详情面板需自带水平内边距。
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    final total = _mouldPage?.total ?? 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: UtenCollapsingHeaderScrollView(
        // 滚走区：分类信息卡（含编辑按钮）—— 上滑即收起、腾出表格空间。
        collapsingHeader: Padding(
          padding: const EdgeInsets.fromLTRB(
            0,
            UtenSpacing.s16,
            0,
            UtenSpacing.s12,
          ),
          child: MasterDetailCard(
            title: d.name,
            icon: Icons.precision_manufacturing_outlined,
            subtitle:
                '编号前缀 ${d.effectivePrefix ?? 'MJ'}${d.codePrefix == null ? '（继承）' : ''}'
                '${d.remark?.isNotEmpty == true ? ' · ${d.remark}' : ''} · 层级 L${d.level}',
            // 详情卡精简（与货品/客户/供应商/收付方式分类卡统一）：不再展示统计行
            // 与路径行——左侧分类树已是主视觉，层级/父级/子项数树里都能看出，卡片只留标题+操作。
            stats: const [],
            canEdit: canMutateCategory,
            onAddChild: widget.onAddChild,
            onEdit: () {
              if (_detail != null) widget.onEdit(_detail!);
            },
            onDelete: widget.onDelete,
            deleteLabel: '删除分类', // TODO(l10n): 补 arb
            extraActions: [
              if (widget.canEdit && isSystemRoot)
                MasterDetailCardAction(
                  icon: Icons.add_rounded,
                  label: '新增子分类', // TODO(l10n): 补 arb
                  onPressed: widget.onAddChild,
                ),
            ],
            secondaryActions: [
              if (widget.canEdit && isSystemRoot)
                const SystemMasterCategoryProtectionNotice(),
            ],
          ),
        ),
        // body：模具标题 + 搜索 + 添加按钮（卡片收起后吸顶）+ 表格（内滚）。
        body: Column(
          children: [
            // 模具标题 + 搜索 + 添加按钮（与原布局一致：添加在搜索右侧）
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Row(
                children: [
                  Icon(
                    Icons.precision_manufacturing_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '模具 ($total)', // TODO(l10n): 补 arb
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: UtenSearchBar(
                      // key 含 nodeId + _kwSeed：切分类 / 树搜索写入关键词时重建搜索框同步显示。
                      key: ValueKey('mould-search-${widget.nodeId}-$_kwSeed'),
                      hint: '搜索模具（名称/编号/位置/备注）', // TODO(l10n): 补 arb
                      initialValue: _keyword,
                      onChanged: _onKeywordChanged,
                    ),
                  ),
                  if (_canEditMaster) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.add_rounded,
                      onPressed: _showMouldCreate,
                      child: const Text('添加模具'), // TODO(l10n): 补 arb
                    ),
                  ],
                ],
              ),
            ),
            // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）。
            // primary:true → 表体参与「卡片折叠 → 表格内滚」联动（拾取 NestedScrollView inner controller）。
            Expanded(
              child: MasterDataTableView<MouldListItem>(
                primary: true,
                columns: _mouldColumns,
                items: _mouldPage?.items ?? const [],
                // 多选：最前列勾选框 + 表头三态全选；选中非空时工具条出批量操作区。
                selectable: true,
                idOf: (m) => m.id,
                selectedIds: _selectedMouldIds,
                onSelectedIdsChanged: (s) =>
                    setState(() => _selectedMouldIds = s),
                batchActionsBuilder: _mouldBatchActions,
                // 行菜单（右击/长按）：查看/启用/禁用/编辑/删除。
                rowMenuBuilder: _mouldMenuItems,
                facets: _facets?.fields ?? const {},
                nullCounts: _facets?.nullCounts ?? const {},
                filters: _filters,
                onFilterChanged: _onFilterChanged,
                // 行底色按状态：使用=浅蓝、禁用=浅红；单击选中自动加深加亮。
                rowColor: (m) => switch (m.status) {
                  '使用' => Colors.lightBlue.withValues(alpha: 0.13),
                  '禁用' => Colors.red.withValues(alpha: 0.10),
                  _ => null,
                },
                onRowTap: (m) => _showMouldDetail(m.id),
                isLoading: _mouldLoading && _mouldPage == null,
                loadingMore: _mouldLoading && _mouldPage != null,
                error: _mouldError,
                onRetry: () => _loadMoulds(_mouldPageNum),
                emptyMessage: '该分类暂无模具', // TODO(l10n): 补 arb
                currentPage: _mouldPage?.page ?? 1,
                totalPages: _mouldPage?.totalPages ?? 1,
                onPageChange: (p) => _loadMoulds(p),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 模具列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 模具表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  ///
  /// 列顺序按产品定义的 10 列。其中：
  /// - 有数据列（key 与后端 query/facet 字段对齐）：模具编号/模具名称/存放位置/制造日期/备注/状态。
  /// - 无数据列（表无对应字段；模数/套数语义与 qty/tqty 不符按需求当无数据处理）：
  ///   模数/套数/模具类型/制造商——单元格取 null（表格显"—"），不进 FACET_COLUMNS 白名单
  ///   （下拉只显示"所有"），后端忽略其 query 参数。
  static final _mouldColumns = <MasterColumnDef<MouldListItem>>[
    MasterColumnDef(
      key: 'code',
      label: '模具编号',
      width: 120,
      value: (m) => m.code,
    ),
    MasterColumnDef(
      key: 'name',
      label: '模具名称',
      width: 180,
      value: (m) => m.name,
    ),
    MasterColumnDef(
      key: 'cavities',
      label: '模数',
      width: 80,
      value: (_) => null,
    ),
    MasterColumnDef(key: 'sets', label: '套数', width: 80, value: (_) => null),
    MasterColumnDef(
      key: 'mouldType',
      label: '模具类型',
      width: 120,
      value: (_) => null,
    ),
    MasterColumnDef(
      key: 'place',
      label: '存放位置',
      width: 140,
      value: (m) => m.place,
    ),
    MasterColumnDef(
      key: 'manufacturer',
      label: '制造商',
      width: 140,
      value: (_) => null,
    ),
    MasterColumnDef(
      key: 'mstatus',
      label: '制造日期',
      width: 110,
      value: (m) => m.mstatus,
    ),
    MasterColumnDef(
      key: 'remark',
      label: '备注',
      width: 200,
      value: (m) => m.remark,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 80,
      value: (m) => m.status,
    ),
  ];
}
