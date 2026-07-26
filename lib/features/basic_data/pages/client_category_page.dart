// 客户资料分类树管理页（基础资料）
//
// 与 mould_category_page.dart（模具资料）/ product_category_page.dart（货品资料）同构：
// - 详情面板调 clientCategoryRepository.detail + clientRepository 分类下分页；
// - 编辑类按钮（新增/编辑/删除）按 client_category:edit 权限显隐；查看全员可见（路由不设守卫）；
// - 复用 UtenCategoryTreeView / CategoryEditDialog / ProductCategoryNode（分类节点形状一致）。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/07-客户资料-新库与迁移.md。
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
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/client_node.dart';
import '../models/product_category_node.dart';
import '../repositories/client_category_repository.dart';
import '../repositories/client_repository.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_detail_sheet.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/uten_category_tree_view.dart';

class ClientCategoryPage extends ConsumerStatefulWidget {
  const ClientCategoryPage({super.key});

  @override
  ConsumerState<ClientCategoryPage> createState() => _ClientCategoryPageState();
}

class _ClientCategoryPageState extends ConsumerState<ClientCategoryPage> {
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
      final tree = await ref.read(clientCategoryRepositoryProvider).tree();
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
    return perms.contains(Perm.clientCategoryEdit);
  }

  /// 新建分类时的常用名称建议（降低起名门槛；客户类常用维度）。
  static const _categorySuggestions = [
    '战略合作客户',
    '重点客户',
    '普通客户',
    '潜在客户',
    '经销商',
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
      await ref.read(clientCategoryRepositoryProvider).create(
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
      await ref.read(clientCategoryRepositoryProvider).update(
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
          '确定删除「${node.name}」吗？若存在子分类或客户引用，删除可能失败。', // TODO(l10n): 补 arb
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
      await ref.read(clientCategoryRepositoryProvider).delete(node.id);
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
        icon: Icons.people_outline,
        message: '暂无客户分类', // TODO(l10n): 补 arb
        description: canEdit ? '还没有任何分类，新建第一个吧' : null, // TODO(l10n): 补 arb
        actionLabel: canEdit ? '新建分类' : null, // TODO(l10n): 补 arb
        onAction: canEdit ? () => _showCreateDialog() : null,
      );
    } else if (bp == UtenBreakpoint.compact) {
      body = selected == null
          ? const UtenEmpty(
              icon: Icons.people_outline,
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
        title: '客户资料', // TODO(l10n): 补 arb
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

/// 客户分类详情面板：只调 detail（分类信息）+ 该分类下的客户分页。
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

  // 该分类（子树）下的客户分页；父分类也加载（子树汇总）。
  PagedResult<ClientListItem>? _clientPage;
  int _clientPageNum = 1;
  bool _clientLoading = false;
  String? _clientError;

  // 字段筛选 + 搜索 + facet（筛选栏用）。切换分类时重置。
  Map<String, String?> _filters = {};
  String _keyword = '';
  ClientFacets? _facets;

  /// 详情弹窗加载中（防并发）。与 [_clientLoading]（列表分页加载）是两回事，不可混用。
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
          .read(clientCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置客户分页 + 筛选状态 + facet。
        _clientPage = null;
        _clientPageNum = 1;
        _clientError = null;
        _filters = {};
        _keyword = '';
        _facets = null;
      });
      // 父分类也加载（后端按子树汇总）；并行拉客户列表与字段 facet。
      await Future.wait([_loadClients(1), _loadFacets()]);
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

  // ---- 客户分页 ----------------------------------------------------------

  Future<void> _loadClients(int page) async {
    if (_clientLoading) return; // 防连点：分页请求进行中时忽略
    setState(() {
      _clientLoading = true;
      _clientError = null;
      _clientPageNum = page;
    });
    try {
      final result = await widget.ref.read(clientRepositoryProvider).list(
            widget.nodeId,
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
          );
      if (!mounted) return;
      setState(() {
        _clientPage = result;
        _clientLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _clientError = e.message;
        _clientLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _clientError = '加载客户列表失败'; // TODO(l10n): 补 arb
        _clientLoading = false;
      });
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    try {
      final f =
          await widget.ref.read(clientRepositoryProvider).facets(widget.nodeId);
      if (!mounted) return;
      setState(() => _facets = f);
    } on ApiException catch (e) {
      // facet 拉取失败：列表仍可用，仅下拉为空；不强提示打扰用户。
      debugPrint('client facets load failed: ${e.message}');
    } catch (_) {
      debugPrint('client facets load failed');
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
    _loadClients(1); // 任一筛选变化回到第 1 页
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadClients(1);
  }

  // 客户主档可编辑字段（与后端 ClientSaveRequest 对齐；含义不明的遗留字段不进表单）。
  static const _clientFields = [
    MasterFieldDef(key: 'name', label: '名称', required: true, group: '基础'),
    MasterFieldDef(key: 'code', label: '编号', group: '基础'),
    MasterFieldDef(key: 'fullName', label: '全称', group: '基础'),
    MasterFieldDef(key: 'clientRank', label: '等级', group: '基础'),
    MasterFieldDef(key: 'status', label: '状态', group: '基础'),
    MasterFieldDef(key: 'linkman', label: '联系人', group: '联系'),
    MasterFieldDef(key: 'mobile', label: '手机', group: '联系'),
    MasterFieldDef(key: 'phone', label: '电话', group: '联系'),
    MasterFieldDef(key: 'phone2', label: '电话2', group: '联系'),
    MasterFieldDef(key: 'fax', label: '传真', group: '联系'),
    MasterFieldDef(key: 'email', label: '邮箱', group: '联系'),
    MasterFieldDef(key: 'website', label: '网址', group: '联系'),
    MasterFieldDef(key: 'postcode', label: '邮编', group: '联系'),
    MasterFieldDef(key: 'region', label: '区域', group: '地址'),
    MasterFieldDef(key: 'placeId', label: '地区', group: '地址'),
    MasterFieldDef(key: 'address', label: '地址', group: '地址'),
    MasterFieldDef(key: 'shipAddress', label: '收货地址', group: '地址'),
    MasterFieldDef(key: 'shipVia', label: '运输方式', group: '地址'),
    MasterFieldDef(key: 'legalPerson', label: '法人', group: '资质'),
    MasterFieldDef(key: 'empId', label: '业务员', group: '资质'),
    MasterFieldDef(key: 'bank', label: '开户行', group: '财务'),
    MasterFieldDef(key: 'bankAccount', label: '银行账号', group: '财务'),
    MasterFieldDef(key: 'taxId', label: '税号', group: '财务'),
    MasterFieldDef(key: 'credit', label: '信用额度', type: MasterFieldType.money, group: '财务'),
    MasterFieldDef(key: 'initTotal', label: '期初应收', type: MasterFieldType.money, group: '财务'),
    MasterFieldDef(key: 'tday', label: '结算天数', type: MasterFieldType.integer, group: '财务'),
    MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
  ];

  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientEdit);

  // ---- 客户 新建/编辑/删除 ------------------------------------------------

  void _showClientCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增客户', // TODO(l10n): 补 arb
      fields: _clientFields,
      fixedValues: {'categoryId': widget.nodeId},
      onSubmit: _doCreateClient,
    );
  }

  Future<bool> _doCreateClient(Map<String, dynamic> body) async {
    try {
      await widget.ref.read(clientRepositoryProvider).create(body);
      if (!mounted) return false;
      context.appSuccess('客户已创建'); // TODO(l10n): 补 arb
      await _loadClients(_clientPageNum);
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

  void _showClientEdit(ClientDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑客户', // TODO(l10n): 补 arb
      fields: _clientFields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'fullName': d.fullName ?? '',
        'clientRank': d.clientRank ?? '',
        'region': d.region ?? '',
        'placeId': d.placeId ?? '',
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
        'credit': d.credit?.toString() ?? '',
        'initTotal': d.initTotal?.toString() ?? '',
        'tday': d.tday?.toString() ?? '',
        'status': d.status ?? '',
        'remark': d.remark ?? '',
      },
      fixedValues: {'categoryId': d.categoryId ?? widget.nodeId},
      onSubmit: (body) => _doUpdateClient(d.id, body),
    );
  }

  Future<bool> _doUpdateClient(String id, Map<String, dynamic> body) async {
    try {
      await widget.ref.read(clientRepositoryProvider).update(id, body);
      if (!mounted) return false;
      context.appSuccess('客户已更新'); // TODO(l10n): 补 arb
      await _loadClients(_clientPageNum);
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

  Future<void> _deleteClient(ClientDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除客户'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该客户')}」吗？', // TODO(l10n): 补 arb
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
      await widget.ref.read(clientRepositoryProvider).delete(d.id);
      if (!mounted) return;
      context.appSuccess('客户已删除'); // TODO(l10n): 补 arb
      await _loadClients(_clientPageNum);
      // 删空当前页时回退上一页，避免列表显示空白
      if (mounted &&
          _clientPage != null &&
          _clientPage!.items.isEmpty &&
          _clientPage!.page > 1) {
        await _loadClients(_clientPage!.page - 1);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  /// 点客户行：拉详情弹框。用独立的 [_detailLoading] 防并发（见 mould 页同款注释）。
  Future<void> _showClientDetail(String id) async {
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
    ClientDetail? d;
    try {
      d = await widget.ref.read(clientRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) {
        context.appError('加载客户详情失败'); // TODO(l10n): 补 arb
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
    await showMasterDetailSheet(
      context: context,
      title: d.name ?? d.code ?? '客户详情',
      rows: _clientDetailRows(d),
      canEdit: _canEditMaster,
      onEdit: () {
        if (d != null) _showClientEdit(d);
      },
      onDelete: () {
        if (d != null) _deleteClient(d);
      },
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _clientDetailRows(ClientDetail d) => [
        MasterDetailRow('编号', d.code), // TODO(l10n): 补 arb
        MasterDetailRow('名称', d.name), // TODO(l10n): 补 arb
        MasterDetailRow('全称', d.fullName), // TODO(l10n): 补 arb
        MasterDetailRow('等级', d.clientRank), // TODO(l10n): 补 arb
        MasterDetailRow('分类', d.categoryName), // TODO(l10n): 补 arb
        MasterDetailRow('区域', d.region), // TODO(l10n): 补 arb
        MasterDetailRow('地区', d.placeId), // TODO(l10n): 补 arb
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
        MasterDetailRow('信用额度', d.credit?.toStringAsFixed(2)), // TODO(l10n): 补 arb
        MasterDetailRow('期初应收', d.initTotal?.toStringAsFixed(2)), // TODO(l10n): 补 arb
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
    final total = _clientPage?.total ?? 0;
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
              icon: Icons.people_outline,
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
          // 固定：客户标题 + 添加按钮
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Row(
              children: [
                Icon(Icons.people_outline,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '客户 ($total)', // TODO(l10n): 补 arb
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: UtenSearchBar(
                    hint: '搜索客户（简称/编码/全称/联系人/手机）', // TODO(l10n): 补 arb
                    initialValue: _keyword,
                    onChanged: _onKeywordChanged,
                  ),
                ),
                if (_canEditMaster) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.add_rounded,
                    onPressed: _showClientCreate,
                    child: const Text('添加客户'), // TODO(l10n): 补 arb
                  ),
                ],
              ],
            ),
          ),
          // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）
          Expanded(
            child: MasterDataTableView<ClientListItem>(
              columns: _clientColumns,
              items: _clientPage?.items ?? const [],
              facets: _facets?.fields ?? const {},
              nullCounts: _facets?.nullCounts ?? const {},
              filters: _filters,
              onFilterChanged: _onFilterChanged,
              onRowTap: (m) => _showClientDetail(m.id),
              isLoading: _clientLoading && _clientPage == null,
              loadingMore: _clientLoading && _clientPage != null,
              error: _clientError,
              onRetry: () => _loadClients(_clientPageNum),
              emptyMessage: '该分类暂无客户', // TODO(l10n): 补 arb
              currentPage: _clientPage?.page ?? 1,
              totalPages: _clientPage?.totalPages ?? 1,
              onPageChange: (p) => _loadClients(p),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 客户列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 客户表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  /// 「主结账方式」「总监」V36 无对应列 → 单元格恒空、不进 FACET_COLUMNS/nullFields 白名单，
  /// 列头下拉只有"所有"（不可筛）；保留列位与用户给定 23 列布局一致。
  /// credit 显示两位小数；tday 直接 toString。
  static final _clientColumns = <MasterColumnDef<ClientListItem>>[
    MasterColumnDef(
        key: 'code', label: '客户编码', width: 100, value: (m) => m.code),
    MasterColumnDef(
        key: 'name', label: '客户简称', width: 140, value: (m) => m.name),
    MasterColumnDef(
        key: 'fullName', label: '客户全称', width: 200, value: (m) => m.fullName),
    MasterColumnDef(
        key: 'settlementMethod',
        label: '主结账方式',
        width: 110,
        value: (m) => null),
    MasterColumnDef(
        key: 'clientXz', label: '客户性质', width: 90, value: (m) => m.clientXz),
    MasterColumnDef(
        key: 'tday',
        label: '信用天数',
        width: 80,
        value: (m) => m.tday?.toString()),
    MasterColumnDef(
        key: 'director', label: '总监', width: 90, value: (m) => null),
    MasterColumnDef(
        key: 'region', label: '区域', width: 100, value: (m) => m.region),
    MasterColumnDef(
        key: 'placeId', label: '所属地区', width: 110, value: (m) => m.placeId),
    MasterColumnDef(
        key: 'empId', label: '业务员', width: 90, value: (m) => m.empId),
    MasterColumnDef(
        key: 'legalPerson',
        label: '法人代表',
        width: 100,
        value: (m) => m.legalPerson),
    MasterColumnDef(
        key: 'linkman', label: '联系人', width: 90, value: (m) => m.linkman),
    MasterColumnDef(
        key: 'mobile', label: '手机', width: 120, value: (m) => m.mobile),
    MasterColumnDef(
        key: 'phone', label: '联系电话', width: 120, value: (m) => m.phone),
    MasterColumnDef(
        key: 'phone2', label: '备用电话', width: 120, value: (m) => m.phone2),
    MasterColumnDef(key: 'fax', label: '传真', width: 110, value: (m) => m.fax),
    MasterColumnDef(
        key: 'postcode', label: '邮编', width: 80, value: (m) => m.postcode),
    MasterColumnDef(
        key: 'address', label: '地址', width: 220, value: (m) => m.address),
    MasterColumnDef(
        key: 'bank', label: '开户银行', width: 160, value: (m) => m.bank),
    MasterColumnDef(
        key: 'bankAccount',
        label: '银行账号',
        width: 160,
        value: (m) => m.bankAccount),
    MasterColumnDef(
        key: 'taxId', label: '纳税号', width: 140, value: (m) => m.taxId),
    MasterColumnDef(
        key: 'credit',
        label: '信誉额度',
        width: 110,
        value: (m) => m.credit?.toStringAsFixed(2)),
    MasterColumnDef(
        key: 'website', label: '网址', width: 160, value: (m) => m.website),
  ];
}
