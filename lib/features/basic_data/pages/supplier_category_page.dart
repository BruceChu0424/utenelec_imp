// 供应商资料分类树管理页（基础资料）
//
// 与 mould/client/product_category_page.dart 同构：
// - 详情面板调 supplierCategoryRepository.detail + supplierRepository 分类下分页；
// - 编辑类按钮按 supplier_category:edit 权限显隐；查看全员可见（路由不设守卫）；
// - 复用 UtenCategoryTreeView / CategoryEditDialog / ProductCategoryNode。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/09-供应商资料-新库与迁移.md。
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
import '../models/product_category_node.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_category_repository.dart';
import '../repositories/supplier_repository.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/master_edit_dialog.dart';
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
    try {
      await ref.read(supplierCategoryRepositoryProvider).create(
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
      await ref.read(supplierCategoryRepositoryProvider).update(
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
          '确定删除「${node.name}」吗？若存在子分类或供应商引用，删除可能失败。', // TODO(l10n): 补 arb
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
      await ref.read(supplierCategoryRepositoryProvider).delete(node.id);
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
        icon: Icons.local_shipping_outlined,
        message: '暂无供应商分类', // TODO(l10n): 补 arb
        description: canEdit ? '点击右上角「+」新建第一个分类' : null, // TODO(l10n): 补 arb
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

/// 供应商分类详情面板：只调 detail（分类信息）+ 该分类下的供应商分页。
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

  PagedResult<SupplierListItem>? _supplierPage;
  int _supplierPageNum = 1;
  bool _supplierLoading = false;
  String? _supplierError;

  /// 详情弹窗加载中（防并发）。与 [_supplierLoading]（列表分页加载）是两回事，不可混用。
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
        _supplierPage = null;
        _supplierPageNum = 1;
        _supplierError = null;
      });
      // 始终加载——后端 list 子树汇总（供应商当前扁平，子树=自身；将来加嵌套也兼容）。
      await _loadSuppliers(1);
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
    if (_supplierLoading) return; // 防连点
    setState(() {
      _supplierLoading = true;
      _supplierError = null;
      _supplierPageNum = page;
    });
    try {
      final result = await widget.ref
          .read(supplierRepositoryProvider)
          .list(widget.nodeId, page: page);
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

  // 供应商主档可编辑字段（与后端 SupplierSaveRequest 对齐）。
  static const _supplierFields = [
    MasterFieldDef(key: 'name', label: '名称', required: true),
    MasterFieldDef(key: 'code', label: '编号'),
    MasterFieldDef(key: 'description', label: '描述/全称'),
    MasterFieldDef(key: 'place', label: '地区'),
    MasterFieldDef(key: 'empId', label: '业务员'),
    MasterFieldDef(key: 'legalPerson', label: '法人'),
    MasterFieldDef(key: 'linkman', label: '联系人'),
    MasterFieldDef(key: 'mobile', label: '手机'),
    MasterFieldDef(key: 'phone', label: '电话'),
    MasterFieldDef(key: 'phone2', label: '电话2'),
    MasterFieldDef(key: 'fax', label: '传真'),
    MasterFieldDef(key: 'postcode', label: '邮编'),
    MasterFieldDef(key: 'address', label: '地址'),
    MasterFieldDef(key: 'email', label: '邮箱'),
    MasterFieldDef(key: 'website', label: '网址'),
    MasterFieldDef(key: 'shipVia', label: '运输方式'),
    MasterFieldDef(key: 'shipAddress', label: '收货地址'),
    MasterFieldDef(key: 'bank', label: '开户行'),
    MasterFieldDef(key: 'bankAccount', label: '银行账号'),
    MasterFieldDef(key: 'taxId', label: '税号'),
    MasterFieldDef(key: 'initTotal', label: '期初应付', type: MasterFieldType.money),
    MasterFieldDef(key: 'tday', label: '结算天数', type: MasterFieldType.integer),
    MasterFieldDef(key: 'status', label: '状态'),
    MasterFieldDef(key: 'remark', label: '备注'),
  ];

  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.supplierEdit);

  // ---- 供应商 新建/编辑/删除 ----------------------------------------------

  void _showSupplierCreate() {
    showDialog<void>(
      context: context,
      builder: (_) => MasterEditDialog(
        title: '新增供应商', // TODO(l10n): 补 arb
        fields: _supplierFields,
        fixedValues: {'categoryId': widget.nodeId},
        onSubmit: _doCreateSupplier,
      ),
    );
  }

  Future<bool> _doCreateSupplier(Map<String, dynamic> body) async {
    try {
      await widget.ref.read(supplierRepositoryProvider).create(body);
      if (!mounted) return false;
      context.appSuccess('供应商已创建'); // TODO(l10n): 补 arb
      await _loadSuppliers(_supplierPageNum);
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

  void _showSupplierEdit(SupplierDetail d) {
    showDialog<void>(
      context: context,
      builder: (_) => MasterEditDialog(
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
      ),
    );
  }

  Future<bool> _doUpdateSupplier(String id, Map<String, dynamic> body) async {
    try {
      await widget.ref.read(supplierRepositoryProvider).update(id, body);
      if (!mounted) return false;
      context.appSuccess('供应商已更新'); // TODO(l10n): 补 arb
      await _loadSuppliers(_supplierPageNum);
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

  Future<void> _deleteSupplier(SupplierDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除供应商'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该供应商')}」吗？', // TODO(l10n): 补 arb
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
      await widget.ref.read(supplierRepositoryProvider).delete(d.id);
      if (!mounted) return;
      context.appSuccess('供应商已删除'); // TODO(l10n): 补 arb
      await _loadSuppliers(_supplierPageNum);
      // 删空当前页时回退上一页，避免列表显示空白
      if (mounted &&
          _supplierPage != null &&
          _supplierPage!.items.isEmpty &&
          _supplierPage!.page > 1) {
        await _loadSuppliers(_supplierPage!.page - 1);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  /// 点供应商行：拉详情弹框。用独立的 [_detailLoading] 防并发（见 mould 页同款注释）。
  Future<void> _showSupplierDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    // 预取 root navigator：showDialog 默认 useRootNavigator:true 把对话框 push 到
    // root navigator，pop 也必须用同一个 root（见 MEMORY: go_router 嵌套 navigator 坑）。
    // 之前漏了 rootNavigator:true，nav.pop() 误把 go_router 那层页面 pop 掉 → 白屏。
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
      nav.pop();
      return;
    }
    nav.pop(); // 关 loading
    if (d == null) {
      _detailLoading = false;
      return;
    }
    await _openSupplierDialog(d);
    if (mounted) _detailLoading = false;
  }

  Future<void> _openSupplierDialog(SupplierDetail d) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(d.name?.isNotEmpty == true ? d.name! : (d.code ?? '供应商详情')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('编号', d.code),
              _row('名称', d.name),
              _row('描述/全称', d.description),
              _row('分类', d.categoryName),
              _row('地区', d.place),
              _row('业务员', d.empId),
              _row('法人', d.legalPerson),
              _row('联系人', d.linkman),
              _row('手机', d.mobile),
              _row('电话', d.phone),
              _row('电话2', d.phone2),
              _row('传真', d.fax),
              _row('邮编', d.postcode),
              _row('地址', d.address),
              _row('收货地址', d.shipAddress),
              _row('运输方式', d.shipVia),
              _row('开户行', d.bank),
              _row('银行账号', d.bankAccount),
              _row('税号', d.taxId),
              _row('期初应付', d.initTotal?.toStringAsFixed(2)),
              _row('结算天数', d.tday?.toString()),
              _row('邮箱', d.email),
              _row('网址', d.website),
              _row('状态', d.status),
              _row('备注', d.remark),
              _row('旧编码', d.legacyId?.toString()),
            ],
          ),
        ),
        actions: [
          if (_canEditMaster)
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _showSupplierEdit(d);
              },
              child: const Text('编辑'), // TODO(l10n): 补 arb
            ),
          if (_canEditMaster)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: UtenColors.error),
              onPressed: () {
                Navigator.of(ctx).pop();
                _deleteSupplier(d);
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

  Widget _row(String label, String? value) {
    final theme = Theme.of(context);
    final hasValue = value != null && value.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
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
        if (_canEditMaster)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            child: FilledButton.icon(
              onPressed: _showSupplierCreate,
              icon: const Icon(Icons.add_business_outlined, size: 18),
              label: const Text('添加供应商'), // TODO(l10n): 补 arb
            ),
          ),
        const SizedBox(height: UtenSpacing.s20),
        _buildSupplierSection(theme),
        const SizedBox(height: UtenSpacing.s24),
      ],
    );
  }

  // ---- 供应商列表区块 -----------------------------------------------------

  Widget _buildSupplierSection(ThemeData theme) {
    final detail = _detail;
    if (detail == null) return const SizedBox.shrink();

    final total = _supplierPage?.total ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(
          title: '供应商 ($total)', // TODO(l10n): 补 arb
          icon: Icons.local_shipping_outlined,
        ),
        if (detail.childCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              '已汇总 ${detail.childCount} 个子分类下的全部供应商', // TODO(l10n): 补 arb
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: UtenSpacing.s8),
        _buildSupplierBody(theme),
        if (_supplierPage != null && _supplierPage!.totalPages > 1)
          _buildSupplierPager(theme),
      ],
    );
  }

  Widget _buildSupplierBody(ThemeData theme) {
    if (_supplierLoading && _supplierPage == null) {
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
    if (_supplierError != null) {
      return UtenEmpty.error(
        message: _supplierError,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: () => _loadSuppliers(_supplierPageNum),
      );
    }
    final items = _supplierPage?.items ?? const <SupplierListItem>[];
    if (items.isEmpty) {
      return const UtenEmpty(
        icon: Icons.local_shipping_outlined,
        message: '该分类暂无供应商', // TODO(l10n): 补 arb
      );
    }
    return Column(
      children: [
        for (final m in items)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: UtenListItem(
              leadingIcon: Icons.store_outlined,
              title: m.name?.isNotEmpty == true ? m.name! : (m.code ?? '(未命名)'),
              subtitle: _supplierSubtitle(m),
              trailing: m.status == null || m.status!.isEmpty
                  ? null
                  : _statusChip(theme, m.status!),
              showChevron: true,
              onTap: () => _showSupplierDetail(m.id),
            ),
          ),
        if (_supplierLoading)
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

  String _supplierSubtitle(SupplierListItem m) {
    final parts = <String>[
      if (m.code != null && m.code!.isNotEmpty) m.code!,
      if (m.place != null && m.place!.isNotEmpty) m.place!,
      if (m.linkman != null && m.linkman!.isNotEmpty) m.linkman!,
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 状态小徽标：使用=绿、禁用=灰。
  Widget _statusChip(ThemeData theme, String status) {
    final inUse = status == '使用';
    final color = inUse ? UtenColors.success : theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        status,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }

  Widget _buildSupplierPager(ThemeData theme) {
    final page = _supplierPage!;
    final canPrev = page.page > 1 && !_supplierLoading;
    final canNext = page.page < page.totalPages && !_supplierLoading;
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: canPrev ? () => _loadSuppliers(page.page - 1) : null,
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
            onPressed: canNext ? () => _loadSuppliers(page.page + 1) : null,
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
