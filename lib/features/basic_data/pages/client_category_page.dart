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
import 'package:go_router/go_router.dart';

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
import '../../../core/router/route_names.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/client_access_models.dart';
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
import '../widgets/client_access_batch_dialog.dart';
import '../widgets/client_access_panel.dart';
import '../widgets/client_master_edit.dart';
import '../widgets/master_edit_dialog.dart';
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
    // 负责人列（ownerEmployeeName）在服务端的筛选参数是 ownerEmployeeId（桶值=员工 UUID）。
    final paramKey = key == 'ownerEmployeeName' ? 'ownerEmployeeId' : key;
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(paramKey); // 选"所有"= 不筛
      } else {
        next[paramKey] = value; // 具体值 或 kMasterFilterNullValue（空值）
      }
      _filters = next;
    });
    _loadClients(1); // 任一筛选变化回到第 1 页
  }

  /// 表头筛选桶/空值计数：服务端 empId 桶（值=负责人 UUID、label=人名）remap 到
  /// 负责人列 key ownerEmployeeName（表格按列 key 索引 facets）。
  Map<String, List<MasterFacetBucket>> get _columnFacets {
    final fields = Map<String, List<MasterFacetBucket>>.from(
      _facets?.fields ?? const {},
    );
    final owner = fields.remove('empId');
    if (owner != null) fields['ownerEmployeeName'] = owner;
    return fields;
  }

  Map<String, int> get _columnNullCounts {
    final counts = Map<String, int>.from(_facets?.nullCounts ?? const {});
    final ownerNull = counts.remove('empId');
    if (ownerNull != null) counts['ownerEmployeeName'] = ownerNull;
    return counts;
  }

  /// 表头筛选回显：把 _filters（服务端参数名）映射回列 key 供表格选中态索引。
  Map<String, String?> get _columnFilters => {
    for (final e in _filters.entries)
      (e.key == 'ownerEmployeeId' ? 'ownerEmployeeName' : e.key): e.value,
  };

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
  /// 导出请求体里的敏感检索值 (搜索关键字与手机/电话/银行账号只走请求体，不进 URL)。
  Map<String, dynamic> get _exportBody {
    final sensitive = contactSensitiveFilterBody(_filters, keyword: _keyword);
    return sensitive.isEmpty ? const {} : {'sensitiveFilter': sensitive};
  }

  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    'categoryId': widget.nodeId,
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
  // 2026-09-14：字段表抽取到 client_master_edit.dart（分类页与详情整页共用）。
  List<MasterFieldDef> _clientFields(
    Map<String, String> iv,
    List<ReferenceMethodOption> settlementMethods, {
    bool legacyCreditSnapshot = false,
    bool showAccess = false,
  }) => buildClientFields(
    iv,
    settlementMethods,
    legacyCreditSnapshot: legacyCreditSnapshot,
    showAccess: showAccess,
  );

  bool get _canCreateMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientCreate);
  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientEdit);
  bool get _canDeleteMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientDelete);
  bool get _canStatusMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientStatus);
  bool get _canAssignClientAccess =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.clientAssign);

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

  // 2026-09-14：编辑流程抽取到 showClientMasterEdit（详情整页共用）。
  Future<void> _showClientEdit(ClientDetail d) async {
    await showClientMasterEdit(
      context,
      widget.ref,
      d,
      fallbackCategoryId: widget.nodeId,
      onSaved: () => _loadClients(_clientPageNum),
    );
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

  /// 双击客户行（2026-09-14）：从弹窗改为客户详情整页 /basicinfo/client/:id——
  /// 页宽自适应多列展示 + 联系方式/地址/跟进记录子表管理；返回时刷新列表。
  Future<void> _showClientDetail(String id) async {
    await context.push(RoutePath.basicinfoClientDetail(id));
    if (mounted) await _loadClients(_clientPageNum);
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
                '编号前缀 ${d.effectivePrefix ?? 'KH'}${d.codePrefix == null ? '(继承)' : ''}'
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
                      hint: '搜索客户(简称/编码/全称/联系人/手机)', // TODO(l10n): 补 arb
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
                    exportBody: _exportBody,
                    exportFilename: '客户资料',
                    type: UtenButtonType.primary,
                    size: UtenButtonSize.large,
                  ),
                  UtenExportButton(
                    endpoint: '/master/clients/export',
                    requiredPermission: Perm.clientExport,
                    report: '',
                    queryParams: _exportQuery,
                    bodyParams: _exportBody,
                    filename: '客户资料',
                    label: '导出客户',
                    type: UtenButtonType.primary,
                    size: UtenButtonSize.large,
                  ),
                ],
                facets: _columnFacets,
                nullCounts: _columnNullCounts,
                filters: _columnFilters,
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
        label: '负责人和可见人',
        icon: Icons.manage_accounts_outlined,
        enabled: _canAssignClientAccess && c.accessManageable,
        onTap: () => _withClientDetail(c.id, _showClientAccess),
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
    if (!_canStatusMaster && !_canDeleteMaster && !_canAssignClientAccess) {
      return const [];
    }
    final byId = {
      for (final item in _clientPage?.items ?? const <ClientListItem>[])
        item.id: item,
    };
    // 归属批量的可操作性看 accessManageable（服务端已合并 client:assign 与对象范围），
    // 与「只读数据」是两条独立的门：只读客户照样可以换负责人。
    final assignable = ids
        .where((id) => byId[id]?.accessManageable == true)
        .toSet();
    final includesReadOnly = ids.any((id) => byId[id]?.writable != true);
    if (includesReadOnly) {
      return [
        if (_canAssignClientAccess && assignable.isNotEmpty)
          ..._accessBatchButtons(assignable),
        const Text('所选客户包含只读数据，请取消只读客户后再批量改资料'),
      ];
    }
    return [
      if (_canAssignClientAccess && assignable.isNotEmpty)
        ..._accessBatchButtons(assignable),
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

  /// 归属批量按钮（批量设负责人 / 批量设可见人）。两者分开是因为语义不同：
  /// 负责人是「归谁」，可见人是「额外给谁看」，混在一个弹窗里容易误把可见人清空。
  List<Widget> _accessBatchButtons(Set<String> ids) => [
    UtenButton(
      key: const ValueKey('client-batch-set-owner'),
      size: UtenButtonSize.small,
      type: UtenButtonType.tonal,
      icon: Icons.person_outline_rounded,
      onPressed: _rowOpBusy
          ? null
          : () => _batchSetClientAccess(ids, owner: true),
      child: Text('批量设负责人 (${ids.length})'), // TODO(l10n): 补 arb
    ),
    UtenButton(
      key: const ValueKey('client-batch-set-viewers'),
      size: UtenButtonSize.small,
      type: UtenButtonType.tonal,
      icon: Icons.visibility_outlined,
      onPressed: _rowOpBusy
          ? null
          : () => _batchSetClientAccess(ids, owner: false),
      child: Text('批量设可见人 (${ids.length})'), // TODO(l10n): 补 arb
    ),
  ];

  /// 多选客户批量设负责人/可见人：一个端点一个事务，任一客户被拒则整批不生效
  /// （半批生效比不生效更难收拾）。未设置的那一维服务端保持各客户原值。
  Future<void> _batchSetClientAccess(
    Set<String> ids, {
    required bool owner,
  }) async {
    if (_rowOpBusy || ids.isEmpty) return;
    final result = await showClientAccessBatchDialog(
      context: context,
      ref: widget.ref,
      clientCount: ids.length,
      assignOwner: owner,
    );
    if (result == null || !mounted) return;
    _rowOpBusy = true;
    final ok = await context.guardRun(
      () async {
        await widget.ref
            .read(clientRepositoryProvider)
            .updateAccessBatch(
              ClientAccessBatchUpdate(
                clientIds: ids.toList(growable: false),
                ownerEmployeeId: owner ? result.employeeIds.first : null,
                viewerEmployeeIds: owner ? null : result.employeeIds,
                reason: result.reason,
              ),
            );
      },
      success: owner ? '已批量设置负责人' : '已批量设置可见人', // TODO(l10n): 补 arb
      errorFallback: '批量设置失败，请稍后重试', // TODO(l10n): 补 arb
    );
    _rowOpBusy = false;
    if (!ok || !mounted) return;
    await _loadClients(_clientPageNum);
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
      // 2026-09-14：老库未匹配到员工的行 owner 为空——显示未分配而不是裸数字 ID。
      value: (m) => (m.ownerEmployeeName?.trim().isNotEmpty ?? false)
          ? m.ownerEmployeeName
          : '未分配',
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
      label: '信用额度 / 旧库 Credit 快照',
      width: 110,
      type: 'money',
      sortable: true,
      value: (m) => m.credit?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'creditFloor',
      label: '铺底额',
      width: 110,
      type: 'money',
      value: (m) => (m.creditFloor ?? 0).toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'website',
      label: '网址',
      width: 160,
      value: (m) => m.website,
    ),
  ];
}
