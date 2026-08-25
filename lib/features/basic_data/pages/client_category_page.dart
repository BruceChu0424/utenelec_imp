// 客户资料分类树管理页（基础资料）
//
// 与 mould_category_page.dart（模具资料）/ product_category_page.dart（货品资料）同构：
// 顶层壳层（树加载/统一搜索/分类 CRUD/build 骨架）复用 CategoryPageShell，
// 本页只声明文案/图标/权限/仓储钩子 + 客户领域差异：
// - 详情面板调 clientCategoryRepository.detail + clientRepository 分类下分页；
// - 结账方式字典预取与关联失效校验、业务员选择、信用/期初应收等字段；
// - 编辑类按钮（新增/编辑/删除）按 client_category:edit 权限显隐；查看全员可见（路由不设守卫）。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/07-客户资料-新库与迁移.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/client_node.dart';
import '../models/master_facet.dart';
import '../models/product_category_node.dart';
import '../models/reference_method_option.dart';
import '../repositories/client_category_repository.dart';
import '../repositories/client_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/reference_method_repository.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/client_access_panel.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/system_master_category_guard.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../widgets/master_data_table_view.dart';

class ClientCategoryPage extends ConsumerStatefulWidget {
  const ClientCategoryPage({super.key});

  @override
  ConsumerState<ClientCategoryPage> createState() => _ClientCategoryPageState();
}

class _ClientCategoryPageState extends ConsumerState<ClientCategoryPage>
    with CategoryPageShell<ClientCategoryPage> {
  @override
  String get shellTitle => '客户资料'; // TODO(l10n): 补 arb

  @override
  String get shellSearchHint => '搜索分类/客户名称或编号'; // TODO(l10n): 补 arb

  @override
  String get shellContentNoun => '客户';

  @override
  IconData get shellEmptyIcon => Icons.people_outline;

  @override
  String get shellPersistenceKey => 'basicData.client';

  @override
  bool get shellCanCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.clientCategoryCreate);

  @override
  bool get shellCanEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.clientCategoryEdit);

  @override
  bool get shellCanDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.clientCategoryDelete);

  @override
  bool get shellCanMove =>
      ref.read(currentPermissionsProvider).contains(Perm.clientCategoryMove);

  @override
  bool get shellCanReorder =>
      ref.read(currentPermissionsProvider).contains(Perm.clientCategoryReorder);

  @override
  Future<List<ProductCategoryNode>> shellLoadTree() =>
      ref.read(clientCategoryRepositoryProvider).tree();

  @override
  Future<void> shellCreateCategory(CategoryEditResult r) => ref
      .read(clientCategoryRepositoryProvider)
      .create(
        ProductCategorySaveInput(
          name: r.name,
          remark: r.remark,
          codePrefix: r.codePrefix,
          parentId: r.parentId,
          sortOrder: r.sortOrder,
        ),
      );

  @override
  Future<void> shellUpdateCategory(String id, CategoryEditResult r) => ref
      .read(clientCategoryRepositoryProvider)
      .update(
        id,
        ProductCategoryUpdateInput(
          name: r.name,
          codePrefix: r.codePrefix,
          remark: r.remark,
          version: r.version ?? 0,
          parentId: r.parentId,
          sortOrder: r.sortOrder,
          moveToRoot: r.moveToRoot,
        ),
      );

  @override
  Future<void> shellDeleteCategory(String id) =>
      ref.read(clientCategoryRepositoryProvider).delete(id);

  @override
  Future<CategoryPrefixPreview> shellPrefixPreview(
    String id,
    String prefix,
    String? parentId,
  ) => ref
      .read(clientCategoryRepositoryProvider)
      .prefixPreview(id, prefix, parentId: parentId);

  @override
  Future<Set<String>?> shellContentCategoryIds(
    String q,
    bool Function() isCurrent,
  ) async {
    final repository = ref.read(clientRepositoryProvider);
    return collectPagedHierarchyCategoryIds<ClientListItem>(
      loadPage: (page) => repository.search(q, page: page, size: 100),
      categoryIdOf: (item) => item.categoryId,
      isCurrent: isCurrent,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => shellReload());
  }

  /// 分类创建/编辑保存后：除了树（shellReload 已做），还要重挂右栏详情面板——
  /// 否则分类卡片仍显示旧名称/前缀，且前缀变更后客户编号已变、列表也需重拉，
  /// 需要手动刷新才能看到最新值。
  int _detailEpoch = 0;

  @override
  void shellAfterCategorySaved() => setState(() => _detailEpoch++);

  @override
  Widget build(BuildContext context) {
    return buildShell(
      context,
      detailPaneBuilder: (selected) => _DetailPane(
        key: ValueKey('dp-${selected.id}-$_detailEpoch'),
        ref: ref,
        nodeId: selected.id,
        canEdit: shellCanEdit,
        canAddCategory: shellCanCreate,
        canDeleteCategory: shellCanDelete,
        externalKeyword: shellTreeSearchKeyword,
        onAddChild: () => shellShowCreateDialog(parent: selected),
        onEdit: (detail) => shellShowEditDialog(detail),
        onDelete: () => shellDeleteNode(selected),
      ),
    );
  }
}

/// 客户分类详情面板：只调 detail（分类信息）+ 该分类下的客户分页。
class _DetailPane extends StatefulWidget {
  const _DetailPane({
    super.key,
    required this.ref,
    required this.nodeId,
    required this.canEdit,
    required this.canAddCategory,
    required this.canDeleteCategory,
    required this.externalKeyword,
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
  });

  final WidgetRef ref;
  final String nodeId;
  final bool canEdit;
  final bool canAddCategory;
  final bool canDeleteCategory;

  /// 顶部树搜索命中客户时传入的过滤词：详情面板把它采纳为本地客户列表的搜索词，
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

  // 该分类（子树）下的客户分页；父分类也加载（子树汇总）。
  PagedResult<ClientListItem>? _clientPage;
  int _clientPageNum = 1;
  bool _clientLoading = false;
  String? _clientError;

  // 字段筛选 + 搜索 + facet（筛选栏用）。切换分类时重置。
  Map<String, String?> _filters = {};
  String _keyword = '';
  ClientFacets? _facets;

  // 搜索框重建种子：外部关键词（树搜索）变化时自增，驱动 UtenSearchBar 用新 initialValue 重建。
  int _kwSeed = 0;

  // 列排序态（金额/数量/日期列）：null = 默认顺序（id ASC）。
  String? _sortKey;
  bool _sortAsc = true;

  /// 详情弹窗加载中（防并发）。与 [_clientLoading]（列表分页加载）是两回事，不可混用。
  bool _detailLoading = false;

  /// 多选选中集（业务 id，跨页保留；批量禁用/删除用）。切换分类时清空。
  Set<String> _selectedClientIds = {};

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
      _loadClients(1);
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
          .read(clientCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置客户分页 + 筛选状态 + facet + 排序态。
        _clientPage = null;
        _clientPageNum = 1;
        _clientError = null;
        _filters = {};
        // 外部搜索词（树搜索命中）随分类切换一并带入：搜索定位时右侧只显示搜索结果。
        _keyword = widget.externalKeyword ?? '';
        _kwSeed++;
        _facets = null;
        _sortKey = null;
        _sortAsc = true;
        _selectedClientIds = {}; // 切分类清空多选（选中的是旧分类的行）
      });
      // 父分类也加载（后端按子树汇总）；并行拉客户列表与字段 facet。
      await Future.wait([_loadClients(1), _loadFacets()]);
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

  // ---- 客户分页 ----------------------------------------------------------

  Future<void> _loadClients(int page) async {
    final generation = _listRequests.begin();
    setState(() {
      _clientLoading = true;
      _clientError = null;
      _clientPageNum = page;
    });
    try {
      final result = await widget.ref
          .read(clientRepositoryProvider)
          .list(
            widget.nodeId,
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _clientPage = result;
      });
    } on ApiException catch (e) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _clientError = e.message;
      });
    } catch (_) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _clientError = '加载客户列表失败'; // TODO(l10n): 补 arb
      });
    } finally {
      if (mounted && _listRequests.isCurrent(generation)) {
        setState(() => _clientLoading = false);
      }
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    try {
      final f = await widget.ref
          .read(clientRepositoryProvider)
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
    _loadClients(1); // 任一筛选变化回到第 1 页
  }

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadClients(1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _loadClients(1); // 排序变化回第 1 页重载
  }

  /// 导出查询参数（与 _loadClients 一致，不含 page/size）。
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
        .read(clientRepositoryProvider)
        .list(
          widget.nodeId,
          size: 2000,
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          filters: _filters,
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    return UtenPrintTable(
      headers: [for (final c in _clientColumns) c.label],
      rows: [
        for (final a in result.items)
          [for (final c in _clientColumns) c.value(a) ?? ''],
      ],
    );
  }

  // 客户主档可编辑字段（与后端 ClientSaveRequest 对齐；含义不明的遗留字段不进表单）。
  List<MasterFieldDef> _clientFields(
    Map<String, String> iv,
    List<ReferenceMethodOption> settlementMethods,
  ) => [
    ...const <MasterFieldDef>[
      MasterFieldDef(key: 'name', label: '名称', required: true, group: '基础'),
      MasterFieldDef(
        key: 'code',
        label: '编号',
        group: '基础',
        hint: '留空按分类前缀自动生成；手工编号也必须唯一',
      ),
      MasterFieldDef(key: 'fullName', label: '全称', group: '基础'),
      MasterFieldDef(key: 'clientRank', label: '等级', group: '基础'),
      MasterFieldDef(
        key: 'status',
        label: '状态',
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        required: true,
        group: '基础',
      ),
      MasterFieldDef(key: 'linkman', label: '联系人', group: '联系'),
      MasterFieldDef(key: 'mobile', label: '手机', required: true, group: '联系'),
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
    ],
    ...const <MasterFieldDef>[
      MasterFieldDef(key: 'bank', label: '开户行', group: '财务'),
      MasterFieldDef(key: 'bankAccount', label: '银行账号', group: '财务'),
      MasterFieldDef(key: 'taxId', label: '税号', group: '财务'),
    ],
    MasterFieldDef(
      key: 'defaultSettlementMethodId',
      label: '默认结账方式',
      type: MasterFieldType.select,
      options: [
        for (final method in settlementMethods)
          MasterSelectOption(
            value: method.id,
            label: method.code.isEmpty
                ? method.name
                : '${method.name} · ${method.code}',
          ),
      ],
      group: '财务',
      hint: '订单未指定时使用；关联以系统 UUID 保存',
    ),
    ...const <MasterFieldDef>[
      MasterFieldDef(
        key: 'credit',
        label: '信用额度',
        type: MasterFieldType.money,
        group: '财务',
      ),
      MasterFieldDef(
        key: 'initTotal',
        label: '期初应收',
        type: MasterFieldType.money,
        group: '财务',
      ),
      MasterFieldDef(
        key: 'creditFloor',
        label: '铺底额',
        type: MasterFieldType.money,
        group: '财务',
      ),
      MasterFieldDef(
        key: 'tday',
        label: '结算天数',
        type: MasterFieldType.integer,
        group: '财务',
      ),
      MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
    ],
  ];

  bool get _canCreateMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientCreate);
  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientEdit);
  bool get _canDeleteMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientDelete);
  bool get _canStatusMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientStatus);

  bool _settlementOptionsLoading = false;

  Future<List<ReferenceMethodOption>?> _loadSettlementMethods() async {
    if (_settlementOptionsLoading) return null;
    _settlementOptionsLoading = true;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final methods = await widget.ref
          .read(referenceMethodRepositoryProvider)
          .settlementMethods();
      if (methods.isEmpty) {
        if (mounted) context.appError('暂无可用结账方式，请先维护结账方式字典');
        return null;
      }
      return methods;
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载结账方式失败，请重试');
    } finally {
      if (nav.canPop()) nav.pop();
      _settlementOptionsLoading = false;
    }
    return null;
  }

  // ---- 客户 新建/编辑/删除 ------------------------------------------------

  Future<void> _showClientCreate() async {
    final settlementMethods = await _loadSettlementMethods();
    if (!mounted || settlementMethods == null) return;
    const iv = <String, String>{};
    showMasterEditDialog(
      context: context,
      title: '新增客户', // TODO(l10n): 补 arb
      fields: _clientFields(iv, settlementMethods),
      initialValues: const {'status': '使用'},
      fixedValues: {'categoryId': widget.nodeId},
      readOnlyKeys: _canStatusMaster ? null : const {'status'},
      onSubmit: _doCreateClient,
    );
  }

  Future<bool> _doCreateClient(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await widget.ref.read(clientRepositoryProvider).create(body);
      },
      success: '客户已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadClients(_clientPageNum);
    return true;
  }

  Future<void> _showClientEdit(ClientDetail d) async {
    final settlementMethods = await _loadSettlementMethods();
    if (!mounted || settlementMethods == null) return;
    if (d.defaultSettlementMethodId != null &&
        !settlementMethods.any(
          (method) => method.id == d.defaultSettlementMethodId,
        )) {
      context.appError('当前默认结账方式已不可用，请先修复客户结账方式关联');
      return;
    }
    final iv = <String, String>{
      'name': d.name ?? '',
      'code': d.code ?? '',
      'fullName': d.fullName ?? '',
      'clientRank': d.clientRank ?? '',
      'region': d.region ?? '',
      'placeId': d.placeId ?? '',
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
      'creditFloor': d.creditFloor?.toString() ?? '',
      'tday': d.tday?.toString() ?? '',
      'defaultSettlementMethodId': d.defaultSettlementMethodId ?? '',
      'status': d.status ?? '',
      'remark': d.remark ?? '',
    };
    showMasterEditDialog(
      context: context,
      title: '编辑客户', // TODO(l10n): 补 arb
      fields: _clientFields(iv, settlementMethods),
      initialValues: iv,
      fixedValues: {
        'categoryId': d.categoryId ?? widget.nodeId,
        if (d.version != null) 'version': d.version,
      },
      readOnlyKeys: _canStatusMaster ? null : const {'status'},
      onSubmit: (body) => _doUpdateClient(d.id, body),
    );
  }

  Future<bool> _doUpdateClient(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await widget.ref.read(clientRepositoryProvider).update(id, body);
      },
      success: '客户已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadClients(_clientPageNum);
    return true;
  }

  Future<void> _deleteClient(ClientDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除客户'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该客户')}」吗？', // TODO(l10n): 补 arb
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
        await widget.ref.read(clientRepositoryProvider).delete(d.id);
      },
      success: '客户已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadClients(_clientPageNum);
    // 删空当前页时回退上一页，避免列表显示空白
    if (mounted &&
        _clientPage != null &&
        _clientPage!.items.isEmpty &&
        _clientPage!.page > 1) {
      await _loadClients(_clientPage!.page - 1);
    }
  }

  Future<void> _showClientAccess(ClientDetail detail) async {
    final repository = widget.ref.read(clientRepositoryProvider);
    final saved = await showClientAccessPanel(
      context: context,
      ref: widget.ref,
      clientId: detail.id,
      clientName: detail.name ?? detail.code ?? '客户',
      loader: repository.access,
      saver: repository.updateAccess,
    );
    if (saved != null && mounted) await _loadClients(_clientPageNum);
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
    final detail = d;
    await showMasterDetailSheet(
      context: context,
      title: detail.name ?? detail.code ?? '客户详情',
      rows: _clientDetailRows(detail),
      extraActions: [
        if (detail.accessManageable)
          MasterDetailAction(
            label: '负责人和可见人',
            icon: Icons.manage_accounts_outlined,
            onPressed: () => _showClientAccess(detail),
          ),
      ],
      canEdit: _canEditMaster && detail.writable,
      canDelete: _canDeleteMaster && detail.writable,
      onToggleStatus: _canStatusMaster && detail.writable
          ? () async {
              final next = detail.status == '使用' ? '禁用' : '使用';
              final ok = await context.guardRun(
                () => widget.ref
                    .read(masterStatusRepositoryProvider)
                    .change(
                      resourcePath: ApiEndpoints.client(detail.id),
                      status: next,
                      version: detail.version,
                    ),
                success: next == '禁用' ? '已停用' : '已启用',
              );
              if (ok && mounted) await _loadClients(_clientPageNum);
            }
          : null,
      statusActionLabel: detail.status == '使用' ? '停用' : '启用',
      onEdit: () {
        _showClientEdit(detail);
      },
      onDelete: () {
        _deleteClient(detail);
      },
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _clientDetailRows(ClientDetail d) => [
    MasterDetailRow('当前访问', d.accessReasonLabel),
    MasterDetailRow('编号', d.code), // TODO(l10n): 补 arb
    MasterDetailRow('名称', d.name), // TODO(l10n): 补 arb
    MasterDetailRow('全称', d.fullName), // TODO(l10n): 补 arb
    MasterDetailRow('等级', d.clientRank), // TODO(l10n): 补 arb
    MasterDetailRow('分类', d.categoryName), // TODO(l10n): 补 arb
    MasterDetailRow('区域', d.region), // TODO(l10n): 补 arb
    MasterDetailRow('地区', d.placeId), // TODO(l10n): 补 arb
    MasterDetailRow('负责人', d.ownerEmployeeName ?? d.empId), // TODO(l10n): 补 arb
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
    MasterDetailRow(
      '期初应收',
      d.initTotal?.toStringAsFixed(2),
    ), // TODO(l10n): 补 arb
    MasterDetailRow('铺底额', d.creditFloor?.toStringAsFixed(2)),
    MasterDetailRow('结算天数', d.tday?.toString()), // TODO(l10n): 补 arb
    MasterDetailRow('默认结账方式', d.defaultSettlementMethodName),
    MasterDetailRow('邮箱', d.email), // TODO(l10n): 补 arb
    MasterDetailRow('网址', d.website), // TODO(l10n): 补 arb
    MasterDetailRow('状态', d.status), // TODO(l10n): 补 arb
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
    final total = _clientPage?.total ?? 0;
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
            icon: Icons.people_outline,
            subtitle:
                '编号前缀 ${d.effectivePrefix ?? 'KH'}${d.codePrefix == null ? '（继承）' : ''}'
                '${d.remark?.isNotEmpty == true ? ' · ${d.remark}' : ''} · 层级 L${d.level}',
            // 详情卡精简（与货品/模具/供应商/收付方式分类卡统一）：不再展示统计行
            // 与路径行——左侧分类树已是主视觉，层级/父级/子项数树里都能看出，卡片只留标题+操作。
            stats: const [],
            canEdit: canMutateCategory,
            canAddChild: widget.canAddCategory,
            canDelete: widget.canDeleteCategory && !isSystemRoot,
            onAddChild: widget.onAddChild,
            onEdit: () {
              if (_detail != null) widget.onEdit(_detail!);
            },
            onDelete: widget.onDelete,
            deleteLabel: '删除分类', // TODO(l10n): 补 arb
            extraActions: [
              if (widget.canAddCategory && isSystemRoot)
                MasterDetailCardAction(
                  icon: Icons.add_rounded,
                  label: '新增子分类', // TODO(l10n): 补 arb
                  onPressed: widget.onAddChild,
                ),
            ],
            secondaryActions: [
              if ((widget.canEdit || widget.canDeleteCategory) && isSystemRoot)
                const SystemMasterCategoryProtectionNotice(),
            ],
          ),
        ),
        // body：客户标题 + 搜索 + 添加按钮（卡片收起后吸顶）+ 表格（内滚）。
        body: Column(
          children: [
            // 客户标题 + 搜索 + 添加按钮（与原布局一致：添加在搜索右侧）
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Row(
                children: [
                  Icon(
                    Icons.people_outline,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '客户 ($total)', // TODO(l10n): 补 arb
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: UtenSearchBar(
                      // key 含 nodeId + _kwSeed：切分类 / 树搜索写入关键词时重建搜索框同步显示。
                      key: ValueKey('client-search-${widget.nodeId}-$_kwSeed'),
                      hint: '搜索客户（简称/编码/全称/联系人/手机）', // TODO(l10n): 补 arb
                      initialValue: _keyword,
                      onChanged: _onKeywordChanged,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  // 预览打印 / 导出：已移入表格工具条（表头设置旁，深绿大按钮）。
                  if (_canCreateMaster) ...[
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
            // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）。
            // primary:true → 表体参与「卡片折叠 → 表格内滚」联动（拾取 NestedScrollView inner controller）。
            Expanded(
              child: MasterDataTableView<ClientListItem>(
                primary: true,
                columns: _clientColumns,
                items: _clientPage?.items ?? const [],
                // 多选：最前列勾选框 + 表头三态全选；选中非空时工具条出批量操作区。
                selectable: true,
                idOf: (c) => c.id,
                selectedIds: _selectedClientIds,
                onSelectedIdsChanged: (s) =>
                    setState(() => _selectedClientIds = s),
                batchActionsBuilder: _clientBatchActions,
                // 行菜单（右击/长按）：查看/启用/禁用/编辑/删除。
                rowMenuBuilder: _clientMenuItems,
                toolbarActions: [
                  UtenPrintPreviewButton(
                    title: '客户资料',
                    subtitle: '最多前 2000 行',
                    loader: _printLoader,
                    exportEndpoint: '/master/clients/export',
                    exportPermission: Perm.clientExport,
                    exportReport: '',
                    exportQuery: _exportQuery,
                    exportFilename: '客户资料',
                    type: UtenButtonType.primary,
                    size: UtenButtonSize.large,
                  ),
                  UtenExportButton(
                    endpoint: '/master/clients/export',
                    requiredPermission: Perm.clientExport,
                    report: '',
                    queryParams: _exportQuery,
                    filename: '客户资料',
                    label: '导出客户',
                    type: UtenButtonType.primary,
                    size: UtenButtonSize.large,
                  ),
                ],
                facets: _facets?.fields ?? const {},
                nullCounts: _facets?.nullCounts ?? const {},
                filters: _filters,
                onFilterChanged: _onFilterChanged,
                // 行底色按状态：使用=浅蓝、禁用=浅红；单击选中自动加深加亮。
                rowColor: (c) => switch (c.status) {
                  '使用' => Colors.lightBlue.withValues(alpha: 0.13),
                  '禁用' => Colors.red.withValues(alpha: 0.10),
                  _ => null,
                },
                onRowTap: (m) => _showClientDetail(m.id),
                sortColumn: _sortKey,
                sortAscending: _sortAsc,
                onSortChange: _onSortChange,
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
      ),
    );
  }

  // ---- 行菜单（右击/长按）+ 多选批量 --------------------------------------

  /// 启用/禁用客户：拉详情全量回传、仅改状态。
  Future<void> _toggleClientStatus(ClientListItem c) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    ClientDetail? d;
    try {
      d = await widget.ref.read(clientRepositoryProvider).detail(c.id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载客户详情失败'); // TODO(l10n): 补 arb
    }
    if (d == null || !mounted) {
      _rowOpBusy = false;
      return;
    }
    if (!d.writable) {
      context.appInfo('当前访问：${d.accessReasonLabel}，${d.readOnlyActionHint}');
      _rowOpBusy = false;
      return;
    }
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => widget.ref
          .read(masterStatusRepositoryProvider)
          .change(
            resourcePath: ApiEndpoints.client(d!.id),
            status: next,
            version: d.version,
          ),
      success: next == '禁用' ? '客户已禁用' : '客户已启用', // TODO(l10n): 补 arb
    );
    if (ok && mounted) await _loadClients(_clientPageNum);
    _rowOpBusy = false;
  }

  /// 菜单「编辑/删除」：先拉详情再走既有流程。
  Future<void> _withClientDetail(
    String id,
    Future<void> Function(ClientDetail d) action,
  ) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    ClientDetail? d;
    try {
      d = await widget.ref.read(clientRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载客户详情失败'); // TODO(l10n): 补 arb
    }
    _rowOpBusy = false;
    if (d == null || !mounted) return;
    if (!d.writable) {
      context.appInfo('当前访问：${d.accessReasonLabel}，${d.readOnlyActionHint}');
      return;
    }
    await action(d);
  }

  /// 行菜单条目（右击/长按弹出）。可用性按权限 + 行状态实时决定。
  List<UtenContextMenuEntry> _clientMenuItems(ClientListItem c) {
    final inUse = c.status == '使用';
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _showClientDetail(c.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: inUse ? '禁用客户' : '启用客户',
        icon: inUse
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        enabled: _canStatusMaster && c.writable,
        destructive: inUse,
        onTap: () => _toggleClientStatus(c),
      ),
      UtenMenuItem(
        label: '编辑客户',
        icon: Icons.edit_outlined,
        enabled: _canEditMaster && c.writable,
        onTap: () => _withClientDetail(c.id, (d) async => _showClientEdit(d)),
      ),
      UtenMenuItem(
        label: '删除客户',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canDeleteMaster && c.writable,
        onTap: () => _withClientDetail(c.id, _deleteClient),
      ),
    ];
  }

  List<Widget> _clientBatchActions(BuildContext context, Set<String> ids) {
    if (!_canStatusMaster && !_canDeleteMaster) return const [];
    final byId = {
      for (final item in _clientPage?.items ?? const <ClientListItem>[])
        item.id: item,
    };
    final includesReadOnly = ids.any((id) => byId[id]?.writable != true);
    if (includesReadOnly) {
      return const [Text('所选客户包含只读数据，请取消只读客户后再批量操作')];
    }
    return [
      if (_canStatusMaster)
        UtenButton(
          size: UtenButtonSize.small,
          type: UtenButtonType.tonal,
          icon: Icons.pause_circle_outline_rounded,
          onPressed: _rowOpBusy ? null : () => _batchSetClientStatus(ids, '禁用'),
          child: const Text('批量禁用'), // TODO(l10n): 补 arb
        ),
      if (_canDeleteMaster)
        UtenButton(
          size: UtenButtonSize.small,
          type: UtenButtonType.danger,
          icon: Icons.delete_outline_rounded,
          onPressed: _rowOpBusy ? null : () => _batchDeleteClients(ids),
          child: const Text('批量删除'), // TODO(l10n): 补 arb
        ),
    ];
  }

  /// 批量启停：逐条拉详情全量回传、仅改状态（无专用批量接口，复用单条更新）。
  Future<void> _batchSetClientStatus(Set<String> ids, String status) async {
    if (_rowOpBusy || ids.isEmpty) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(clientRepositoryProvider);
    var okCount = 0;
    var skipped = 0;
    for (final id in ids) {
      try {
        final d = await repo.detail(id);
        if (!d.writable) {
          skipped++;
          continue;
        }
        if (d.status == status) {
          skipped++;
          continue;
        }
        await widget.ref
            .read(masterStatusRepositoryProvider)
            .change(
              resourcePath: ApiEndpoints.client(id),
              status: status,
              version: d.version,
            );
        okCount++;
      } catch (_) {
        skipped++;
      }
    }
    _rowOpBusy = false;
    if (!mounted) return;
    setState(() => _selectedClientIds = {});
    context.appSuccess(
      status == '禁用'
          ? '已禁用 $okCount 个客户${skipped > 0 ? '，$skipped 个跳过' : ''}'
          : '已启用 $okCount 个客户${skipped > 0 ? '，$skipped 个跳过' : ''}',
    );
    await _loadClients(_clientPageNum);
  }

  /// 批量删除：确认后逐个删（容忍单条失败，如被单据引用）。
  Future<void> _batchDeleteClients(Set<String> ids) async {
    if (_rowOpBusy || ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除客户'), // TODO(l10n): 补 arb
        content: Text('确定删除选中的 ${ids.length} 个客户吗？被单据引用的客户会删除失败。'),
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
    final repo = widget.ref.read(clientRepositoryProvider);
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
    setState(() => _selectedClientIds = {});
    context.appSuccess(
      '已删除 $okCount 个客户${failed.isNotEmpty ? '，${ids.length - okCount} 个失败' : ''}',
    );
    if (failed.isNotEmpty) context.appError(failed.first);
    await _loadClients(_clientPageNum);
  }

  // ---- 客户列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 客户表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  /// 主结账方式由 UUID 关联解析；总监仍无对应列、单元格恒空。
  /// credit 显示两位小数；tday 直接 toString。
  static final _clientColumns = <MasterColumnDef<ClientListItem>>[
    MasterColumnDef(
      key: 'code',
      label: '客户编码',
      width: 100,
      value: (m) => m.code,
    ),
    MasterColumnDef(
      key: 'name',
      label: '客户简称',
      width: 140,
      value: (m) => m.name,
    ),
    MasterColumnDef(
      key: 'fullName',
      label: '客户全称',
      width: 200,
      value: (m) => m.fullName,
    ),
    MasterColumnDef(
      key: 'defaultSettlementMethodName',
      label: '主结账方式',
      width: 110,
      value: (m) => m.defaultSettlementMethodName,
    ),
    MasterColumnDef(
      key: 'clientXz',
      label: '客户性质',
      width: 90,
      value: (m) => m.clientXz,
    ),
    MasterColumnDef(
      key: 'tday',
      label: '信用天数',
      width: 80,
      type: 'number',
      sortable: true,
      value: (m) => m.tday?.toString(),
    ),
    MasterColumnDef(
      key: 'region',
      label: '区域',
      width: 100,
      value: (m) => m.region,
    ),
    MasterColumnDef(
      key: 'placeId',
      label: '所属地区',
      width: 110,
      value: (m) => m.placeId,
    ),
    MasterColumnDef(
      key: 'ownerEmployeeName',
      label: '负责人',
      width: 120,
      value: (m) => m.ownerEmployeeName ?? m.empId,
    ),
    MasterColumnDef(
      key: 'legalPerson',
      label: '法人代表',
      width: 100,
      value: (m) => m.legalPerson,
    ),
    MasterColumnDef(
      key: 'linkman',
      label: '联系人',
      width: 90,
      value: (m) => m.linkman,
    ),
    MasterColumnDef(
      key: 'mobile',
      label: '手机',
      width: 120,
      value: (m) => m.mobile,
    ),
    MasterColumnDef(
      key: 'phone',
      label: '联系电话',
      width: 120,
      value: (m) => m.phone,
    ),
    MasterColumnDef(
      key: 'phone2',
      label: '备用电话',
      width: 120,
      value: (m) => m.phone2,
    ),
    MasterColumnDef(key: 'fax', label: '传真', width: 110, value: (m) => m.fax),
    MasterColumnDef(
      key: 'postcode',
      label: '邮编',
      width: 80,
      value: (m) => m.postcode,
    ),
    MasterColumnDef(
      key: 'address',
      label: '地址',
      width: 220,
      value: (m) => m.address,
    ),
    MasterColumnDef(
      key: 'bank',
      label: '开户银行',
      width: 160,
      value: (m) => m.bank,
    ),
    MasterColumnDef(
      key: 'bankAccount',
      label: '银行账号',
      width: 160,
      value: (m) => m.bankAccount,
    ),
    MasterColumnDef(
      key: 'taxId',
      label: '纳税号',
      width: 140,
      value: (m) => m.taxId,
    ),
    MasterColumnDef(
      key: 'credit',
      label: '信誉额度',
      width: 110,
      type: 'money',
      sortable: true,
      value: (m) => m.credit?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'website',
      label: '网址',
      width: 160,
      value: (m) => m.website,
    ),
  ];
}
