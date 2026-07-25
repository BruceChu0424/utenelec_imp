// 货品资料分类树管理页（基础资料）
//
// 拷贝自部门管理页（department_page.dart）改造：
// - 详情面板只调 productCategoryRepository.detail（不拉员工）；
// - 编辑类按钮（新增/编辑/删除）按 material_category:edit 权限显隐；
//   查看全员可见（路由不设守卫）。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/03-页面/ 总览（基础资料）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';
import '../models/product_category_node.dart';
import '../repositories/color_repository.dart';
import '../repositories/goods_repository.dart';
import '../repositories/product_category_repository.dart';
import '../repositories/unit_repository.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/uten_category_tree_view.dart';

class ProductCategoryPage extends ConsumerStatefulWidget {
  const ProductCategoryPage({super.key});

  @override
  ConsumerState<ProductCategoryPage> createState() =>
      _ProductCategoryPageState();
}

class _ProductCategoryPageState extends ConsumerState<ProductCategoryPage> {
  List<ProductCategoryNode>? _tree;
  String? _selectedId;
  bool _loading = true;
  String? _error;

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
      final tree = await ref.read(productCategoryRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _selectedId = _selectedId ?? (tree.isNotEmpty ? tree.first.id : null);
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
    return perms.contains(Perm.materialCategoryEdit);
  }

  /// 新建分类时的常用名称建议（降低起名门槛；货品类常用维度）。
  static const _categorySuggestions = [
    '原材料',
    '半成品',
    '成品',
    '辅料',
    '包装材料',
    '五金配件',
  ];

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
    try {
      await ref.read(productCategoryRepositoryProvider).create(
            ProductCategorySaveInput(
              code: r.code!,
              name: r.name,
              parentId: r.parentId,
            ),
          );
      if (!mounted) return false;
      context.appSuccess('分类已创建'); // TODO(l10n): 补 arb
      await _load();
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('创建失败，请稍后重试'); // TODO(l10n): 补 arb
      return false;
    }
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
    try {
      await ref.read(productCategoryRepositoryProvider).update(
            id,
            ProductCategoryUpdateInput(
              name: r.name,
              parentId: r.parentId,
            ),
          );
      if (!mounted) return false;
      context.appSuccess('分类已更新'); // TODO(l10n): 补 arb
      await _load();
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('更新失败，请稍后重试'); // TODO(l10n): 补 arb
      return false;
    }
  }

  Future<void> _delete(ProductCategoryNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${node.name}」吗？若存在子分类或货品引用，删除可能失败。', // TODO(l10n): 补 arb
        ),
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
    try {
      await ref.read(productCategoryRepositoryProvider).delete(node.id);
      if (!mounted) return;
      context.appSuccess('分类已删除'); // TODO(l10n): 补 arb
      if (_selectedId == node.id) _selectedId = null;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  // ---- 树渲染 -------------------------------------------------------------

  Widget _buildTree({
    required void Function(String id) onSelect,
  }) {
    final theme = Theme.of(context);
    final canEdit = _canEdit;
    return UtenCategoryTreeView(
      nodes: _tree ?? const <ProductCategoryNode>[],
      nodeEnabledPredicate: (_) => true,
      selectedIds: {?_selectedId},
      expandOnRowTap: true,
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
        icon: Icons.category_outlined,
        message: '暂无货品分类', // TODO(l10n): 补 arb
        description: canEdit ? '还没有任何分类，新建第一个吧' : null, // TODO(l10n): 补 arb
        actionLabel: canEdit ? '新建分类' : null, // TODO(l10n): 补 arb
        onAction: canEdit ? () => _showCreateDialog() : null,
      );
    } else if (bp == UtenBreakpoint.compact) {
      body = selected == null
          ? const UtenEmpty(
              icon: Icons.category_outlined,
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
        title: '货品资料', // TODO(l10n): 补 arb
        // 显式返回到基础资料 hub：hub 与本页都用 context.go 进入（不压栈），
        // 默认 UtenBackButton 会因 canPop()=false 兜底回工作台，故指定去向。
        leading: UtenBackButton(
          onPressed: () => context.go(RouteName.basicinfo),
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

/// 分类详情面板：只调 detail（不拉员工/岗位）。
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

  // 该分类（子树）下的货品分页；父分类也加载（子树汇总）。
  PagedResult<GoodsListItem>? _goodsPage;
  int _goodsPageNum = 1;
  bool _goodsLoading = false;
  String? _goodsError;

  // 字段筛选 + 搜索 + facet（筛选栏用）。切换分类时重置。
  Map<String, String?> _filters = {};
  String _keyword = '';
  GoodsFacets? _facets;

  // 颜色/单位字典（货品编辑表单下拉选项）。全局，不随分类切换。
  List<MasterSelectOption> _colorOptions = const [];
  List<MasterSelectOption> _unitOptions = const [];

  /// 详情弹窗加载中（防并发）。
  /// 注意：与 [_goodsLoading]（货品分页列表的加载状态）是两回事，不可混用——
  /// 列表加载完后 [_goodsLoading] 恒为 false，无法防止详情弹窗被并发触发。
  bool _detailLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadDicts();
  }

  @override
  void didUpdateWidget(_DetailPane old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) _load();
  }

  /// 加载颜色/单位字典（货品编辑表单下拉选项；全局，失败静默降级为空下拉）。
  Future<void> _loadDicts() async {
    try {
      final colors = await widget.ref.read(colorRepositoryProvider).dict();
      final units = await widget.ref.read(unitRepositoryProvider).dict();
      if (!mounted) return;
      setState(() {
        _colorOptions = [
          for (final c in colors)
            if (c.legacyId != null)
              MasterSelectOption(
                value: c.legacyId.toString(),
                label:
                    (c.name != null && c.name!.isNotEmpty) ? c.name! : '#${c.legacyId}',
              ),
        ];
        _unitOptions = [
          for (final u in units)
            if (u.legacyId != null)
              MasterSelectOption(
                value: u.legacyId.toString(),
                label:
                    (u.name != null && u.name!.isNotEmpty) ? u.name! : '#${u.legacyId}',
              ),
        ];
      });
    } on ApiException catch (e) {
      debugPrint('color/unit dict load failed: ${e.message}');
    } catch (_) {
      debugPrint('color/unit dict load failed');
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.ref
          .read(productCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置货品分页 + 筛选状态 + facet。
        _goodsPage = null;
        _goodsPageNum = 1;
        _goodsError = null;
        _filters = {};
        _keyword = '';
        _facets = null;
      });
      // 父分类也加载（后端按子树汇总）；并行拉货品列表与字段 facet。
      await Future.wait([_loadGoods(1), _loadFacets()]);
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

  // ---- 货品分页 ----------------------------------------------------------

  Future<void> _loadGoods(int page) async {
    if (_goodsLoading) return; // 防连点：分页请求进行中时忽略
    setState(() {
      _goodsLoading = true;
      _goodsError = null;
      _goodsPageNum = page;
    });
    try {
      final result = await widget.ref.read(goodsRepositoryProvider).list(
            widget.nodeId,
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
          );
      if (!mounted) return;
      setState(() {
        _goodsPage = result;
        _goodsLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _goodsError = e.message;
        _goodsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _goodsError = '加载货品列表失败'; // TODO(l10n): 补 arb
        _goodsLoading = false;
      });
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    try {
      final f =
          await widget.ref.read(goodsRepositoryProvider).facets(widget.nodeId);
      if (!mounted) return;
      setState(() => _facets = f);
    } on ApiException catch (e) {
      // facet 拉取失败：列表仍可用，仅下拉为空；不强提示打扰用户。
      debugPrint('goods facets load failed: ${e.message}');
    } catch (_) {
      debugPrint('goods facets load failed');
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
    _loadGoods(1); // 任一筛选变化回到第 1 页
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadGoods(1);
  }

  // 货品主档可编辑字段（与后端 GoodsSaveRequest 对齐；老库 78 字段里只维护核心）。
  /// 货品可编辑字段（颜色/单位为下拉，选项来自字典；与后端 GoodsSaveRequest 对齐）。
  List<MasterFieldDef> get _goodsFields => [
    const MasterFieldDef(
        key: 'name', label: '名称', required: true, group: '基础'),
    const MasterFieldDef(key: 'code', label: '编号', group: '基础'),
    const MasterFieldDef(key: 'shortName', label: '简称', group: '基础'),
    const MasterFieldDef(key: 'status', label: '状态', group: '基础'),
    const MasterFieldDef(key: 'model', label: '型号', group: '规格'),
    const MasterFieldDef(key: 'spec', label: '规格', group: '规格'),
    const MasterFieldDef(key: 'material', label: '材质', group: '规格'),
    const MasterFieldDef(
      key: 'thickness',
      label: '厚度',
      type: MasterFieldType.money,
      group: '规格',
    ),
    const MasterFieldDef(
      key: 'mWeight',
      label: '单重',
      type: MasterFieldType.money,
      group: '规格',
    ),
    MasterFieldDef(
      key: 'colorLegacyId',
      label: '主颜色',
      type: MasterFieldType.select,
      options: _colorOptions,
      selectInteger: true,
      group: '规格',
    ),
    const MasterFieldDef(
      key: 'price', label: '价格', type: MasterFieldType.money, group: '商务'),
    const MasterFieldDef(key: 'pack', label: '包装', group: '商务'),
    MasterFieldDef(
      key: 'unitLegacyId',
      label: '单位',
      type: MasterFieldType.select,
      options: _unitOptions,
      selectInteger: true,
      group: '商务',
    ),
    const MasterFieldDef(
      key: 'pieces',
      label: '件数',
      type: MasterFieldType.integer,
      group: '商务',
    ),
  ];

  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsEdit);

  // ---- 货品 新建/编辑/删除 ------------------------------------------------

  void _showGoodsCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增货品', // TODO(l10n): 补 arb
      fields: _goodsFields,
      fixedValues: {'categoryId': widget.nodeId},
      onSubmit: _doCreateGoods,
    );
  }

  Future<bool> _doCreateGoods(Map<String, dynamic> body) async {
    try {
      await widget.ref.read(goodsRepositoryProvider).create(body);
      if (!mounted) return false;
      context.appSuccess('货品已创建'); // TODO(l10n): 补 arb
      await _loadGoods(_goodsPageNum);
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('创建失败，请稍后重试'); // TODO(l10n): 补 arb
      return false;
    }
  }

  void _showGoodsEdit(GoodsDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑货品', // TODO(l10n): 补 arb
      fields: _goodsFields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'shortName': d.shortName ?? '',
        'model': d.model ?? '',
        'spec': d.spec ?? '',
        'price': d.price?.toString() ?? '',
        'material': d.material ?? '',
        'thickness': d.thickness?.toString() ?? '',
        'mWeight': d.mWeight?.toString() ?? '',
        'pack': d.pack ?? '',
        'pieces': d.pieces?.toString() ?? '',
        'status': d.status ?? '',
        'colorLegacyId': d.colorLegacyId?.toString() ?? '',
        'unitLegacyId': d.unitLegacyId?.toString() ?? '',
      },
      fixedValues: {'categoryId': d.categoryId ?? widget.nodeId},
      onSubmit: (body) => _doUpdateGoods(d.id, body),
    );
  }

  Future<bool> _doUpdateGoods(String id, Map<String, dynamic> body) async {
    try {
      await widget.ref.read(goodsRepositoryProvider).update(id, body);
      if (!mounted) return false;
      context.appSuccess('货品已更新'); // TODO(l10n): 补 arb
      await _loadGoods(_goodsPageNum);
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('更新失败，请稍后重试'); // TODO(l10n): 补 arb
      return false;
    }
  }

  Future<void> _deleteGoods(GoodsDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除货品'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该货品')}」吗？', // TODO(l10n): 补 arb
        ),
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
    try {
      await widget.ref.read(goodsRepositoryProvider).delete(d.id);
      if (!mounted) return;
      context.appSuccess('货品已删除'); // TODO(l10n): 补 arb
      await _loadGoods(_goodsPageNum);
      // 删空当前页时回退上一页，避免列表显示空白
      if (mounted &&
          _goodsPage != null &&
          _goodsPage!.items.isEmpty &&
          _goodsPage!.page > 1) {
        await _loadGoods(_goodsPage!.page - 1);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  /// 点货品行：拉详情弹框展示核心字段。
  ///
  /// 用独立的 [_detailLoading] 防并发——不能用 [_goodsLoading]（那是分页列表
  /// 加载状态，列表加载完即恒为 false，起不到防连点作用）。否则并发触发
  /// showDialog 会让 Navigator 上多个对话框路由交错 push/pop，触发 element
  /// 生命周期断言（framework `_activateRecursively`：
  /// `_lifecycleState == _ElementLifecycle.inactive is not true`）。
  Future<void> _showGoodsDetail(String id) async {
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
    GoodsDetail? d;
    try {
      d = await widget.ref.read(goodsRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) {
        context.appError('加载货品详情失败'); // TODO(l10n): 补 arb
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
          : (detail.code ?? '货品详情'),
      rows: _goodsDetailRows(detail),
      canEdit: _canEditMaster,
      onEdit: () => _showGoodsEdit(detail),
      onDelete: () => _deleteGoods(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _goodsDetailRows(GoodsDetail d) => [
        MasterDetailRow('编码', d.code), // TODO(l10n): 补 arb
        MasterDetailRow('型号', d.model), // TODO(l10n): 补 arb
        MasterDetailRow('规格', d.spec), // TODO(l10n): 补 arb
        MasterDetailRow('简称', d.shortName), // TODO(l10n): 补 arb
        MasterDetailRow('价格', d.price?.toStringAsFixed(2)), // TODO(l10n): 补 arb
        MasterDetailRow('材质', d.material), // TODO(l10n): 补 arb
        MasterDetailRow('厚度', d.thickness?.toStringAsFixed(2)), // TODO(l10n): 补 arb
        MasterDetailRow('包装', d.pack), // TODO(l10n): 补 arb
        MasterDetailRow('单重', d.mWeight?.toStringAsFixed(2)), // TODO(l10n): 补 arb
        MasterDetailRow('件数', d.pieces?.toString()), // TODO(l10n): 补 arb
        MasterDetailRow('主颜色', d.colorName), // TODO(l10n): 补 arb
        MasterDetailRow('单位', d.unitName), // TODO(l10n): 补 arb
        MasterDetailRow('分类', d.categoryName), // TODO(l10n): 补 arb
        MasterDetailRow('状态', d.status), // TODO(l10n): 补 arb
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
    final total = _goodsPage?.total ?? 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Column(
        children: [
          // 固定：分类信息卡（含编辑按钮）
          Padding(
            padding:
                const EdgeInsets.fromLTRB(0, UtenSpacing.s16, 0, UtenSpacing.s12),
            child: MasterDetailCard(
              title: d.name,
              icon: Icons.inventory_2_outlined,
              subtitle: '编码 ${d.code} · 层级 L${d.level}', // TODO(l10n): 补 arb
              stats: [
                MasterDetailStat('子分类数', '${d.childCount}'), // TODO(l10n): 补 arb
                MasterDetailStat('父级', d.parentName), // TODO(l10n): 补 arb
                MasterDetailStat('旧编码', d.legacyId?.toString()), // TODO(l10n): 补 arb
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
          // 固定：货品标题 + 添加按钮
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '货品 ($total)', // TODO(l10n): 补 arb
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: UtenSearchBar(
                    hint: '搜索货品（名称/编号/型号/规格/系列）', // TODO(l10n): 补 arb
                    initialValue: _keyword,
                    onChanged: _onKeywordChanged,
                  ),
                ),
                if (_canEditMaster) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.add_rounded,
                    onPressed: _showGoodsCreate,
                    child: const Text('添加货品'), // TODO(l10n): 补 arb
                  ),
                ],
              ],
            ),
          ),
          // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）
          Expanded(
            child: MasterDataTableView<GoodsListItem>(
              columns: _goodsColumns,
              items: _goodsPage?.items ?? const [],
              facets: _facets?.fields ?? const {},
              nullCounts: _facets?.nullCounts ?? const {},
              filters: _filters,
              onFilterChanged: _onFilterChanged,
              onRowTap: (g) => _showGoodsDetail(g.id),
              isLoading: _goodsLoading && _goodsPage == null,
              loadingMore: _goodsLoading && _goodsPage != null,
              error: _goodsError,
              onRetry: () => _loadGoods(_goodsPageNum),
              emptyMessage: '该分类暂无货品', // TODO(l10n): 补 arb
              currentPage: _goodsPage?.page ?? 1,
              totalPages: _goodsPage?.totalPages ?? 1,
              onPageChange: (p) => _loadGoods(p),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 货品列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 货品表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  /// 颜色/单位只有老库 legacy id → 单元格显 #id；价格作为末列。
  static final _goodsColumns = <MasterColumnDef<GoodsListItem>>[
    MasterColumnDef(
        key: 'code', label: '编号', width: 120, value: (g) => g.code),
    MasterColumnDef(
        key: 'series', label: '系列', width: 90, value: (g) => g.series),
    MasterColumnDef(
        key: 'model', label: '型号', width: 120, value: (g) => g.model),
    MasterColumnDef(
        key: 'name', label: '货品名称', width: 200, value: (g) => g.name),
    MasterColumnDef(
        key: 'spec', label: '规格', width: 150, value: (g) => g.spec),
    MasterColumnDef(
        key: 'colorLegacyId',
        label: '主颜色',
        width: 90,
        value: (g) =>
            g.colorName ?? (g.colorLegacyId == null ? null : '#${g.colorLegacyId}')),
    MasterColumnDef(
        key: 'requireRemark',
        label: '备注',
        width: 180,
        value: (g) => g.requireRemark),
    MasterColumnDef(
        key: 'cNumber', label: '客户型号', width: 120, value: (g) => g.cNumber),
    MasterColumnDef(
        key: 'unitLegacyId',
        label: '单位',
        width: 70,
        value: (g) =>
            g.unitName ?? (g.unitLegacyId == null ? null : '#${g.unitLegacyId}')),
    MasterColumnDef(
        key: 'material', label: '材质', width: 120, value: (g) => g.material),
    MasterColumnDef(
        key: 'price',
        label: '价格',
        width: 100,
        value: (g) => g.price?.toStringAsFixed(2)),
  ];
}
