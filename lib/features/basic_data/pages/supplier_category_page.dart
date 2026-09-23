// 供应商资料分类树管理页（基础资料）
//
// 顶层壳层（树加载/统一搜索/分类 CRUD/build 骨架）复用 CategoryPageShell，
// 本页只声明文案/图标/权限/仓储钩子 + 供应商领域差异：
// - 右侧明细区复用 MasterEntityDetailPane(ADR-111)，本页给 supplierRepository 分类下分页闭包；
// - 表格走通用 MasterDataTableView（搜索 + 横排 autofilter 筛选 + 列对齐 + 分页）；
// - 字段 facet 走 /facets（19 个有数据列，主结账方式/损耗率无对应列不参与 facet）；
// - 编辑类按钮按 supplier_category:edit / supplier:edit 权限显隐；查看全员可见；
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/09-供应商资料-新库与迁移.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/product_category_node.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_category_repository.dart';
import '../repositories/supplier_repository.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_entity_detail_pane.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/supplier_master_edit.dart';
import '../widgets/category_tree_search.dart';

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
      detailPaneBuilder: (selected) =>
          MasterEntityDetailPane<SupplierListItem, SupplierDetail>(
            key: ValueKey('dp-${selected.id}-$_detailEpoch'),
            config: _paneConfig(),
            categoryId: selected.id,
            canEditCategory: shellCanEdit,
            canAddCategory: shellCanCreate,
            canDeleteCategory: shellCanDelete,
            externalKeyword: shellTreeSearchKeyword,
            onAddChild: () => shellShowCreateDialog(parent: selected),
            onEditCategory: (detail) => shellShowEditDialog(detail),
            onDeleteCategory: () => shellDeleteNode(selected),
          ),
    );
  }

  /// 供应商明细区配置：列、仓储闭包、权限；新建/编辑走共享 supplier_master_edit。
  MasterEntityPaneConfig<SupplierListItem, SupplierDetail> _paneConfig() {
    final perms = ref.read(currentPermissionsProvider);
    final suppliers = ref.read(supplierRepositoryProvider);
    return MasterEntityPaneConfig<SupplierListItem, SupplierDetail>(
      noun: '供应商', // TODO(l10n): 补 arb
      icon: Icons.local_shipping_outlined,
      defaultCodePrefix: 'GY',
      keyPrefix: 'supplier',
      searchHint: '搜索供应商(简称/全称/联系人/法人/地区/手机)', // TODO(l10n): 补 arb
      columns: _supplierColumns,
      idOf: (s) => s.id,
      statusOf: (s) => s.status,
      versionOf: (s) => s.version,
      labelOf: (s) => s.name?.isNotEmpty == true ? s.name! : '该供应商',
      loadCategory: (id) =>
          ref.read(supplierCategoryRepositoryProvider).detail(id),
      loadPage: (q) => suppliers.list(
        q.categoryId,
        page: q.page,
        size: q.size ?? 20,
        keyword: q.keyword,
        filters: q.filters,
        sort: q.sort,
        order: q.order,
      ),
      loadFacets: (id) async {
        final f = await suppliers.facets(id);
        return MasterPaneFacets(fields: f.fields, nullCounts: f.nullCounts);
      },
      batchEntityPath: ApiEndpoints.suppliers,
      statusResourceOf: ApiEndpoints.supplier,
      canCreate: perms.contains(Perm.supplierCreate),
      canEdit: perms.contains(Perm.supplierEdit),
      canDelete: perms.contains(Perm.supplierDelete),
      canStatus: perms.contains(Perm.supplierStatus),
      // 业务员列在服务端的 facet 字段是 empId(值=员工 UUID、label=人名)，
      // 筛选参数是 ownerEmployeeId；表格按列 key ownerEmployeeName 索引。
      columnOfFacetField: const {'empId': 'ownerEmployeeName'},
      filterParamOfColumn: const {'ownerEmployeeName': 'ownerEmployeeId'},
      export: const MasterPaneExport(
        title: '供应商资料', // TODO(l10n): 补 arb
        endpoint: '/master/suppliers/export',
        permission: Perm.supplierExport,
        label: '导出供应商', // TODO(l10n): 补 arb
      ),
      onCreate: _showSupplierCreate,
      onOpen: (pane, s) => _showSupplierDetail(pane, s.id),
      loadDetail: suppliers.detail,
      onEdit: (pane, d) => showSupplierMasterEdit(
        context,
        ref,
        d,
        fallbackCategoryId: pane.categoryId,
        onSaved: () => pane.reload(),
      ),
    );
  }

  /// 新建供应商：先加载启用中的结算方式(范式同客户页)，再开表单。
  Future<void> _showSupplierCreate(
    MasterEntityPaneController<SupplierListItem, SupplierDetail> pane,
  ) async {
    final settlementMethods = await loadSupplierSettlementMethods(context, ref);
    if (!mounted || settlementMethods == null) return;
    const iv = <String, String>{};
    showMasterEditDialog(
      context: context,
      title: '新增供应商', // TODO(l10n): 补 arb
      fields: buildSupplierFields(context, iv, settlementMethods, ref),
      initialValues: const {'status': '使用'},
      fixedValues: {'categoryId': pane.categoryId},
      readOnlyKeys:
          ref.read(currentPermissionsProvider).contains(Perm.supplierStatus)
          ? null
          : const {'status'},
      onSubmit: (body) async {
        final ok = await context.guardRun(
          () async {
            await ref.read(supplierRepositoryProvider).create(body);
          },
          success: '供应商已创建', // TODO(l10n): 补 arb
          errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
        );
        if (ok) await pane.reload();
        return ok;
      },
    );
  }

  /// 双击供应商行(2026-09-14)：进供应商详情整页 /basicinfo/supplier/:id，返回时刷新。
  Future<void> _showSupplierDetail(
    MasterEntityPaneController<SupplierListItem, SupplierDetail> pane,
    String id,
  ) async {
    await context.push(RoutePath.basicinfoSupplierDetail(id));
    if (mounted) await pane.reload();
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
      type: 'number',
      // ADR-098：已结清委外订货行的加权损耗率（服务端汇总视图）；没有结清行显示「—」。
      // 仍不可筛（不是 suppliers 物理列，不进 facets）。
      value: (s) => s.lossRate?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'place',
      label: '所属地区',
      width: 110,
      value: (s) => s.place,
    ),
    MasterColumnDef(
      key: 'ownerEmployeeName',
      label: '业务员',
      width: 110,
      // 2026-09-14：后端补 ownerEmployeeName；未匹配显示未分配而不是裸数字 ID。
      value: (s) => (s.ownerEmployeeName?.trim().isNotEmpty ?? false)
          ? s.ownerEmployeeName
          : '未分配',
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
