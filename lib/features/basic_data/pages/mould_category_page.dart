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
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
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
import '../widgets/uten_category_tree_view.dart';

class MouldCategoryPage extends ConsumerStatefulWidget {
  const MouldCategoryPage({super.key});

  @override
  ConsumerState<MouldCategoryPage> createState() => _MouldCategoryPageState();
}

class _MouldCategoryPageState extends ConsumerState<MouldCategoryPage> {
  List<ProductCategoryNode>? _tree;
  String? _selectedId;
  bool _loading = true;
  String? _error;

  // 顶部统一搜索（分类名 + 模具名）→ 定位分类：visibleFilterIds 驱动树只显示命中分类 + 祖先链。
  Set<String>? _visibleFilterIds;
  String _globalQuery = '';

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

  void _onGlobalSearch(String q) => _applyGlobalSearch(q.trim());

  Future<void> _applyGlobalSearch(String q) async {
    final tree = _tree;
    if (tree == null || tree.isEmpty) return;
    if (q.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null; // 清空：恢复全树
      });
      return;
    }
    _globalQuery = q;
    // ① 同步：分类名命中（+祖先+子树），先渲染即时结果。
    final catHits = categoryHits(tree, q);
    setState(() => _visibleFilterIds = catHits);
    // ② 异步：模具名命中 → 取其 categoryId（+祖先），合并并定位到第一个命中分类。
    try {
      final result = await ref.read(mouldRepositoryProvider).search(q, size: 50);
      if (!mounted || _globalQuery != q) return; // 过期结果丢弃
      final ids = <String>{};
      String? first;
      for (final m in result.items) {
        final cid = m.categoryId;
        if (cid == null || cid.isEmpty) continue;
        ids.add(cid);
        first ??= cid;
      }
      if (ids.isEmpty) {
        final firstCat = shallowestHit(tree, q, catHits);
        setState(() {
          _visibleFilterIds = catHits;
          if (firstCat != null && _selectedId != firstCat) {
            _selectedId = firstCat;
          }
        });
        return;
      }
      final merged = <String>{...catHits, ...ids};
      for (final cid in ids) {
        addAncestors(tree, cid, merged);
      }
      final target = first;
      setState(() {
        _visibleFilterIds = merged;
        if (_selectedId != target) _selectedId = target;
      });
    } catch (_) {
      // 搜索是辅助功能，失败静默（保留 ① 的分类命中结果）。
    }
  }

  /// 树顶部统一搜索框（搜分类名 + 搜模具定位分类；UtenSearchBar 已自带防抖与清除）。
  Widget _buildGlobalSearchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: UtenSearchBar(
        hint: '搜索分类/模具', // TODO(l10n): 补 arb
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

  /// 新建分类时的常用名称建议（降低起名门槛；模具类常用维度）。
  static const _categorySuggestions = ['注塑模具', '冲压模具', '压铸模具', '锻压模具', '夹具工装'];

  // ---- 创建/编辑/删除 -----------------------------------------------------

  void _showCreateDialog({ProductCategoryNode? parent}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => CategoryEditDialog(
        tree: _tree ?? const <ProductCategoryNode>[],
        initialParent: parent,
        suggestions: _categorySuggestions,
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
                code: r.code!,
                name: r.name,
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
    showDialog<void>(
      context: context,
      builder: (ctx) => CategoryEditDialog(
        tree: _tree ?? const <ProductCategoryNode>[],
        editing: detail,
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
              ProductCategoryUpdateInput(name: r.name, parentId: r.parentId),
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${node.name}」吗？若存在子分类或模具引用，删除可能失败。', // TODO(l10n): 补 arb
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
      header: _buildGlobalSearchBox(),
      onNodeTap: (node) => onSelect(node.id),
      trailingBuilder: (node) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.hasChildren)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                '${node.children.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (canEdit)
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
      ),
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
      body = selected == null
          ? const UtenEmpty(
              icon: Icons.precision_manufacturing_outlined,
              message: '请选择左侧分类查看详情', // TODO(l10n): 补 arb
            )
          : UtenContentContainer(
              child: _DetailPane(
                ref: ref,
                nodeId: selected.id,
                canEdit: canEdit,
                onAddChild: () => _showCreateDialog(parent: selected),
                onEdit: (detail) => _showEditDialog(detail),
                onDelete: () => _delete(selected),
              ),
            );
    } else {
      body = Row(
        children: [
          SizedBox(
            width: 300,
            child: _buildTree(
              onSelect: (id) => setState(() => _selectedId = id),
            ),
          ),
          Container(width: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: selected == null
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
                    onAddChild: () => _showCreateDialog(parent: selected),
                    onEdit: (detail) => _showEditDialog(detail),
                    onDelete: () => _delete(selected),
                  ),
          ),
        ],
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
                    setState(() => _selectedId = id);
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
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
  });

  final WidgetRef ref;
  final String nodeId;
  final bool canEdit;
  final VoidCallback onAddChild;
  final void Function(ProductCategoryDetail detail) onEdit;
  final VoidCallback onDelete;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
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

  /// 详情弹窗加载中（防并发）。
  /// 注意：与 [_mouldLoading]（模具分页列表的加载状态）是两回事，不可混用——
  /// 列表加载完后 [_mouldLoading] 恒为 false，无法防止详情弹窗被并发触发。
  bool _detailLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_DetailPane old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.ref
          .read(mouldCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置模具分页 + 筛选状态 + facet。
        _mouldPage = null;
        _mouldPageNum = 1;
        _mouldError = null;
        _filters = {};
        _keyword = '';
        _facets = null;
      });
      // 父分类也加载（后端按子树汇总）；并行拉模具列表与字段 facet。
      await Future.wait([_loadMoulds(1), _loadFacets()]);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载分类详情失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  // ---- 模具分页 ----------------------------------------------------------

  Future<void> _loadMoulds(int page) async {
    if (_mouldLoading) return; // 防连点：分页请求进行中时忽略
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
      if (!mounted) return;
      setState(() {
        _mouldPage = result;
        _mouldLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _mouldError = e.message;
        _mouldLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _mouldError = '加载模具列表失败'; // TODO(l10n): 补 arb
        _mouldLoading = false;
      });
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

  // 模具主档可编辑字段（与后端 MouldSaveRequest 对齐）。
  static const _mouldFields = [
    MasterFieldDef(key: 'name', label: '名称', required: true, group: '基础'),
    MasterFieldDef(
      key: 'code',
      label: '编号',
      group: '基础',
      readOnly: true,
      hint: '保存后自动生成',
    ),
    MasterFieldDef(key: 'mnumber', label: '备用编号', group: '基础'),
    MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
    MasterFieldDef(key: 'qty', label: '数量', group: '制造'),
    MasterFieldDef(
      key: 'tqty',
      label: '总数量',
      type: MasterFieldType.money,
      group: '制造',
    ),
    MasterFieldDef(key: 'mstatus', label: '制造年月', group: '制造'),
    MasterFieldDef(key: 'place', label: '车间', group: '制造'),
    MasterFieldDef(key: 'keeper', label: '保管人', group: '制造'),
    MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
  ];

  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.mouldEdit);

  // ---- 模具 新建/编辑/删除 ------------------------------------------------

  void _showMouldCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增模具', // TODO(l10n): 补 arb
      fields: _mouldFields,
      initialValues: const {'status': '使用'},
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

  void _showMouldEdit(MouldDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑模具', // TODO(l10n): 补 arb
      fields: _mouldFields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'mnumber': d.mnumber ?? '',
        'qty': d.qty ?? '',
        'tqty': d.tqty?.toString() ?? '',
        'mstatus': d.mstatus ?? '',
        'status': d.status ?? '',
        'place': d.place ?? '',
        'keeper': d.keeper ?? '',
        'remark': d.remark ?? '',
      },
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
    MasterDetailRow('旧编码', d.legacyId?.toString()), // TODO(l10n): 补 arb
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
    // compact：容器 gutter 已提供水平留白；medium+：详情面板需自带水平内边距。
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    final total = _mouldPage?.total ?? 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Column(
        children: [
          // 固定：分类信息卡（含编辑按钮）
          Padding(
            padding: const EdgeInsets.fromLTRB(
              0,
              UtenSpacing.s16,
              0,
              UtenSpacing.s12,
            ),
            child: MasterDetailCard(
              title: d.name,
              icon: Icons.precision_manufacturing_outlined,
              subtitle: '编码 ${d.code} · 层级 L${d.level}', // TODO(l10n): 补 arb
              stats: [
                MasterDetailStat(
                  '子分类数',
                  '${d.childCount}',
                ), // TODO(l10n): 补 arb
                MasterDetailStat('父级', d.parentName), // TODO(l10n): 补 arb
                MasterDetailStat(
                  '旧编码',
                  d.legacyId?.toString(),
                ), // TODO(l10n): 补 arb
              ],
              path: d.path.isEmpty ? null : d.path,
              canEdit: widget.canEdit,
              onAddChild: widget.onAddChild,
              onEdit: () {
                if (_detail != null) widget.onEdit(_detail!);
              },
              onDelete: widget.onDelete,
            ),
          ),
          // 固定：模具标题 + 添加按钮
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
          // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）
          Expanded(
            child: MasterDataTableView<MouldListItem>(
              columns: _mouldColumns,
              items: _mouldPage?.items ?? const [],
              facets: _facets?.fields ?? const {},
              nullCounts: _facets?.nullCounts ?? const {},
              filters: _filters,
              onFilterChanged: _onFilterChanged,
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
    );
  }

  // ---- 模具列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 模具表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  ///
  /// 列顺序按产品定义的 10 列。其中：
  /// - 有数据列（key 与后端 query/facet 字段对齐）：模具编号/模具名称/存放位置/制造日期/备注/状态。
  /// - 无数据列（V34 表无对应字段；模数/套数语义与 qty/tqty 不符按需求当无数据处理）：
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
