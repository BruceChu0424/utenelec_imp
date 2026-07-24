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
import '../../../components/cards/uten_card.dart';
import '../../../components/cards/uten_list_item.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
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
import '../repositories/goods_repository.dart';
import '../repositories/product_category_repository.dart';
import '../widgets/category_edit_dialog.dart';
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
        description: canEdit ? '点击右上角「+」新建第一个分类' : null, // TODO(l10n): 补 arb
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
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: '新增顶级分类', // TODO(l10n): 补 arb
              onPressed: () => _showCreateDialog(),
            ),
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

  // 该分类下的货品分页（仅叶子分类加载；分组节点提示用户选具体子分类）。
  PagedResult<GoodsListItem>? _goodsPage;
  int _goodsPageNum = 1;
  bool _goodsLoading = false;
  String? _goodsError;

  /// 详情弹窗加载中（防并发）。
  /// 注意：与 [_goodsLoading]（货品分页列表的加载状态）是两回事，不可混用——
  /// 列表加载完后 [_goodsLoading] 恒为 false，无法防止详情弹窗被并发触发。
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
          .read(productCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置货品分页；叶子分类才拉货品。
        _goodsPage = null;
        _goodsPageNum = 1;
        _goodsError = null;
      });
      if (d.childCount == 0) {
        await _loadGoods(1);
      }
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
      final result = await widget.ref
          .read(goodsRepositoryProvider)
          .list(widget.nodeId, page: page);
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

  // 货品主档可编辑字段（与后端 GoodsSaveRequest 对齐；老库 78 字段里只维护核心）。
  static const _goodsFields = [
    MasterFieldDef(key: 'name', label: '名称', required: true),
    MasterFieldDef(key: 'code', label: '编号'),
    MasterFieldDef(key: 'shortName', label: '简称'),
    MasterFieldDef(key: 'model', label: '型号'),
    MasterFieldDef(key: 'spec', label: '规格'),
    MasterFieldDef(key: 'price', label: '价格', type: MasterFieldType.money),
    MasterFieldDef(key: 'material', label: '材质'),
    MasterFieldDef(key: 'thickness', label: '厚度', type: MasterFieldType.money),
    MasterFieldDef(key: 'mWeight', label: '单重', type: MasterFieldType.money),
    MasterFieldDef(key: 'pack', label: '包装'),
    MasterFieldDef(key: 'pieces', label: '件数', type: MasterFieldType.integer),
    MasterFieldDef(key: 'status', label: '状态'),
  ];

  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.goodsEdit);

  // ---- 货品 新建/编辑/删除 ------------------------------------------------

  void _showGoodsCreate() {
    showDialog<void>(
      context: context,
      builder: (_) => MasterEditDialog(
        title: '新增货品', // TODO(l10n): 补 arb
        fields: _goodsFields,
        fixedValues: {'categoryId': widget.nodeId},
        onSubmit: _doCreateGoods,
      ),
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
    showDialog<void>(
      context: context,
      builder: (_) => MasterEditDialog(
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
        },
        fixedValues: {'categoryId': d.categoryId ?? widget.nodeId},
        onSubmit: (body) => _doUpdateGoods(d.id, body),
      ),
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
    // 成功：开详情对话框，关闭后再复位 flag（对话框期间继续禁止并发）。
    await _openGoodsDialog(d);
    if (mounted) _detailLoading = false;
  }

  Future<void> _openGoodsDialog(GoodsDetail d) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(d.name?.isNotEmpty == true ? d.name! : (d.code ?? '货品详情')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _goodsRow('编码', d.code),
              _goodsRow('型号', d.model),
              _goodsRow('规格', d.spec),
              _goodsRow('简称', d.shortName),
              _goodsRow('价格', d.price?.toStringAsFixed(2)),
              _goodsRow('材质', d.material),
              _goodsRow('厚度', d.thickness?.toStringAsFixed(2)),
              _goodsRow('包装', d.pack),
              _goodsRow('单重', d.mWeight?.toStringAsFixed(2)),
              _goodsRow('件数', d.pieces?.toString()),
              _goodsRow('分类', d.categoryName),
              _goodsRow('状态', d.status),
              _goodsRow('旧编码', d.legacyId?.toString()),
            ],
          ),
        ),
        actions: [
          if (_canEditMaster)
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _showGoodsEdit(d);
              },
              child: const Text('编辑'), // TODO(l10n): 补 arb
            ),
          if (_canEditMaster)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: UtenColors.error),
              onPressed: () {
                Navigator.of(ctx).pop();
                _deleteGoods(d);
              },
              child: const Text('删除'), // TODO(l10n): 补 arb
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
  }

  Widget _goodsRow(String label, String? value) {
    final theme = Theme.of(context);
    final hasValue = value != null && value.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              hasValue ? value : '—',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

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
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: hPad,
        vertical: UtenSpacing.s16,
      ),
      children: [
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                d.name,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '编码 ${d.code} · 层级 L${d.level}', // TODO(l10n): 补 arb
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s8,
                children: [
                  _stat(theme, '子分类数', '${d.childCount}'), // TODO(l10n): 补 arb
                  if (d.parentName != null)
                    _stat(theme, '父级', d.parentName!), // TODO(l10n): 补 arb
                  if (d.legacyId != null)
                    _stat(theme, '旧编码', '${d.legacyId}'), // TODO(l10n): 补 arb
                ],
              ),
              if (d.path.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  '路径：${d.path}', // TODO(l10n): 补 arb
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s16),
        if (widget.canEdit)
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            children: [
              FilledButton.tonalIcon(
                onPressed: widget.onAddChild,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新增子分类'), // TODO(l10n): 补 arb
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  if (_detail != null) widget.onEdit(_detail!);
                },
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('编辑'), // TODO(l10n): 补 arb
              ),
              FilledButton.tonalIcon(
                onPressed: widget.onDelete,
                style: FilledButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'), // TODO(l10n): 补 arb
              ),
            ],
          ),
        if (_canEditMaster && _detail != null && _detail!.childCount == 0)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            child: FilledButton.icon(
              onPressed: _showGoodsCreate,
              icon: const Icon(Icons.inventory_2_outlined, size: 18),
              label: const Text('添加货品'), // TODO(l10n): 补 arb
            ),
          ),
        const SizedBox(height: UtenSpacing.s20),
        _buildGoodsSection(theme),
        const SizedBox(height: UtenSpacing.s24),
      ],
    );
  }

  // ---- 货品列表区块 -------------------------------------------------------

  /// 分类信息卡下方的货品分页列表。
  /// 分组节点（childCount>0）提示用户选具体子分类；叶子分类展示其货品 + 上一页/下一页。
  Widget _buildGoodsSection(ThemeData theme) {
    final detail = _detail;
    if (detail == null) return const SizedBox.shrink();

    // 分组节点：老库分类树的中间层通常不直接挂货品，提示选具体子分类。
    if (detail.childCount > 0) {
      return const UtenEmpty(
        icon: Icons.inventory_2_outlined,
        message: '该分类下含子分类，请在左侧选择具体子分类查看货品', // TODO(l10n): 补 arb
      );
    }

    final total = _goodsPage?.total ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(
          title: '货品 ($total)', // TODO(l10n): 补 arb
          icon: Icons.inventory_2_outlined,
        ),
        const SizedBox(height: UtenSpacing.s8),
        _buildGoodsBody(theme),
        if (_goodsPage != null && _goodsPage!.totalPages > 1)
          _buildGoodsPager(theme),
      ],
    );
  }

  Widget _buildGoodsBody(ThemeData theme) {
    if (_goodsLoading && _goodsPage == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (_goodsError != null) {
      return UtenEmpty.error(
        message: _goodsError,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: () => _loadGoods(_goodsPageNum),
      );
    }
    final items = _goodsPage?.items ?? const <GoodsListItem>[];
    if (items.isEmpty) {
      return const UtenEmpty(
        icon: Icons.inventory_2_outlined,
        message: '该分类暂无货品', // TODO(l10n): 补 arb
      );
    }
    return Column(
      children: [
        for (final g in items)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: UtenListItem(
              leadingIcon: Icons.inventory_2_outlined,
              title: g.name?.isNotEmpty == true ? g.name! : (g.code ?? '(未命名)'),
              subtitle: _goodsSubtitle(g),
              trailing: g.price == null
                  ? null
                  : Text(
                      g.price!.toStringAsFixed(2),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
              showChevron: true,
              onTap: () => _showGoodsDetail(g.id),
            ),
          ),
        if (_goodsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      ],
    );
  }

  String _goodsSubtitle(GoodsListItem g) {
    final parts = <String>[
      if (g.code != null && g.code!.isNotEmpty) g.code!,
      if (g.spec != null && g.spec!.isNotEmpty) g.spec!,
      if (g.model != null && g.model!.isNotEmpty) g.model!,
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 简单分页：上一页 / 下一页（页码从 1 起，与后端 Pageables 约定一致）。
  Widget _buildGoodsPager(ThemeData theme) {
    final page = _goodsPage!;
    final canPrev = page.page > 1 && !_goodsLoading;
    final canNext = page.page < page.totalPages && !_goodsLoading;
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: canPrev ? () => _loadGoods(page.page - 1) : null,
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            label: const Text('上一页'), // TODO(l10n): 补 arb
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Text(
              '${page.page} / ${page.totalPages}', // TODO(l10n): 补 arb
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: canNext ? () => _loadGoods(page.page + 1) : null,
            icon: const Text('下一页'), // TODO(l10n): 补 arb
            label: const Icon(Icons.chevron_right_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _stat(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Text(
        '$label：$value',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
