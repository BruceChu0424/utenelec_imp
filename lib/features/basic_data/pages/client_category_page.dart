import '../../../components/inputs/uten_table_cell_auto_width.dart';
// 客户资料分类树管理页（基础资料）
//
// 与 mould_category_page.dart（模具资料）/ product_category_page.dart（货品资料）同构：
// 顶层壳层（树加载/统一搜索/分类 CRUD/build 骨架）复用 CategoryPageShell，
// 右侧明细区复用 MasterEntityDetailPane(ADR-111：分页/筛选/排序/打印导出/启停/删除/
// 批量命令只有一份)，本页只声明文案/图标/权限/仓储闭包 + 客户领域差异：
// - 结账方式字典预取后再开新建弹窗；编辑走共享 showClientMasterEdit；
// - 负责人和可见人(单个 / 批量)、只读客户(对象范围外)的行与批量门；
// - 主档按 client:view 查看；分类按 client_category:view 独立显示，无权时使用主档全局列表。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/07-客户资料-新库与迁移.md。
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import '../widgets/client_ship_address_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/client_access_models.dart';
import '../models/client_node.dart';
import '../models/product_category_node.dart';
import '../models/reference_method_option.dart';
import '../repositories/client_category_repository.dart';
import '../repositories/client_repository.dart';
import '../repositories/reference_method_repository.dart';
import '../widgets/basic_data_l10n.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/client_access_batch_dialog.dart';
import '../widgets/client_access_panel.dart';
import '../widgets/client_master_edit.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_edit_owner.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_inline_create_fields.dart';
import '../repositories/currency_repository.dart';
import '../repositories/master_inline_edit_repository.dart';
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
  FormDraftDescriptor get shellCategoryDraftDescriptor =>
      FormDraftCatalog.clientCategory;
  @override
  String get shellCategoryViewPermission => Perm.clientCategoryView;

  /// 已有分类树时保持挂载（与货品资料页同款）：分类增删改/刷新不再整页白闪、
  /// 树的展开状态不丢——此前本页未开启，每次保存分类整棵树卸载重挂（2026-10-18）。
  @override
  bool get shellKeepTreeMounted => true;

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
  Future<ProductCategoryDetail> shellCreateCategory(CategoryEditResult r) => ref
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
  Future<CategoryPrefixAvailability> shellPrefixAvailability(
    String prefix, {
    String? categoryId,
  }) => ref
      .read(clientCategoryRepositoryProvider)
      .prefixAvailability(prefix, categoryId: categoryId);

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
  Future<ProductCategoryDetail> shellLoadCategoryDetail(String id) =>
      ref.read(clientCategoryRepositoryProvider).detail(id);

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
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.clientAddress,
    onResume: (parameters) async {
      final clientId = parameters['parentId'];
      if (clientId == null) throw StateError('草稿里缺少客户信息');
      final client = await ref.read(clientRepositoryProvider).detail(clientId);
      if (!context.mounted) return;
      if (!client.writable) throw StateError('当前客户已不能编辑');
      await showClientShipAddressSheet(
        context,
        ref,
        clientId: clientId,
        clientName: client.name ?? '客户',
      );
    },
    child: _buildClientDraftHost(context),
  );

  Widget _buildClientDraftHost(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.client,
    onResume: (parameters) =>
        _showClientCreate(draftCategoryId: parameters['categoryId']),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    return buildShell(
      context,
      searchPaneBuilder: (query) =>
          MasterEntityDetailPane<ClientListItem, ClientDetail>(
            key: ValueKey('global-search-$query-$_detailEpoch'),
            config: _paneConfig(),
            categoryId: shellSearchCategoryId,
            externalKeyword: query,
            externalSearchPending: shellSearchPending,
          ),
      detailPaneBuilder: (selected) =>
          MasterEntityDetailPane<ClientListItem, ClientDetail>(
            key: ValueKey('dp-${selected.id}-$_detailEpoch'),
            config: _paneConfig(),
            categoryId: selected.id,
            externalKeyword: shellTreeSearchKeyword,
            externalSearchPending: shellSearchPending,
          ),
    );
  }

  /// 客户明细区配置：列、仓储闭包、权限与客户特有动作(负责人/可见人)。
  MasterEntityPaneConfig<ClientListItem, ClientDetail> _paneConfig() {
    final perms = ref.read(currentPermissionsProvider);
    final canCreate = perms.contains(Perm.clientCreate);
    final canChangeStatus = perms.contains(Perm.clientStatus);
    final clients = ref.watch(clientRepositoryProvider);
    return MasterEntityPaneConfig<ClientListItem, ClientDetail>(
      noun: '客户', // TODO(l10n): 补 arb
      inlineCreation: (pane) => MasterInlineCreateConfig(
        namespace: 'clients.${pane.categoryId}',
        fields: masterInlineCreateFields(
          buildClientFields(
            const {},
            const [],
            l10n: basicDataL10n(context),
            financialWritable: perms.contains(Perm.clientFinance),
          ),
          excluded: {if (!canChangeStatus) 'status'},
          options: {
            'defaultSettlementMethodId': () async => [
              for (final value
                  in await ref
                      .read(referenceMethodRepositoryProvider)
                      .settlementMethods())
                MasterSelectOption(value: value.id, label: value.name),
            ],
            'defaultCurrencyId': () async => [
              for (final value
                  in await ref.read(currencyRepositoryProvider).dict())
                MasterSelectOption(
                  value: value.id,
                  label: value.name ?? value.code ?? value.id,
                ),
            ],
          },
        ),
        defaults: {'status': '使用', 'categoryId': pane.categoryId},
        canCreate: canCreate,
        onCreate: (_, values) async {
          await ref.read(clientRepositoryProvider).create({
            'status': '使用',
            ...values,
            'categoryId': pane.categoryId,
          });
        },
      ),
      icon: Icons.people_outline,
      defaultCodePrefix: 'KH',
      columns: _visibleClientColumns(basicDataL10n(context)),
      inlineFields:
          {
            'name': MasterInlineField<ClientListItem>(
              key: 'name',
              read: (row) => row.name,
              required: true,
            ),
            'fullName': MasterInlineField<ClientListItem>(
              key: 'fullName',
              read: (row) => row.fullName,
            ),
            'nameEn': MasterInlineField<ClientListItem>(
              key: 'nameEn',
              read: (row) => row.nameEn,
            ),
            'region': MasterInlineField<ClientListItem>(
              key: 'region',
              read: (row) => row.region,
            ),
            'placeId': MasterInlineField<ClientListItem>(
              key: 'placeId',
              read: (row) => row.placeId,
            ),
            'legalPerson': MasterInlineField<ClientListItem>(
              key: 'legalPerson',
              read: (row) => row.legalPerson,
            ),
            'linkman': MasterInlineField<ClientListItem>(
              key: 'linkman',
              read: (row) => row.linkman,
              required: true,
            ),
            'mobile': MasterInlineField<ClientListItem>(
              key: 'mobile',
              read: (row) => row.mobile,
            ),
            'phone': MasterInlineField<ClientListItem>(
              key: 'phone',
              read: (row) => row.phone,
            ),
            'phone2': MasterInlineField<ClientListItem>(
              key: 'phone2',
              read: (row) => row.phone2,
            ),
            'fax': MasterInlineField<ClientListItem>(
              key: 'fax',
              read: (row) => row.fax,
            ),
            'postcode': MasterInlineField<ClientListItem>(
              key: 'postcode',
              read: (row) => row.postcode,
            ),
            'address': MasterInlineField<ClientListItem>(
              key: 'address',
              read: (row) => row.address,
            ),
            'bank': MasterInlineField<ClientListItem>(
              key: 'bank',
              read: (row) => row.bank,
            ),
            'bankAccount': MasterInlineField<ClientListItem>(
              key: 'bankAccount',
              read: (row) => row.bankAccount,
            ),
            'taxId': MasterInlineField<ClientListItem>(
              key: 'taxId',
              read: (row) => row.taxId,
            ),
            'website': MasterInlineField<ClientListItem>(
              key: 'website',
              read: (row) => row.website,
            ),
            'tday': MasterInlineField<ClientListItem>(
              key: 'tday',
              read: (row) => row.tday,
              type: MasterFieldType.integer,
              validate: (value) => value is int && value < 0 ? '天数不能为负数' : null,
            ),
            'creditFloor': MasterInlineField<ClientListItem>(
              key: 'creditFloor',
              read: (row) => row.creditFloor,
              type: MasterFieldType.money,
            ),
            'defaultSettlementMethodName': MasterInlineField<ClientListItem>(
              key: 'defaultSettlementMethodId',
              read: (row) => row.defaultSettlementMethodId,
              type: MasterFieldType.custom,
              cellBuilder: (context, row, field) => MasterInlineOptionsCell(
                field: field,
                currentLabel: row.defaultSettlementMethodName,
                load: () async => [
                  for (final method
                      in await ref
                          .read(referenceMethodRepositoryProvider)
                          .settlementMethods())
                    MasterSelectOption(value: method.id, label: method.name),
                ],
              ),
            ),
          }..removeWhere(
            (key, field) =>
                clientFinancialFieldKeys.contains(field.key) &&
                !perms.contains(Perm.clientFinance),
          ),
      onInlineSave: (id, patch, original) {
        final boundary = ref.read(sensitiveReadBoundaryProvider);
        return ref
            .read(masterInlineEditRepositoryProvider)
            .saveParty(
              'clients',
              id,
              patch,
              expectedVersion: original.version,
              isCurrent: () =>
                  mounted &&
                  ref.read(sensitiveReadBoundaryProvider) == boundary,
            );
      },

      idOf: (c) => c.id,
      statusOf: (c) => c.status,
      versionOf: (c) => c.version,
      labelOf: (c) => c.name?.isNotEmpty == true ? c.name! : (c.code ?? '该客户'),
      writableOf: (c) => c.writable,
      readOnlyRowHint: (_) => '该客户对你只读，不能修改', // TODO(l10n): 补 arb
      loadCategory: (id) =>
          ref.read(clientCategoryRepositoryProvider).detail(id),
      loadPage: (q) => q.categoryId == null
          ? clients.listGlobal(
              page: q.page,
              size: q.size ?? 20,
              keyword: q.keyword,
              filters: q.filters,
              sort: q.sort,
              order: q.order,
            )
          : clients.list(
              q.categoryId!,
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
      loadGlobalFacets: () async {
        final f = await clients.globalFacets();
        return MasterPaneFacets(fields: f.fields, nullCounts: f.nullCounts);
      },
      batchEntityPath: ApiEndpoints.clients,
      statusResourceOf: ApiEndpoints.client,
      canCreate: canCreate,
      canEdit: perms.contains(Perm.clientEdit),
      canDelete: perms.contains(Perm.clientDelete),
      canStatus: canChangeStatus,
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
        if (perms.contains(Perm.clientFinance))
          UtenMenuItem(
            label: '维护财务资料',
            icon: Icons.account_balance_outlined,
            enabled: c.financialWritable,
            onTap: () => pane.withDetail(
              c.id,
              (detail) => showClientMasterEdit(
                context,
                ref,
                detail,
                onSaved: () => pane.reload(),
              ),
            ),
          ),
        UtenMenuItem(
          label: '负责人和可见人', // TODO(l10n): 补 arb
          icon: Icons.manage_accounts_outlined,
          enabled: perms.contains(Perm.clientAssign) && c.accessManageable,
          onTap: () => _showClientAccess(pane, c),
        ),
      ],
      extraBatchMenuItems: (pane, ids) {
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
        // 归属批量菜单(批量设负责人 / 批量设可见人)。两者分开是因为语义不同：
        // 负责人是「归谁」，可见人是「额外给谁看」，混在一个弹窗里容易误把可见人清空。
        return [
          UtenMenuItem(
            label: '批量设负责人 (${assignable.length})', // TODO(l10n): 补 arb
            icon: Icons.person_outline_rounded,
            enabled: !pane.busy,
            onTap: () => _batchSetClientAccess(pane, assignable, owner: true),
          ),
          UtenMenuItem(
            label: '批量设可见人 (${assignable.length})', // TODO(l10n): 补 arb
            icon: Icons.visibility_outlined,
            enabled: !pane.busy,
            onTap: () => _batchSetClientAccess(pane, assignable, owner: false),
          ),
        ];
      },
    );
  }

  // ---- 客户 新建 -----------------------------------------------------------

  Future<void> _showClientCreate({String? draftCategoryId}) async {
    final current = shellCaptureActionOwner();
    final settlementMethods =
        ref.read(currentPermissionsProvider).contains(Perm.clientFinance)
        ? await loadClientSettlementMethods(context, ref)
        : const <ReferenceMethodOption>[];
    if (!mounted || !current() || settlementMethods == null) return;
    const iv = <String, String>{};
    final categoryId = draftCategoryId ?? _pane?.categoryId;
    await showMasterEditDialog(
      context: context,
      draftSpec: FormDraftCatalog.client.spec(
        title: '新增客户',
        categoryId: categoryId,
      ),
      title: '新增客户', // TODO(l10n): 补 arb
      fields: buildClientFields(
        iv,
        settlementMethods,
        l10n: basicDataL10n(context),
        financialWritable: ref
            .read(currentPermissionsProvider)
            .contains(Perm.clientFinance),
      ),
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
    // Preserve the actual API failure for the shared draft submission fence.
    final current = shellCaptureActionOwner();
    await ref.read(clientRepositoryProvider).create(body);
    if (mounted && current()) {
      context.appSuccess('客户已创建');
      await _pane?.reload();
    }
    return true;
  }

  // ---- 客户特有动作：详情整页 / 负责人与可见人 --------------------------------

  /// 双击客户行(2026-09-14)：进客户详情整页 /basicinfo/client/:id，返回时刷新列表。
  Future<void> _showClientDetail(
    MasterEntityPaneController<ClientListItem, ClientDetail> pane,
    String id,
  ) async {
    final current = shellCaptureActionOwner();
    await context.push(RoutePath.basicinfoClientDetail(id));
    if (mounted && current()) await pane.reload();
  }

  Future<void> _showClientAccess(
    MasterEntityPaneController<ClientListItem, ClientDetail> pane,
    ClientListItem row,
  ) async {
    // Bind to the actual rendered pane rather than a previously selected category.
    // Access assignment has its own capability and may be allowed on an unassigned
    // customer whose ordinary master fields are still read-only.
    final paneState = pane is State ? pane as State : null;
    if (!mounted ||
        paneState == null ||
        !paneState.mounted ||
        pane.busy ||
        !row.accessManageable ||
        !ref.read(currentPermissionsProvider).contains(Perm.clientAssign)) {
      return;
    }
    final repository = ref.read(clientRepositoryProvider);
    final saved = await pane.runExclusive(
      () => showClientAccessPanel(
        context: paneState.context,
        ref: ref,
        clientId: row.id,
        clientName: row.name ?? row.code ?? '客户',
        loader: repository.access,
        saver: repository.updateAccess,
      ),
    );
    if (saved != null && mounted && paneState.mounted) await pane.reload();
  }

  Widget _clientOwnerCell(BuildContext cellContext, ClientListItem row) {
    final labelStyle = Theme.of(cellContext).textTheme.bodyMedium;
    if (!row.accessManageable ||
        !ref.read(currentPermissionsProvider).contains(Perm.clientAssign)) {
      return Text(
        row.ownersLabel,
        style: labelStyle,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Tooltip(
      message: '设置负责人和可见人',
      child: TextButton(
        key: ValueKey('client-owner-access-${row.id}'),
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () async {
          if (!cellContext.mounted) return;
          final paneState = cellContext
              .findAncestorStateOfType<
                State<MasterEntityDetailPane<ClientListItem, ClientDetail>>
              >();
          if (paneState
              is MasterEntityPaneController<ClientListItem, ClientDetail>) {
            await _showClientAccess(
              paneState
                  as MasterEntityPaneController<ClientListItem, ClientDetail>,
              row,
            );
          }
        },
        child: Row(
          children: [
            Expanded(
              child: Text(
                row.ownersLabel,
                style: labelStyle?.copyWith(
                  color: Theme.of(cellContext).colorScheme.primary,
                ),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.manage_accounts_outlined, size: 16),
          ],
        ),
      ),
    );
  }

  /// 多选客户批量设负责人/可见人：一个端点一个事务，任一客户被拒则整批不生效
  /// (半批生效比不生效更难收拾)。未设置的那一维服务端保持各客户原值。
  Future<void> _batchSetClientAccess(
    MasterEntityPaneController<ClientListItem, ClientDetail> pane,
    Set<String> ids, {
    required bool owner,
  }) async {
    if (pane.busy || ids.isEmpty) return;
    final clientIds = ids.toList(growable: false);
    final submission = MasterEditOwner(
      context,
      ref,
      permissions: {Perm.clientView, Perm.clientAssign},
    );
    try {
      if (!await submission.bindRequests() ||
          !mounted ||
          !submission.isCurrent) {
        return;
      }
      final result = await showClientAccessBatchDialog(
        context: context,
        ref: ref,
        clientCount: clientIds.length,
        assignOwner: owner,
        submissionOwner: submission,
      );
      if (result == null || !mounted || !submission.isCurrent) return;
      final ok = await pane.runExclusive(() async {
        try {
          await submission.run(
            () => ref
                .read(clientRepositoryProvider)
                .updateAccessBatch(
                  ClientAccessBatchUpdate(
                    clientIds: clientIds,
                    ownerEmployeeIds: owner ? result.employeeIds : null,
                    viewerEmployeeIds: owner ? null : result.employeeIds,
                    reason: result.reason,
                  ),
                ),
          );
          if (!mounted || !submission.isCurrent) return false;
          context.appSuccess(owner ? '已批量设置负责人' : '已批量设置可见人');
          return true;
        } on ApiException catch (error) {
          if (mounted && submission.isCurrent) context.appError(error.message);
          return false;
        } catch (_) {
          if (mounted && submission.isCurrent) context.appError('批量设置失败，请稍后重试');
          return false;
        }
      });
      if (ok == true && mounted && submission.isCurrent) await pane.reload();
    } finally {
      submission.dispose();
    }
  }

  // ---- 客户列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// Columns shown in the table: the static list plus 外文名称 (ADR-134),
  /// whose label comes from arb and therefore needs a context.
  List<MasterColumnDef<ClientListItem>> _visibleClientColumns(
    AppLocalizations l10n,
  ) => [
    for (final c in _clientColumns) ...[
      if (c.key == 'ownerEmployeeName')
        MasterColumnDef<ClientListItem>(
          key: c.key,
          label: c.label,
          width: c.width,
          value: c.value,
          minimumWidthOf: (_) => 48,
          measureWidthScope: (
            'client.ownerAccess.v1',
            ref.read(currentPermissionsProvider).contains(Perm.clientAssign),
          ),
          measureWidthOf: (context, row, scaler) =>
              utenTableCellTextWidth(
                row.ownersLabel,
                style:
                    Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
                textScaler: scaler,
                textDirection: Directionality.of(context),
              ) +
              (ref.read(currentPermissionsProvider).contains(Perm.clientAssign)
                  ? 20
                  : 0),
          cellBuilder: _clientOwnerCell,
          cellBuilderHandlesSemantics: true,
        )
      else
        c,
      // ADR-134: 外文名称 right after the full name; the label comes from arb.
      if (c.key == 'fullName')
        MasterColumnDef<ClientListItem>(
          key: 'nameEn',
          label: l10n.clientNameEnLabel,
          width: 200,
          info: l10n.clientNameEnInfo,
          value: (m) => m.nameEn,
        ),
    ],
  ];

  /// 客户表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=初始参考宽度，实际沿用公共内容量宽、
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
      columnSearchEnabled: false,
      width: 90,
      value: (m) => m.clientXz,
    ),
    MasterColumnDef(
      key: 'tday',
      label: '信用天数',
      width: 80,
      type: 'number',
      columnSearchEnabled: true,
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
      value: (m) => m.ownersLabel,
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
      columnSearchEnabled: true,
      info: '旧库信用额度快照，按本列两位显示值检索；不是实时应收或可用额度。',
      sortable: true,
      exactValueOf: (m) => m.creditDisplayText ?? m.credit?.toStringAsFixed(2),
      value: (m) => m.creditDisplayText ?? m.credit?.toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'creditFloor',
      label: '铺底额',
      width: 110,
      type: 'money',
      columnSearchEnabled: true,
      info: '按本列两位铺底额检索；跨币种不相加。',
      sortable: true,
      exactValueOf: (m) =>
          m.creditFloorDisplayText ?? (m.creditFloor ?? 0).toStringAsFixed(2),
      value: (m) =>
          m.creditFloorDisplayText ?? (m.creditFloor ?? 0).toStringAsFixed(2),
    ),
    MasterColumnDef(
      key: 'website',
      label: '网址',
      width: 160,
      value: (m) => m.website,
    ),
  ];
}
