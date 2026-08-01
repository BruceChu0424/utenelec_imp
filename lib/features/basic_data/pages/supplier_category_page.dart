// 供应商资料分类树管理页（基础资料）
//
// 与 product_category_page.dart（货品）同构：
// - 详情面板调 supplierCategoryRepository.detail + supplierRepository 分类下分页（动态筛选）；
// - 表格走通用 MasterDataTableView（搜索 + 横排 autofilter 筛选 + 列对齐 + 分页）；
// - 字段 facet 走 /facets（19 个有数据列，主结账方式/损耗率无对应列不参与 facet）；
// - 编辑类按钮按 supplier_category:edit / supplier:edit 权限显隐；查看全员可见；
// - 复用 UtenCategoryTreeView（点行同时展开+选中）/ CategoryEditDialog / ProductCategoryNode。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/09-供应商资料-新库与迁移.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
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
import '../models/master_facet.dart';
import '../models/product_category_node.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_category_repository.dart';
import '../repositories/supplier_repository.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/uten_category_tree_view.dart';

class SupplierCategoryPage extends ConsumerStatefulWidget {
  const SupplierCategoryPage({super.key});

  @override
  ConsumerState<SupplierCategoryPage> createState() =>
      _SupplierCategoryPageState();
}

class _SupplierCategoryPageState extends ConsumerState<SupplierCategoryPage> {
  List<ProductCategoryNode>? _tree;
  String? _selectedId;
  bool _loading = true;
  String? _error;

  // 顶部统一搜索（分类名 + 供应商名）→ 定位分类：visibleFilterIds 驱动树只显示命中分类 + 祖先链。
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
      final tree = await ref.read(supplierCategoryRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        // 不预选分类：默认右侧空态「请选择左侧分类」，点了分类才拉供应商（省资源）。
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

  // ---- 顶部统一搜索（分类名 + 供应商名 → 定位分类）----------------------------

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
    final catHits = categoryHits(tree, q);
    setState(() => _visibleFilterIds = catHits);
    try {
      final result = await ref
          .read(supplierRepositoryProvider)
          .search(q, size: 50);
      if (!mounted || _globalQuery != q) return;
      final ids = <String>{};
      String? first;
      for (final s in result.items) {
        final cid = s.categoryId;
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
      // 搜索是辅助功能，失败静默（保留分类命中结果）。
    }
  }

  Widget _buildGlobalSearchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: UtenSearchBar(
        hint: '搜索分类/供应商', // TODO(l10n): 补 arb
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
    return perms.contains(Perm.supplierCategoryEdit);
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
            .read(supplierCategoryRepositoryProvider)
            .create(
              ProductCategorySaveInput(
                code: r.code,
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
            .read(supplierCategoryRepositoryProvider)
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
          '确定删除「${node.name}」吗？若存在子分类或供应商引用，删除可能失败。', // TODO(l10n): 补 arb
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
        await ref.read(supplierCategoryRepositoryProvider).delete(node.id);
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
        icon: Icons.local_shipping_outlined,
        message: '暂无供应商分类', // TODO(l10n): 补 arb
        description: canEdit ? '还没有任何分类，新建第一个吧' : null, // TODO(l10n): 补 arb
        actionLabel: canEdit ? '新建分类' : null, // TODO(l10n): 补 arb
        onAction: canEdit ? () => _showCreateDialog() : null,
      );
    } else if (bp == UtenBreakpoint.compact) {
      body = selected == null
          ? const UtenEmpty(
              icon: Icons.local_shipping_outlined,
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
        title: '供应商资料', // TODO(l10n): 补 arb
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

/// 供应商分类详情面板：分类信息卡 + 该分类（子树）下的供应商 Excel 表格（搜索+筛选+分页）。
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

  // 该分类（子树）下的供应商分页；父分类也加载（子树汇总）。
  PagedResult<SupplierListItem>? _supplierPage;
  int _supplierPageNum = 1;
  bool _supplierLoading = false;
  String? _supplierError;

  // 字段筛选 + 搜索 + facet（筛选栏用）。切换分类时重置。
  Map<String, String?> _filters = {};
  String _keyword = '';
  SupplierFacets? _facets;

  // 列排序态（金额/数量/日期列）：null = 默认顺序（id ASC）。
  String? _sortKey;
  bool _sortAsc = true;

  /// 详情弹窗加载中（防并发）。
  /// 注意：与 [_supplierLoading]（供应商分页列表的加载状态）是两回事，不可混用——
  /// 列表加载完后 [_supplierLoading] 恒为 false，无法防止详情弹窗被并发触发。
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
          .read(supplierCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置供应商分页 + 筛选状态 + facet + 排序态。
        _supplierPage = null;
        _supplierPageNum = 1;
        _supplierError = null;
        _filters = {};
        _keyword = '';
        _facets = null;
        _sortKey = null;
        _sortAsc = true;
      });
      // 父分类也加载（后端按子树汇总）；并行拉供应商列表与字段 facet。
      await Future.wait([_loadSuppliers(1), _loadFacets()]);
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

  // ---- 供应商分页 --------------------------------------------------------

  Future<void> _loadSuppliers(int page) async {
    if (_supplierLoading) return; // 防连点：分页请求进行中时忽略
    setState(() {
      _supplierLoading = true;
      _supplierError = null;
      _supplierPageNum = page;
    });
    try {
      final result = await widget.ref
          .read(supplierRepositoryProvider)
          .list(
            widget.nodeId,
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted) return;
      setState(() {
        _supplierPage = result;
        _supplierLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _supplierError = e.message;
        _supplierLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _supplierError = '加载供应商列表失败'; // TODO(l10n): 补 arb
        _supplierLoading = false;
      });
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    try {
      final f = await widget.ref
          .read(supplierRepositoryProvider)
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
    _loadSuppliers(1); // 任一筛选变化回到第 1 页
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadSuppliers(1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _loadSuppliers(1); // 排序变化回第 1 页重载
  }

  /// 导出查询参数（与 _loadSuppliers 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    'categoryId': widget.nodeId,
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 打印预览数据：按当前分类/筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await widget.ref
        .read(supplierRepositoryProvider)
        .list(
          widget.nodeId,
          size: 2000,
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          filters: _filters,
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    return UtenPrintTable(
      headers: [for (final c in _supplierColumns) c.label],
      rows: [
        for (final a in result.items)
          [for (final c in _supplierColumns) c.value(a) ?? ''],
      ],
    );
  }

  // 供应商主档可编辑字段（与后端 SupplierSaveRequest 对齐）。
  static const _supplierFields = [
    MasterFieldDef(key: 'name', label: '名称', required: true, group: '基础'),
    MasterFieldDef(
      key: 'code',
      label: '编号',
      group: '基础',
      readOnly: true,
      hint: '保存后自动生成',
    ),
    MasterFieldDef(key: 'description', label: '描述/全称', group: '基础'),
    MasterFieldDef(key: 'place', label: '地区', group: '地址'),
    MasterFieldDef(key: 'empId', label: '业务员', group: '资质'),
    MasterFieldDef(key: 'legalPerson', label: '法人', group: '资质'),
    MasterFieldDef(key: 'linkman', label: '联系人', group: '联系'),
    MasterFieldDef(key: 'mobile', label: '手机', group: '联系'),
    MasterFieldDef(key: 'phone', label: '电话', group: '联系'),
    MasterFieldDef(key: 'phone2', label: '电话2', group: '联系'),
    MasterFieldDef(key: 'fax', label: '传真', group: '联系'),
    MasterFieldDef(key: 'postcode', label: '邮编', group: '联系'),
    MasterFieldDef(key: 'address', label: '地址', group: '地址'),
    MasterFieldDef(key: 'email', label: '邮箱', group: '联系'),
    MasterFieldDef(key: 'website', label: '网址', group: '联系'),
    MasterFieldDef(key: 'shipVia', label: '运输方式', group: '地址'),
    MasterFieldDef(key: 'shipAddress', label: '收货地址', group: '地址'),
    MasterFieldDef(key: 'bank', label: '开户行', group: '财务'),
    MasterFieldDef(key: 'bankAccount', label: '银行账号', group: '财务'),
    MasterFieldDef(key: 'taxId', label: '税号', group: '财务'),
    MasterFieldDef(
      key: 'initTotal',
      label: '期初应付',
      type: MasterFieldType.money,
      group: '财务',
    ),
    MasterFieldDef(
      key: 'tday',
      label: '结算天数',
      type: MasterFieldType.integer,
      group: '财务',
    ),
    MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
    MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
  ];

  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.supplierEdit);

  // ---- 供应商 新建/编辑/删除 ----------------------------------------------

  void _showSupplierCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增供应商', // TODO(l10n): 补 arb
      fields: _supplierFields,
      initialValues: const {'status': '使用'},
      fixedValues: {'categoryId': widget.nodeId},
      onSubmit: _doCreateSupplier,
    );
  }

  Future<bool> _doCreateSupplier(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await widget.ref.read(supplierRepositoryProvider).create(body);
      },
      success: '供应商已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadSuppliers(_supplierPageNum);
    return true;
  }

  void _showSupplierEdit(SupplierDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑供应商', // TODO(l10n): 补 arb
      fields: _supplierFields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'description': d.description ?? '',
        'place': d.place ?? '',
        'empId': d.empId ?? '',
        'legalPerson': d.legalPerson ?? '',
        'linkman': d.linkman ?? '',
        'mobile': d.mobile ?? '',
        'phone': d.phone ?? '',
        'phone2': d.phone2 ?? '',
        'fax': d.fax ?? '',
        'postcode': d.postcode ?? '',
        'address': d.address ?? '',
        'email': d.email ?? '',
        'website': d.website ?? '',
        'shipVia': d.shipVia ?? '',
        'shipAddress': d.shipAddress ?? '',
        'bank': d.bank ?? '',
        'bankAccount': d.bankAccount ?? '',
        'taxId': d.taxId ?? '',
        'initTotal': d.initTotal?.toString() ?? '',
        'tday': d.tday?.toString() ?? '',
        'status': d.status ?? '',
        'remark': d.remark ?? '',
      },
      fixedValues: {'categoryId': d.categoryId ?? widget.nodeId},
      onSubmit: (body) => _doUpdateSupplier(d.id, body),
    );
  }

  Future<bool> _doUpdateSupplier(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await widget.ref.read(supplierRepositoryProvider).update(id, body);
      },
      success: '供应商已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadSuppliers(_supplierPageNum);
    return true;
  }

  Future<void> _deleteSupplier(SupplierDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除供应商'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该供应商')}」吗？', // TODO(l10n): 补 arb
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
        await widget.ref.read(supplierRepositoryProvider).delete(d.id);
      },
      success: '供应商已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadSuppliers(_supplierPageNum);
    // 删空当前页时回退上一页，避免列表显示空白
    if (mounted &&
        _supplierPage != null &&
        _supplierPage!.items.isEmpty &&
        _supplierPage!.page > 1) {
      await _loadSuppliers(_supplierPage!.page - 1);
    }
  }

  /// 点供应商行：拉详情弹框展示核心字段。
  ///
  /// 用独立的 [_detailLoading] 防并发——不能用 [_supplierLoading]（那是分页列表
  /// 加载状态，列表加载完即恒为 false，起不到防连点作用）。否则并发触发
  /// showDialog 会让 Navigator 上多个对话框路由交错 push/pop，触发 element
  /// 生命周期断言（见 MEMORY: go_router 嵌套 navigator 坑）。
  Future<void> _showSupplierDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    // 预取 root navigator：showDialog 默认 useRootNavigator:true 把对话框 push 到
    // root navigator，pop 也必须用同一个 root。
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    SupplierDetail? d;
    try {
      d = await widget.ref.read(supplierRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) {
        context.appError('加载供应商详情失败'); // TODO(l10n): 补 arb
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
          : (detail.code ?? '供应商详情'),
      rows: _supplierDetailRows(detail),
      canEdit: _canEditMaster,
      onEdit: () => _showSupplierEdit(detail),
      onDelete: () => _deleteSupplier(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _supplierDetailRows(SupplierDetail d) => [
    MasterDetailRow('编号', d.code), // TODO(l10n): 补 arb
    MasterDetailRow('名称', d.name), // TODO(l10n): 补 arb
    MasterDetailRow('描述/全称', d.description), // TODO(l10n): 补 arb
    MasterDetailRow('分类', d.categoryName), // TODO(l10n): 补 arb
    MasterDetailRow('地区', d.place), // TODO(l10n): 补 arb
    MasterDetailRow('业务员', d.empId), // TODO(l10n): 补 arb
    MasterDetailRow('法人', d.legalPerson), // TODO(l10n): 补 arb
    MasterDetailRow('联系人', d.linkman), // TODO(l10n): 补 arb
    MasterDetailRow('手机', d.mobile), // TODO(l10n): 补 arb
    MasterDetailRow('电话', d.phone), // TODO(l10n): 补 arb
    MasterDetailRow('电话2', d.phone2), // TODO(l10n): 补 arb
    MasterDetailRow('传真', d.fax), // TODO(l10n): 补 arb
    MasterDetailRow('邮编', d.postcode), // TODO(l10n): 补 arb
    MasterDetailRow('地址', d.address), // TODO(l10n): 补 arb
    MasterDetailRow('收货地址', d.shipAddress), // TODO(l10n): 补 arb
    MasterDetailRow('运输方式', d.shipVia), // TODO(l10n): 补 arb
    MasterDetailRow('开户行', d.bank), // TODO(l10n): 补 arb
    MasterDetailRow('银行账号', d.bankAccount), // TODO(l10n): 补 arb
    MasterDetailRow('税号', d.taxId), // TODO(l10n): 补 arb
    MasterDetailRow(
      '期初应付',
      d.initTotal?.toStringAsFixed(2),
    ), // TODO(l10n): 补 arb
    MasterDetailRow('结算天数', d.tday?.toString()), // TODO(l10n): 补 arb
    MasterDetailRow('邮箱', d.email), // TODO(l10n): 补 arb
    MasterDetailRow('网址', d.website), // TODO(l10n): 补 arb
    MasterDetailRow('状态', d.status), // TODO(l10n): 补 arb
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
    final total = _supplierPage?.total ?? 0;
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
              icon: Icons.local_shipping_outlined,
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
          // 固定：供应商标题 + 添加按钮
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Row(
              children: [
                Icon(
                  Icons.local_shipping_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '供应商 ($total)', // TODO(l10n): 补 arb
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: UtenSearchBar(
                    hint: '搜索供应商（简称/全称/联系人/法人/地区/手机）', // TODO(l10n): 补 arb
                    initialValue: _keyword,
                    onChanged: _onKeywordChanged,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                // 预览打印 / 导出：已移入表格工具条（表头设置旁，深绿大按钮）。
                if (_canEditMaster) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.add_rounded,
                    onPressed: _showSupplierCreate,
                    child: const Text('添加供应商'), // TODO(l10n): 补 arb
                  ),
                ],
              ],
            ),
          ),
          // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）
          Expanded(
            child: MasterDataTableView<SupplierListItem>(
              columns: _supplierColumns,
              items: _supplierPage?.items ?? const [],
              toolbarActions: [
                UtenPrintPreviewButton(
                  title: '供应商资料',
                  subtitle: '最多前 2000 行',
                  loader: _printLoader,
                  exportEndpoint: '/master/suppliers/export',
                  exportPermission: Perm.supplierExport,
                  exportReport: '',
                  exportQuery: _exportQuery,
                  exportFilename: '供应商资料',
                  type: UtenButtonType.primary,
                  size: UtenButtonSize.large,
                ),
                UtenExportButton(
                  endpoint: '/master/suppliers/export',
                  requiredPermission: Perm.supplierExport,
                  report: '',
                  queryParams: _exportQuery,
                  filename: '供应商资料',
                  label: '导出供应商',
                  type: UtenButtonType.primary,
                  size: UtenButtonSize.large,
                ),
              ],
              facets: _facets?.fields ?? const {},
              nullCounts: _facets?.nullCounts ?? const {},
              filters: _filters,
              onFilterChanged: _onFilterChanged,
              onRowTap: (s) => _showSupplierDetail(s.id),
              sortColumn: _sortKey,
              sortAscending: _sortAsc,
              onSortChange: _onSortChange,
              isLoading: _supplierLoading && _supplierPage == null,
              loadingMore: _supplierLoading && _supplierPage != null,
              error: _supplierError,
              onRetry: () => _loadSuppliers(_supplierPageNum),
              emptyMessage: '该分类暂无供应商', // TODO(l10n): 补 arb
              currentPage: _supplierPage?.page ?? 1,
              totalPages: _supplierPage?.totalPages ?? 1,
              onPageChange: (p) => _loadSuppliers(p),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 供应商列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 供应商表格 21 列（严格按用户指定顺序与列宽）：
  /// [MasterColumnDef.key]=筛选键（与后端 query 参数名一一对齐，autofilter）；
  /// [MasterColumnDef.value]=单元格取值。
  ///
  /// 主结账方式（key=priceStyle）/损耗率（key=lossRate）无对应物理列：
  /// 不可筛（不进 facets/nullCounts → 下拉仅显示"所有"），单元格恒显示"—"。
  static final _supplierColumns = <MasterColumnDef<SupplierListItem>>[
    MasterColumnDef(
      key: 'name',
      label: '供应商简称',
      width: 160,
      value: (s) => s.name,
    ),
    MasterColumnDef(
      key: 'description',
      label: '全称',
      width: 200,
      value: (s) => s.description,
    ),
    MasterColumnDef(
      key: 'priceStyle',
      label: '主结账方式',
      width: 110,
      value: (_) => '—',
    ), // 无对应物理列，恒显示"—"
    MasterColumnDef(
      key: 'tday',
      label: '信用天数',
      width: 80,
      type: 'number',
      sortable: true,
      value: (s) => s.tday?.toString(),
    ),
    MasterColumnDef(
      key: 'lossRate',
      label: '损耗率(%)',
      width: 90,
      value: (_) => '—',
    ), // 无对应物理列，恒显示"—"
    MasterColumnDef(
      key: 'place',
      label: '所属地区',
      width: 110,
      value: (s) => s.place,
    ),
    MasterColumnDef(
      key: 'empId',
      label: '业务员',
      width: 90,
      value: (s) => s.empId,
    ),
    MasterColumnDef(
      key: 'legalPerson',
      label: '法人代表',
      width: 100,
      value: (s) => s.legalPerson,
    ),
    MasterColumnDef(
      key: 'linkman',
      label: '联系人',
      width: 90,
      value: (s) => s.linkman,
    ),
    MasterColumnDef(
      key: 'mobile',
      label: '手机',
      width: 120,
      value: (s) => s.mobile,
    ),
    MasterColumnDef(
      key: 'phone',
      label: '联系电话',
      width: 120,
      value: (s) => s.phone,
    ),
    MasterColumnDef(
      key: 'phone2',
      label: '备用电话',
      width: 120,
      value: (s) => s.phone2,
    ),
    MasterColumnDef(key: 'fax', label: '传真', width: 110, value: (s) => s.fax),
    MasterColumnDef(
      key: 'postcode',
      label: '邮编',
      width: 80,
      value: (s) => s.postcode,
    ),
    MasterColumnDef(
      key: 'address',
      label: '地址',
      width: 220,
      value: (s) => s.address,
    ),
    MasterColumnDef(
      key: 'bank',
      label: '开户银行',
      width: 160,
      value: (s) => s.bank,
    ),
    MasterColumnDef(
      key: 'bankAccount',
      label: '银行账号',
      width: 160,
      value: (s) => s.bankAccount,
    ),
    MasterColumnDef(
      key: 'taxId',
      label: '纳税号',
      width: 140,
      value: (s) => s.taxId,
    ),
    MasterColumnDef(
      key: 'website',
      label: '网址',
      width: 160,
      value: (s) => s.website,
    ),
    MasterColumnDef(
      key: 'shipVia',
      label: '运输方式',
      width: 100,
      value: (s) => s.shipVia,
    ),
    MasterColumnDef(
      key: 'shipAddress',
      label: '送货地址',
      width: 220,
      value: (s) => s.shipAddress,
    ),
  ];
}
