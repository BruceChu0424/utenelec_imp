// 客户资料分类树管理页（基础资料）
//
// 与 mould_category_page.dart（模具资料）/ product_category_page.dart（货品资料）同构：
// 顶层壳层（树加载/统一搜索/分类 CRUD/build 骨架）复用 CategoryPageShell，
// 右侧明细区复用 MasterEntityDetailPane(ADR-111：分页/筛选/排序/打印导出/启停/删除/
// 批量命令只有一份)，本页只声明文案/图标/权限/仓储闭包 + 客户领域差异：
// - 结账方式字典预取后再开新建弹窗；编辑走共享 showClientMasterEdit；
// - 负责人和可见人(单个 / 批量)、只读客户(对象范围外)的行与批量门；
// - 编辑类按钮按 client_category:* / client:* 权限显隐；查看全员可见(路由不设守卫)。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/07-客户资料-新库与迁移.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/client_access_models.dart';
import '../models/client_node.dart';
import '../models/product_category_node.dart';
import '../models/reference_method_option.dart';
import '../repositories/client_category_repository.dart';
import '../repositories/client_repository.dart';
import '../repositories/reference_method_repository.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/client_access_batch_dialog.dart';
import '../widgets/client_access_panel.dart';
import '../widgets/client_master_edit.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_entity_detail_pane.dart';

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

  /// 当前挂着的右栏明细区(新建/编辑保存后经它重拉列表)。
  MasterEntityPaneController<ClientListItem, ClientDetail>? _pane;

  @override
  Widget build(BuildContext context) {
    return buildShell(
      context,
      detailPaneBuilder: (selected) =>
          MasterEntityDetailPane<ClientListItem, ClientDetail>(
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

  /// 客户明细区配置：列、仓储闭包、权限与客户特有动作(负责人/可见人)。
  MasterEntityPaneConfig<ClientListItem, ClientDetail> _paneConfig() {
    final perms = ref.read(currentPermissionsProvider);
    final clients = ref.read(clientRepositoryProvider);
    return MasterEntityPaneConfig<ClientListItem, ClientDetail>(
      noun: '客户', // TODO(l10n): 补 arb
      icon: Icons.people_outline,
      defaultCodePrefix: 'KH',
      keyPrefix: 'client',
      searchHint: '搜索客户(简称/编码/全称/联系人/手机)', // TODO(l10n): 补 arb
      columns: _clientColumns,
      idOf: (c) => c.id,
      statusOf: (c) => c.status,
      versionOf: (c) => c.version,
      labelOf: (c) => c.name?.isNotEmpty == true ? c.name! : (c.code ?? '该客户'),
      writableOf: (c) => c.writable,
      readOnlyRowHint: (_) => '该客户对你只读，不能修改', // TODO(l10n): 补 arb
      readOnlyBatchHint: '所选客户包含只读数据，请取消只读客户后再批量改资料', // TODO(l10n): 补 arb
      loadCategory: (id) =>
          ref.read(clientCategoryRepositoryProvider).detail(id),
      loadPage: (q) => clients.list(
        q.categoryId,
        page: q.page,
        size: q.size ?? 20,
        keyword: q.keyword,
        filters: q.filters,
        sort: q.sort,
        order: q.order,
      ),
      loadFacets: (id) async {
        final f = await clients.facets(id);
        return MasterPaneFacets(fields: f.fields, nullCounts: f.nullCounts);
      },
      batchEntityPath: ApiEndpoints.clients,
      statusResourceOf: ApiEndpoints.client,
      canCreate: perms.contains(Perm.clientCreate),
      canEdit: perms.contains(Perm.clientEdit),
      canDelete: perms.contains(Perm.clientDelete),
      canStatus: perms.contains(Perm.clientStatus),
      // 负责人列在服务端的 facet 字段是 empId(值=员工 UUID、label=人名)，
      // 筛选参数是 ownerEmployeeId；表格按列 key ownerEmployeeName 索引。
      columnOfFacetField: const {'empId': 'ownerEmployeeName'},
      filterParamOfColumn: const {'ownerEmployeeName': 'ownerEmployeeId'},
      export: const MasterPaneExport(
        title: '客户资料', // TODO(l10n): 补 arb
        endpoint: '/master/clients/export',
        permission: Perm.clientExport,
        label: '导出客户', // TODO(l10n): 补 arb
        contactSensitiveInBody: true,
      ),
      onCreate: (pane) {
        _pane = pane;
        return _showClientCreate();
      },
      onOpen: (pane, c) => _showClientDetail(pane, c.id),
      loadDetail: clients.detail,
      onEdit: (pane, d) => showClientMasterEdit(
        context,
        ref,
        d,
        fallbackCategoryId: pane.categoryId,
        onSaved: () => pane.reload(),
      ),
      detailReadOnlyHint: (d) => d.writable
          ? null
          : '当前访问：${d.accessReasonLabel}，${d.readOnlyActionHint}',
      extraMenuItems: (pane, c) => [
        UtenMenuItem(
          label: '负责人和可见人', // TODO(l10n): 补 arb
          icon: Icons.manage_accounts_outlined,
          enabled: perms.contains(Perm.clientAssign) && c.accessManageable,
          onTap: () => pane.withDetail(c.id, (d) => _showClientAccess(pane, d)),
        ),
      ],
      extraBatchActions: (pane, ids) {
        if (!perms.contains(Perm.clientAssign)) return const [];
        // 归属批量看 accessManageable(服务端已合并 client:assign 与对象范围)，
        // 与「只读数据」是两条独立的门：只读客户照样可以换负责人。
        final byId = {
          for (final item in pane.page?.items ?? const <ClientListItem>[])
            item.id: item,
        };
        final assignable = ids
            .where((id) => byId[id]?.accessManageable == true)
            .toSet();
        if (assignable.isEmpty) return const [];
        return _accessBatchButtons(pane, assignable);
      },
    );
  }

  // ---- 客户 新建 -----------------------------------------------------------

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
      final methods = await ref
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

  Future<void> _showClientCreate() async {
    final settlementMethods = await _loadSettlementMethods();
    if (!mounted || settlementMethods == null) return;
    const iv = <String, String>{};
    final categoryId = _pane?.categoryId;
    showMasterEditDialog(
      context: context,
      title: '新增客户', // TODO(l10n): 补 arb
      fields: buildClientFields(iv, settlementMethods),
      initialValues: const {'status': '使用'},
      fixedValues: {'categoryId': ?categoryId},
      readOnlyKeys:
          ref.read(currentPermissionsProvider).contains(Perm.clientStatus)
          ? null
          : const {'status'},
      onSubmit: _doCreateClient,
    );
  }

  Future<bool> _doCreateClient(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref.read(clientRepositoryProvider).create(body);
      },
      success: '客户已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _pane?.reload();
    return true;
  }

  // ---- 客户特有动作：详情整页 / 负责人与可见人 --------------------------------

  /// 双击客户行(2026-09-14)：进客户详情整页 /basicinfo/client/:id，返回时刷新列表。
  Future<void> _showClientDetail(
    MasterEntityPaneController<ClientListItem, ClientDetail> pane,
    String id,
  ) async {
    await context.push(RoutePath.basicinfoClientDetail(id));
    if (mounted) await pane.reload();
  }

  Future<void> _showClientAccess(
    MasterEntityPaneController<ClientListItem, ClientDetail> pane,
    ClientDetail detail,
  ) async {
    final repository = ref.read(clientRepositoryProvider);
    final saved = await showClientAccessPanel(
      context: context,
      ref: ref,
      clientId: detail.id,
      clientName: detail.name ?? detail.code ?? '客户',
      loader: repository.access,
      saver: repository.updateAccess,
    );
    if (saved != null && mounted) await pane.reload();
  }

  /// 归属批量按钮(批量设负责人 / 批量设可见人)。两者分开是因为语义不同：
  /// 负责人是「归谁」，可见人是「额外给谁看」，混在一个弹窗里容易误把可见人清空。
  List<Widget> _accessBatchButtons(
    MasterEntityPaneController<ClientListItem, ClientDetail> pane,
    Set<String> ids,
  ) => [
    UtenButton(
      key: const ValueKey('client-batch-set-owner'),
      size: UtenButtonSize.small,
      type: UtenButtonType.tonal,
      icon: Icons.person_outline_rounded,
      onPressed: pane.busy
          ? null
          : () => _batchSetClientAccess(pane, ids, owner: true),
      child: Text('批量设负责人 (${ids.length})'), // TODO(l10n): 补 arb
    ),
    UtenButton(
      key: const ValueKey('client-batch-set-viewers'),
      size: UtenButtonSize.small,
      type: UtenButtonType.tonal,
      icon: Icons.visibility_outlined,
      onPressed: pane.busy
          ? null
          : () => _batchSetClientAccess(pane, ids, owner: false),
      child: Text('批量设可见人 (${ids.length})'), // TODO(l10n): 补 arb
    ),
  ];

  /// 多选客户批量设负责人/可见人：一个端点一个事务，任一客户被拒则整批不生效
  /// (半批生效比不生效更难收拾)。未设置的那一维服务端保持各客户原值。
  Future<void> _batchSetClientAccess(
    MasterEntityPaneController<ClientListItem, ClientDetail> pane,
    Set<String> ids, {
    required bool owner,
  }) async {
    if (pane.busy || ids.isEmpty) return;
    final result = await showClientAccessBatchDialog(
      context: context,
      ref: ref,
      clientCount: ids.length,
      assignOwner: owner,
    );
    if (result == null || !mounted) return;
    final ok = await pane.runExclusive(
      () => context.guardRun(
        () async {
          await ref
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
      ),
    );
    if (ok == true && mounted) await pane.reload();
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
