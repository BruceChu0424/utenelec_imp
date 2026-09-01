// 供应商资料分类树管理页（基础资料）
//
// 顶层壳层（树加载/统一搜索/分类 CRUD/build 骨架）复用 CategoryPageShell，
// 本页只声明文案/图标/权限/仓储钩子 + 供应商领域差异：
// - 详情面板调 supplierCategoryRepository.detail + supplierRepository 分类下分页（动态筛选）；
// - 表格走通用 MasterDataTableView（搜索 + 横排 autofilter 筛选 + 列对齐 + 分页）；
// - 字段 facet 走 /facets（19 个有数据列，主结账方式/损耗率无对应列不参与 facet）；
// - 编辑类按钮按 supplier_category:edit / supplier:edit 权限显隐；查看全员可见；
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/09-供应商资料-新库与迁移.md。
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
import '../../../components/inputs/uten_employee_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/department_employee_picker.dart';
import '../models/master_facet.dart';
import '../models/product_category_node.dart';
import '../models/reference_method_option.dart';
import '../models/supplier_node.dart';
import '../repositories/reference_method_repository.dart';
import '../repositories/supplier_category_repository.dart';
import '../repositories/supplier_repository.dart';
import '../repositories/master_status_repository.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/system_master_category_guard.dart';

class SupplierCategoryPage extends ConsumerStatefulWidget {
  const SupplierCategoryPage({super.key});

  @override
  ConsumerState<SupplierCategoryPage> createState() =>
      _SupplierCategoryPageState();
}

class _SupplierCategoryPageState extends ConsumerState<SupplierCategoryPage>
    with CategoryPageShell<SupplierCategoryPage> {
  @override
  String get shellTitle => '供应商资料'; // TODO(l10n): 补 arb

  @override
  String get shellSearchHint => '搜索分类/供应商名称或编号'; // TODO(l10n): 补 arb

  @override
  String get shellContentNoun => '供应商';

  @override
  IconData get shellEmptyIcon => Icons.local_shipping_outlined;

  @override
  String get shellPersistenceKey => 'basicData.supplier';

  @override
  bool get shellCanCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.supplierCategoryCreate);

  @override
  bool get shellCanEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.supplierCategoryEdit);

  @override
  bool get shellCanDelete => ref
      .read(currentPermissionsProvider)
      .contains(Perm.supplierCategoryDelete);

  @override
  bool get shellCanMove =>
      ref.read(currentPermissionsProvider).contains(Perm.supplierCategoryMove);

  @override
  bool get shellCanReorder => ref
      .read(currentPermissionsProvider)
      .contains(Perm.supplierCategoryReorder);

  @override
  Future<List<ProductCategoryNode>> shellLoadTree() =>
      ref.read(supplierCategoryRepositoryProvider).tree();

  @override
  Future<void> shellCreateCategory(CategoryEditResult r) => ref
      .read(supplierCategoryRepositoryProvider)
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
      .read(supplierCategoryRepositoryProvider)
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
      ref.read(supplierCategoryRepositoryProvider).delete(id);

  @override
  Future<CategoryPrefixPreview> shellPrefixPreview(
    String id,
    String prefix,
    String? parentId,
  ) => ref
      .read(supplierCategoryRepositoryProvider)
      .prefixPreview(id, prefix, parentId: parentId);

  @override
  Future<Set<String>?> shellContentCategoryIds(
    String q,
    bool Function() isCurrent,
  ) async {
    final repository = ref.read(supplierRepositoryProvider);
    return collectPagedHierarchyCategoryIds<SupplierListItem>(
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
  /// 否则分类卡片仍显示旧名称/前缀，且前缀变更后供应商编号已变、列表也需重拉。
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

/// 供应商分类详情面板：分类信息卡 + 该分类（子树）下的供应商 Excel 表格（搜索+筛选+分页）。
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

  /// 顶部树搜索命中供应商时传入的过滤词：详情面板把它采纳为本地供应商列表的搜索词，
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

  // 该分类（子树）下的供应商分页；父分类也加载（子树汇总）。
  PagedResult<SupplierListItem>? _supplierPage;
  int _supplierPageNum = 1;
  bool _supplierLoading = false;
  String? _supplierError;

  // 字段筛选 + 搜索 + facet（筛选栏用）。切换分类时重置。
  Map<String, String?> _filters = {};
  String _keyword = '';
  SupplierFacets? _facets;

  // 搜索框重建种子：外部关键词（树搜索）变化时自增，驱动 UtenSearchBar 用新 initialValue 重建。
  int _kwSeed = 0;

  // 列排序态（金额/数量/日期列）：null = 默认顺序（id ASC）。
  String? _sortKey;
  bool _sortAsc = true;

  /// 详情弹窗加载中（防并发）。
  /// 注意：与 [_supplierLoading]（供应商分页列表的加载状态）是两回事，不可混用——
  /// 列表加载完后 [_supplierLoading] 恒为 false，无法防止详情弹窗被并发触发。
  bool _detailLoading = false;

  /// 多选选中集（业务 id，跨页保留；批量禁用/删除用）。切换分类时清空。
  Set<String> _selectedSupplierIds = {};

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
      _loadSuppliers(1);
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
          .read(supplierCategoryRepositoryProvider)
          .detail(widget.nodeId);
      if (!mounted || !_detailRequests.isCurrent(generation)) return;
      setState(() {
        _detail = d;
        _loading = false;
        // 切换分类时重置供应商分页 + 筛选状态 + facet + 排序态。
        _supplierPage = null;
        _supplierPageNum = 1;
        _supplierError = null;
        _filters = {};
        // 外部搜索词（树搜索命中）随分类切换一并带入：搜索定位时右侧只显示搜索结果。
        _keyword = widget.externalKeyword ?? '';
        _kwSeed++;
        _facets = null;
        _sortKey = null;
        _sortAsc = true;
        _selectedSupplierIds = {}; // 切分类清空多选（选中的是旧分类的行）
      });
      // 父分类也加载（后端按子树汇总）；并行拉供应商列表与字段 facet。
      await Future.wait([_loadSuppliers(1), _loadFacets()]);
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

  // ---- 供应商分页 --------------------------------------------------------

  Future<void> _loadSuppliers(int page) async {
    final generation = _listRequests.begin();
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
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _supplierPage = result;
      });
    } on ApiException catch (e) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _supplierError = e.message;
      });
    } catch (_) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _supplierError = '加载供应商列表失败'; // TODO(l10n): 补 arb
      });
    } finally {
      if (mounted && _listRequests.isCurrent(generation)) {
        setState(() => _supplierLoading = false);
      }
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
  List<MasterFieldDef> _supplierFields(
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
      MasterFieldDef(key: 'description', label: '描述/全称', group: '基础'),
      MasterFieldDef(key: 'place', label: '地区', group: '地址'),
    ],
    MasterFieldDef(
      key: 'ownerEmployeeId',
      label: '业务员',
      type: MasterFieldType.custom,
      group: '资质',
      customBuilder: (ctx) => DepartmentEmployeePickerField(
        label: '业务员',
        hint: '选择在职员工',
        initialId: ctx.initialValue,
        initialName: iv['ownerEmployeeName'],
        initialLoader: (employeeId) async {
          final employee = await widget.ref
              .read(employeeRepositoryProvider)
              .getById(employeeId);
          return UtenEmployeePickerItem(
            id: employee.id,
            name: employee.fullName ?? '',
            employeeCode: employee.code,
            departmentName: employee.departmentName,
          );
        },
        onChanged: ctx.onChanged,
        onPick: () => showUtenDepartmentEmployeePicker(
          context,
          widget.ref,
          title: '选择业务员',
        ),
      ),
    ),
    ...const <MasterFieldDef>[
      MasterFieldDef(key: 'legalPerson', label: '法人', group: '资质'),
      MasterFieldDef(key: 'linkman', label: '联系人', group: '联系'),
      MasterFieldDef(key: 'mobile', label: '手机', required: true, group: '联系'),
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
    ],
    MasterFieldDef(
      key: 'defaultSettlementMethodId',
      label: '默认结算方式',
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
      hint: '采购/委外订货开单时预填结账方式；不影响既有单据与应付',
    ),
    ...const <MasterFieldDef>[
      MasterFieldDef(
        key: 'status',
        label: '状态',
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        required: true,
        group: '基础',
      ),
      MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
    ],
  ];

  bool get _canCreateMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.supplierCreate);
  bool get _canEditMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.supplierEdit);
  bool get _canDeleteMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.supplierDelete);
  bool get _canStatusMaster =>
      widget.ref.read(currentPermissionsProvider).contains(Perm.supplierStatus);

  // ---- 供应商 新建/编辑/删除 ----------------------------------------------

  bool _settlementOptionsLoading = false;

  /// 加载启用中的结算方式（新建/编辑表单「默认结算方式」下拉用；范式同客户页）。
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
        if (mounted) context.appError('暂无可用结算方式，请先维护结算方式字典');
        return null;
      }
      return methods;
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载结算方式失败，请重试');
    } finally {
      if (nav.canPop()) nav.pop();
      _settlementOptionsLoading = false;
    }
    return null;
  }

  Future<void> _showSupplierCreate() async {
    final settlementMethods = await _loadSettlementMethods();
    if (!mounted || settlementMethods == null) return;
    const iv = <String, String>{};
    showMasterEditDialog(
      context: context,
      title: '新增供应商', // TODO(l10n): 补 arb
      fields: _supplierFields(iv, settlementMethods),
      initialValues: const {'status': '使用'},
      fixedValues: {'categoryId': widget.nodeId},
      readOnlyKeys: _canStatusMaster ? null : const {'status'},
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

  Future<void> _showSupplierEdit(SupplierDetail d) async {
    final settlementMethods = await _loadSettlementMethods();
    if (!mounted || settlementMethods == null) return;
    if (d.defaultSettlementMethodId != null &&
        !settlementMethods.any(
          (method) => method.id == d.defaultSettlementMethodId,
        )) {
      context.appError('当前默认结算方式已不可用，请先修复供应商结算方式关联');
      return;
    }
    final iv = <String, String>{
      'name': d.name ?? '',
      'code': d.code ?? '',
      'description': d.description ?? '',
      'place': d.place ?? '',
      'ownerEmployeeId': d.ownerEmployeeId ?? '',
      'ownerEmployeeName': d.ownerEmployeeName ?? d.empId ?? '',
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
      'defaultSettlementMethodId': d.defaultSettlementMethodId ?? '',
      'status': d.status ?? '',
      'remark': d.remark ?? '',
    };
    showMasterEditDialog(
      context: context,
      title: '编辑供应商', // TODO(l10n): 补 arb
      fields: _supplierFields(iv, settlementMethods),
      initialValues: iv,
      fixedValues: {
        'categoryId': d.categoryId ?? widget.nodeId,
        if (d.version != null) 'version': d.version,
      },
      readOnlyKeys: _canStatusMaster ? null : const {'status'},
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

  // ---- 行菜单（右击/长按）+ 多选批量 --------------------------------------

  /// 启用/禁用供应商：列表行不带状态字段 → 拉详情判定后翻转，全量回传仅改状态。
  Future<void> _toggleSupplierStatus(SupplierListItem s) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    SupplierDetail? d;
    try {
      d = await widget.ref.read(supplierRepositoryProvider).detail(s.id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载供应商详情失败'); // TODO(l10n): 补 arb
    }
    if (d == null || !mounted) {
      _rowOpBusy = false;
      return;
    }
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => widget.ref
          .read(masterStatusRepositoryProvider)
          .change(
            resourcePath: ApiEndpoints.supplier(d!.id),
            status: next,
            version: d.version,
          ),
      success: next == '禁用' ? '供应商已禁用' : '供应商已启用', // TODO(l10n): 补 arb
    );
    if (ok && mounted) await _loadSuppliers(_supplierPageNum);
    _rowOpBusy = false;
  }

  /// 菜单「编辑/删除」：先拉详情再走既有流程。
  Future<void> _withSupplierDetail(
    String id,
    Future<void> Function(SupplierDetail d) action,
  ) async {
    if (_rowOpBusy) return;
    _rowOpBusy = true;
    SupplierDetail? d;
    try {
      d = await widget.ref.read(supplierRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载供应商详情失败'); // TODO(l10n): 补 arb
    }
    _rowOpBusy = false;
    if (d != null && mounted) await action(d);
  }

  /// 行菜单条目（右击/长按弹出）。可用性按权限实时决定。
  /// 列表行不带状态字段，启停项用「启用/禁用」合并入口（点进去按详情翻转）。
  List<UtenContextMenuEntry> _supplierMenuItems(SupplierListItem s) {
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _showSupplierDetail(s.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '启用/禁用供应商',
        icon: Icons.power_settings_new_rounded,
        enabled: _canStatusMaster,
        onTap: () => _toggleSupplierStatus(s),
      ),
      UtenMenuItem(
        label: '编辑供应商',
        icon: Icons.edit_outlined,
        enabled: _canEditMaster,
        onTap: () =>
            _withSupplierDetail(s.id, (d) async => _showSupplierEdit(d)),
      ),
      UtenMenuItem(
        label: '删除供应商',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canDeleteMaster,
        onTap: () => _withSupplierDetail(s.id, _deleteSupplier),
      ),
    ];
  }

  List<Widget> _supplierBatchActions(BuildContext context, Set<String> ids) {
    if (!_canStatusMaster && !_canDeleteMaster) return const [];
    return [
      if (_canStatusMaster)
        UtenButton(
          size: UtenButtonSize.small,
          type: UtenButtonType.tonal,
          icon: Icons.pause_circle_outline_rounded,
          onPressed: _rowOpBusy
              ? null
              : () => _batchSetSupplierStatus(ids, '禁用'),
          child: const Text('批量禁用'), // TODO(l10n): 补 arb
        ),
      if (_canDeleteMaster)
        UtenButton(
          size: UtenButtonSize.small,
          type: UtenButtonType.danger,
          icon: Icons.delete_outline_rounded,
          onPressed: _rowOpBusy ? null : () => _batchDeleteSuppliers(ids),
          child: const Text('批量删除'), // TODO(l10n): 补 arb
        ),
    ];
  }

  /// 批量启停：逐条拉详情全量回传、仅改状态（无专用批量接口，复用单条更新）。
  Future<void> _batchSetSupplierStatus(Set<String> ids, String status) async {
    if (_rowOpBusy || ids.isEmpty) return;
    _rowOpBusy = true;
    final repo = widget.ref.read(supplierRepositoryProvider);
    var okCount = 0;
    var skipped = 0;
    for (final id in ids) {
      try {
        final d = await repo.detail(id);
        if (d.status == status) {
          skipped++;
          continue;
        }
        await widget.ref
            .read(masterStatusRepositoryProvider)
            .change(
              resourcePath: ApiEndpoints.supplier(id),
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
    setState(() => _selectedSupplierIds = {});
    context.appSuccess(
      status == '禁用'
          ? '已禁用 $okCount 个供应商${skipped > 0 ? '，$skipped 个跳过' : ''}'
          : '已启用 $okCount 个供应商${skipped > 0 ? '，$skipped 个跳过' : ''}',
    );
    await _loadSuppliers(_supplierPageNum);
  }

  /// 批量删除：确认后逐个删（容忍单条失败，如被单据引用）。
  Future<void> _batchDeleteSuppliers(Set<String> ids) async {
    if (_rowOpBusy || ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除供应商'), // TODO(l10n): 补 arb
        content: Text('确定删除选中的 ${ids.length} 个供应商吗？被单据引用的供应商会删除失败。'),
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
    final repo = widget.ref.read(supplierRepositoryProvider);
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
    setState(() => _selectedSupplierIds = {});
    context.appSuccess(
      '已删除 $okCount 个供应商${failed.isNotEmpty ? '，${ids.length - okCount} 个失败' : ''}',
    );
    if (failed.isNotEmpty) context.appError(failed.first);
    await _loadSuppliers(_supplierPageNum);
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
      canDelete: _canDeleteMaster,
      onToggleStatus: _canStatusMaster
          ? () async {
              final next = detail.status == '使用' ? '禁用' : '使用';
              final ok = await context.guardRun(
                () => widget.ref
                    .read(masterStatusRepositoryProvider)
                    .change(
                      resourcePath: ApiEndpoints.supplier(detail.id),
                      status: next,
                      version: detail.version,
                    ),
                success: next == '禁用' ? '已停用' : '已启用',
              );
              if (ok && mounted) await _loadSuppliers(_supplierPageNum);
            }
          : null,
      statusActionLabel: detail.status == '使用' ? '停用' : '启用',
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
    MasterDetailRow('业务员', d.ownerEmployeeName ?? d.empId), // TODO(l10n): 补 arb
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
    MasterDetailRow('默认结算方式', d.defaultSettlementMethodName), // TODO(l10n): 补 arb
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
    final total = _supplierPage?.total ?? 0;
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
            icon: Icons.local_shipping_outlined,
            subtitle:
                '编号前缀 ${d.effectivePrefix ?? 'GY'}${d.codePrefix == null ? '(继承)' : ''}'
                '${d.remark?.isNotEmpty == true ? ' · ${d.remark}' : ''} · 层级 L${d.level}',
            // 详情卡精简（与货品/客户/模具/收付方式分类卡统一）：不再展示统计行
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
        // body：供应商标题 + 搜索 + 添加按钮（卡片收起后吸顶）+ 表格（内滚）。
        body: Column(
          children: [
            // 供应商标题 + 搜索 + 添加按钮（与原布局一致：添加在搜索右侧）
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
                      // key 含 nodeId + _kwSeed：切分类 / 树搜索写入关键词时重建搜索框同步显示。
                      key: ValueKey(
                        'supplier-search-${widget.nodeId}-$_kwSeed',
                      ),
                      hint: '搜索供应商(简称/全称/联系人/法人/地区/手机)', // TODO(l10n): 补 arb
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
                      onPressed: _showSupplierCreate,
                      child: const Text('添加供应商'), // TODO(l10n): 补 arb
                    ),
                  ],
                ],
              ),
            ),
            // 表格（搜索 + 横排 autofilter 筛选 + 逐行数据 + 分页，一体；Excel 风格）。
            // primary:true → 表体参与「卡片折叠 → 表格内滚」联动（拾取 NestedScrollView inner controller）。
            Expanded(
              child: MasterDataTableView<SupplierListItem>(
                primary: true,
                columns: _supplierColumns,
                items: _supplierPage?.items ?? const [],
                // 多选：最前列勾选框 + 表头三态全选；选中非空时工具条出批量操作区。
                selectable: true,
                idOf: (s) => s.id,
                selectedIds: _selectedSupplierIds,
                onSelectedIdsChanged: (s) =>
                    setState(() => _selectedSupplierIds = s),
                batchActionsBuilder: _supplierBatchActions,
                // 行菜单（右击/长按）：查看/启用禁用/编辑/删除。
                rowMenuBuilder: _supplierMenuItems,
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
