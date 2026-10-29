import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
// 结算方式管理页（基础资料 · 扁平字典 + 账期策略维护，V453）。
//
// 结算方式是销售/采购/委外结账条件与应付到期日的 UUID 权威字典（ADR-035/047）。
// 本页只做两件事：分页查看（含禁用行、系统角色、账期口径）和维护账期策略与
// 可选改名（settlement_method:edit）；系统角色（CASH/MONTHLY）口径由迁移锁定，
// 页面置灰并提示。新增仍走 settlement_method:create（可随带账期）。
// 停用/删除不在此页开放：活动客户/供应商默认与单据引用受 DB 守卫保护。
//
// 2026-09-16 列表表格化：卡片列表改为 MasterDataTableView（横排 autofilter 列头），
// 状态/系统角色/到期基准/到期规则四列接后端 facets（settlement-admin/facets），
// 表头筛选和名称/编号关键词在同一服务端谓词下分页；导出保留完整筛选条件。
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import 'package:collection/collection.dart';
import '../../../components/print/complete_print_snapshot.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../models/master_facet.dart';
import '../models/settlement_method_admin.dart';
import '../repositories/reference_method_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_inline_page_mixin.dart';
import '../widgets/master_operation_history_panel.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_record_history_panel.dart';

class SettlementMethodPage extends ConsumerStatefulWidget {
  const SettlementMethodPage({super.key});

  @override
  ConsumerState<SettlementMethodPage> createState() =>
      _SettlementMethodPageState();
}

class _SettlementMethodPageState extends ConsumerState<SettlementMethodPage>
    with
        MasterInlinePageMixin<SettlementMethodPage, SettlementMethodAdminItem>,
        ScopedPagedReadViewMixin<SettlementMethodPage> {
  final _readViewportRows =
      MasterDataTableRowsController<SettlementMethodAdminItem>();
  int get _visibleReadPage => _page == null
      ? (_pageNum)
      : (_readViewportRows.visiblePage ?? (_pageNum));

  @override
  void scopedPagedReadOwnerChanged() {
    if (mounted) {
      setState(() {
        inlineClearView();
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  @override
  String get inlineEntityType => 'reference-methods';
  @override
  bool get inlineCanEdit => _canEdit;
  @override
  bool get inlineReadReady => _page != null && !_loading && _error == null;
  @override
  String inlineIdOf(SettlementMethodAdminItem row) => row.id;
  @override
  Future<void> inlineReload() => _load();
  @override
  Future<void> inlineReloadAfterBoundary() => _refresh();
  @override
  void inlineClearView() {
    _items = null;
    _page = null;
    _pageNum = 1;
    _facets = null;
    _error = null;
    _selectedMethodIds = {};
  }

  @override
  Map<String, MasterInlineField<SettlementMethodAdminItem>> get inlineFields =>
      {
        'name': MasterInlineField(
          key: 'name',
          read: (row) => row.name,
          required: true,
          enabledOf: (row) => !row.lockedBySystemRole,
        ),
        'termsBase': MasterInlineField(
          key: 'termsBase',
          read: (row) => row.termsBase,
          type: MasterFieldType.select,
          required: true,
          options: [
            for (final value in settlementTermsBaseLabels.entries)
              MasterSelectOption(value: value.key, label: value.value),
          ],
          enabledOf: (row) => !row.lockedBySystemRole,
        ),
        'dueRule': MasterInlineField(
          key: 'dueRule',
          read: (row) => row.dueRule,
          type: MasterFieldType.select,
          required: true,
          options: [
            for (final value in settlementDueRuleLabels.entries)
              MasterSelectOption(value: value.key, label: value.value),
          ],
          enabledOf: (row) => !row.lockedBySystemRole,
        ),
        'defaultDueDays': MasterInlineField(
          key: 'defaultDueDays',
          read: (row) => row.defaultDueDays,
          type: MasterFieldType.integer,
          required: true,
          enabledOf: (row) => !row.lockedBySystemRole,
        ),
        'fixedDayOfMonth': MasterInlineField(
          key: 'fixedDayOfMonth',
          read: (row) => row.fixedDayOfMonth,
          type: MasterFieldType.integer,
          enabledOf: (row) => !row.lockedBySystemRole,
        ),
        'monthsAhead': MasterInlineField(
          key: 'monthsAhead',
          read: (row) => row.monthsAhead,
          type: MasterFieldType.integer,
          required: true,
          enabledOf: (row) => !row.lockedBySystemRole,
        ),
      };
  List<SettlementMethodAdminItem>? _items;
  PagedResult<SettlementMethodAdminItem>? _page;
  int _pageNum = 1;
  Set<String> _selectedMethodIds = {};
  bool _loading = false;
  String? _error;
  String _keyword = '';
  final _loadRequests = LatestRequestGuard();

  /// 表头筛选（字段→原始值；空值哨兵见 master_facet.dart）。落到服务端查询。
  Map<String, String?> _filters = {};
  SettlementMethodFacets? _facets;

  bool get _canCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.settlementMethodCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.settlementMethodEdit);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadFacets();
    });
  }

  Future<void> _load([int? requestedPage, bool useCache = false]) async {
    final targetPage = requestedPage ?? _visibleReadPage;
    final inlineReadBoundary = captureInlineRead();
    final epoch = ref.read(exportContextEpochProvider);
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      if (targetPage != _pageNum) _selectedMethodIds = {};
      _pageNum = targetPage;
    });
    final page = targetPage;
    final repository = ref.read(referenceMethodRepositoryProvider);
    final keyword = _keyword;
    final filters = Map<String, String?>.unmodifiable(_filters);
    Object pagingQuery() => [
      ref.read(referenceMethodRepositoryProvider),
      _keyword,
      _filters,
    ];
    try {
      final result = await readScopedPage<SettlementMethodAdminItem>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        fetchPage: (target) => repository.settlementAdminPage(
          page: target,
          keyword: keyword,
          filters: filters,
        ),
      );
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_loadRequests.isCurrent(generation) ||
          epoch != ref.read(exportContextEpochProvider)) {
        return;
      }
      setState(() {
        _page = result;
        _pageNum = result.page;
        _items = result.items;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_loadRequests.isCurrent(generation) ||
          epoch != ref.read(exportContextEpochProvider)) {
        return;
      }
      setState(() {
        if (e.httpStatus == 401 ||
            e.httpStatus == 403 ||
            e.code == 'READ_SCOPE_CHANGED') {
          _items = null;
          _page = null;
          _selectedMethodIds = {};
        }
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_loadRequests.isCurrent(generation) ||
          epoch != ref.read(exportContextEpochProvider)) {
        return;
      }
      setState(() {
        _error = '加载结算方式失败';
        _loading = false;
      });
    }
  }

  /// 拉字段 facet（表头筛选下拉选项）。失败静默降级为空下拉，不阻塞列表。
  Future<void> _loadFacets() async {
    final inlineReadBoundary = captureInlineRead();
    try {
      final f = await ref
          .read(referenceMethodRepositoryProvider)
          .settlementAdminFacets();
      if (!mounted || !inlineAcceptsRead(inlineReadBoundary)) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      _selectedMethodIds = {};
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      _filters = next;
      _pageNum = 1;
    });
    _load();
  }

  Future<void> _refresh({int? page}) async {
    await Future.wait([_load(page ?? 1), _loadFacets()]);
  }

  List<SettlementMethodAdminItem> get _filtered => _items ?? const [];

  // ---- 新增（可随带账期） ------------------------------------------------

  Future<void> _showCreate() async {
    if (!_canCreate) return;
    await showMasterEditDialog(
      context: context,
      draftSpec: FormDraftCatalog.settlement.spec(title: '新增结算方式'),
      title: '新增结算方式', // TODO(l10n): 补 arb
      fields: _termsFields(),
      initialValues: const {
        'termsBase': 'RECEIPT_DATE',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': '0',
        'monthsAhead': '0',
      },
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    final name = (body['name'] as String?)?.trim() ?? '';
    await ref
        .read(referenceMethodRepositoryProvider)
        .createSettlement(name, terms: _termsOf(body));
    if (mounted) {
      context.appSuccess('结算方式已创建');
      await _refresh();
    }
    return true;
  }

  @override
  MasterInlineCreateConfig get inlineCreation => MasterInlineCreateConfig(
    namespace: 'settlement-methods',
    fields: _termsFields(),
    defaults: const {
      'termsBase': 'RECEIPT_DATE',
      'dueRule': 'NET_DAYS',
      'defaultDueDays': '0',
      'monthsAhead': '0',
    },
    canCreate: _canCreate,
    onCreate: (_, values) async {
      await ref
          .read(referenceMethodRepositoryProvider)
          .createSettlement(
            values['name']?.toString().trim() ?? '',
            terms: _termsOf(values),
          );
    },
  );

  // ---- 账期维护 ----------------------------------------------------------

  void _showEditTerms(SettlementMethodAdminItem m) {
    if (_page == null || _error != null) return;
    final readToken = captureInlineRead();
    final fields = _termsFields(hintName: m.name, includePresentation: true);
    final body = _SettlementTermsDialog(
      item: m,
      isCurrent: () => inlineAcceptsRead(readToken),
      fields: fields,
      initialValues: {
        'code': m.code ?? '',
        'name': m.name,
        'termsBase': m.termsBase,
        'dueRule': m.dueRule,
        'defaultDueDays': m.defaultDueDays.toString(),
        'fixedDayOfMonth': m.fixedDayOfMonth?.toString() ?? '',
        'monthsAhead': m.monthsAhead.toString(),
        'status': m.status ?? '',
        'systemRole': settlementSystemRoleLabel(m.systemRole),
        'termsSummary': settlementTermsSummary(m),
        'remark': m.remark ?? '',
      },
      onSubmit: (body) => _doUpdateTerms(m, body, readToken),
      onHistoryChanged: _refresh,
    );
    if (context.breakpoint.isCompact) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(UtenRadius.lg),
          ),
        ),
        builder: (context) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: body,
        ),
      );
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => UtenDialogFrame(
        shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: (MediaQuery.sizeOf(context).width * 0.92).clamp(
              560.0,
              900.0,
            ),
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: body,
        ),
      ),
    );
  }

  Future<bool> _doUpdateTerms(
    SettlementMethodAdminItem m,
    Map<String, dynamic> body,
    MasterInlineReadToken token,
  ) async {
    if (!mounted || !inlineAcceptsRead(token)) return false;
    if (m.lockedBySystemRole || !_canEdit) {
      context.appInfo('当前结算方式不可编辑');
      return false;
    }
    final ok = await context.guardRun(
      () async {
        await runSensitiveWrite(
          ref,
          isCurrent: () => mounted && inlineAcceptsRead(token) && _canEdit,
          write: () => ref
              .read(referenceMethodRepositoryProvider)
              .updateSettlementTerms(m.id, body),
        );
      },
      success: '账期已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok || !mounted || !inlineAcceptsRead(token)) return false;
    await _refresh();
    return true;
  }

  /// 组装提交用的账期策略体（新建套 terms 键；编辑直接平铺——两端各自与后端
  /// DTO 对齐）。固定日仅在 FIXED_DAY_OF_MONTH 时上送，其余规则强制 null。
  Map<String, dynamic> _termsOf(Map<String, dynamic> body) {
    final rule = body['dueRule'] as String?;
    final fixedDay = body['fixedDayOfMonth'];
    return {
      'name': body['name'],
      'termsBase': body['termsBase'],
      'dueRule': rule,
      'defaultDueDays': body['defaultDueDays'],
      'fixedDayOfMonth': rule == 'FIXED_DAY_OF_MONTH' ? fixedDay : null,
      'monthsAhead': body['monthsAhead'],
    };
  }

  // ---- 字段定义 ----------------------------------------------------------

  List<MasterFieldDef> _termsFields({
    String? hintName,
    bool includePresentation = false,
  }) => [
    const MasterFieldDef(
      key: 'code',
      label: '编号',
      group: '基础',
      readOnly: true,
      hint: '保存后自动生成',
    ),
    MasterFieldDef(
      key: 'name',
      label: '名称',
      required: true,
      group: '基础',
      hint: hintName,
    ),
    MasterFieldDef(
      key: 'termsBase',
      label: '到期基准',
      type: MasterFieldType.select,
      required: true,
      options: [
        for (final entry in settlementTermsBaseLabels.entries)
          MasterSelectOption(value: entry.key, label: entry.value),
      ],
      group: '账期',
      hint: '质检验收/对账确认/发票基准开放前，到期日保持未定并阻断月结冻结',
    ),
    MasterFieldDef(
      key: 'dueRule',
      label: '到期规则',
      type: MasterFieldType.select,
      required: true,
      options: [
        for (final entry in settlementDueRuleLabels.entries)
          MasterSelectOption(value: entry.key, label: entry.value),
      ],
      group: '账期',
    ),
    const MasterFieldDef(
      key: 'defaultDueDays',
      label: '默认天数',
      type: MasterFieldType.integer,
      required: true,
      group: '账期',
      hint: '0-3650；供应商正数结算天数优先于该默认值',
    ),
    const MasterFieldDef(
      key: 'fixedDayOfMonth',
      label: '固定日',
      type: MasterFieldType.integer,
      group: '账期',
      hint: '1-31；仅「固定日」规则填写，其它规则留空',
    ),
    const MasterFieldDef(
      key: 'monthsAhead',
      label: '跨月数',
      type: MasterFieldType.integer,
      required: true,
      group: '账期',
      hint: '0-120；月末/固定日规则跨几个月后到期',
    ),
    if (includePresentation) ...[
      const MasterFieldDef(
        key: 'status',
        label: '状态',
        group: '资料',
        readOnly: true,
      ),
      const MasterFieldDef(
        key: 'systemRole',
        label: '系统角色',
        group: '资料',
        readOnly: true,
      ),
      const MasterFieldDef(
        key: 'termsSummary',
        label: '账期说明',
        group: '资料',
        readOnly: true,
      ),
      const MasterFieldDef(
        key: 'remark',
        label: '备注',
        group: '资料',
        readOnly: true,
      ),
    ],
  ];

  // ---- 导出 / 打印（V717 settlement_method:export） --------------------------

  /// Export describes the complete server query, independent of the viewed page.
  Map<String, dynamic> get _exportQuery => {
    ...masterFilterQueryParams(_filters),
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword,
  };

  /// 打印预览数据：按当前筛选口径拉全量，列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final read = captureInlineRead();
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final epoch = ref.read(exportContextEpochProvider);
    final repository = ref.read(referenceMethodRepositoryProvider);
    final query = Map<String, dynamic>.of(_exportQuery);
    final filters = Map<String, String?>.unmodifiable(_filters);
    final keyword = query['keyword'] as String?;
    final columns = List.of(_columns);
    var retired = false;
    bool current() {
      if (retired || !mounted) return false;
      retired =
          !inlineAcceptsRead(read) ||
          epoch != ref.read(exportContextEpochProvider) ||
          !const DeepCollectionEquality().equals(query, _exportQuery);
      return !retired;
    }

    final scope = await boundary.api.captureRequestScope(isCurrent: current);
    final table = await scope.run(
      () => loadCompletePrintSnapshot<SettlementMethodAdminItem>(
        loadPage: (page, size) => repository.settlementAdminPage(
          page: page,
          size: size,
          keyword: keyword,
          filters: filters,
        ),
        idOf: (row) => row.id,
        headers: [for (final column in columns) column.label],
        columnKeys: [for (final column in columns) column.key],
        cellsOf: (row) => [
          for (final column in columns) column.value(row) ?? '',
        ],
        isCurrent: () => current() && scope.isCurrent,
      ),
    );
    await scope.verify();
    return table;
  }

  // ---- 列定义 -----------------------------------------------------------

  static final _columns = <MasterColumnDef<SettlementMethodAdminItem>>[
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 72,
      value: (m) => m.status,
    ),
    MasterColumnDef(key: 'code', label: '编号', width: 110, value: (m) => m.code),
    MasterColumnDef(key: 'name', label: '名称', width: 170, value: (m) => m.name),
    MasterColumnDef(
      key: 'systemRole',
      label: '系统角色',
      width: 130,
      value: (m) =>
          m.lockedBySystemRole ? settlementSystemRoleLabel(m.systemRole) : null,
    ),
    MasterColumnDef(
      key: 'termsBase',
      label: '到期基准',
      width: 150,
      value: (m) => settlementTermsBaseLabel(m.termsBase),
    ),
    MasterColumnDef(
      key: 'dueRule',
      label: '到期规则',
      width: 140,
      value: (m) => settlementDueRuleLabel(m.dueRule),
    ),
    MasterColumnDef(
      key: 'defaultDueDays',
      label: '默认天数',
      width: 110,
      type: 'number',
      value: (row) => row.defaultDueDays.toString(),
    ),
    MasterColumnDef(
      key: 'fixedDayOfMonth',
      label: '固定日',
      width: 90,
      type: 'number',
      value: (row) => row.fixedDayOfMonth?.toString(),
    ),
    MasterColumnDef(
      key: 'monthsAhead',
      label: '跨月数',
      width: 90,
      type: 'number',
      value: (row) => row.monthsAhead.toString(),
    ),
    const MasterColumnDef(
      key: 'terms',
      label: '账期口径',
      width: 320,
      value: settlementTermsSummary,
    ),
  ];

  /// facet 桶加展示标签（下拉显示中文口径，筛选仍回传原始值）。
  Map<String, List<MasterFacetBucket>> get _labeledFacets {
    final source = _facets?.fields ?? const {};
    return {
      for (final entry in source.entries)
        entry.key: [
          for (final bucket in entry.value)
            MasterFacetBucket(
              value: bucket.value,
              count: bucket.count,
              label: switch (entry.key) {
                'systemRole' => settlementSystemRoleLabel(bucket.value),
                'termsBase' => settlementTermsBaseLabel(bucket.value),
                'dueRule' => settlementDueRuleLabel(bucket.value),
                _ => bucket.display,
              },
            ),
        ],
    };
  }

  // ---- 展示 --------------------------------------------------------------

  List<Widget> _settlementActions(BuildContext context, Set<String> ids) => [
    MasterInlineEditActions<SettlementMethodAdminItem>(
      controller: inlineEdit,
      canEdit: _canEdit && inlineReadReady,
      canCreate: _canCreate && inlineReadReady,
      onSave: saveInline,
      embedded: true,
      additionalActions: [
        if (_canCreate)
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.add_rounded,
            onPressed: () => inlineNavigate(_showCreate),
            child: const Text('添加结算方式'),
          ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.settlement,
    onResume: (_) => _showCreate(),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final items = _filtered;
    return inlineGuard(
      Scaffold(
        appBar: UtenAppBar(
          title: '结算方式',
          leading: UtenBackButton(
            onPressed: () => inlineNavigate(
              () => backTo(context, defaultPath: RouteName.basicinfo),
            ),
          ),
          actions: [
            MasterOperationHistoryActions(
              entityType: 'reference-methods',
              onChanged: _refresh,
            ),
            UtenRefreshButton(
              busy: _loading,
              onRefresh: () =>
                  inlineNavigate(() => _refresh(page: _visibleReadPage)),
            ),
          ],
        ),
        body: SafeArea(
          child: UtenContentContainer(
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Column(
                children: [
                  UtenPageEdgePadding(
                    padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4,
                    ),
                    child: UtenSearchBar(
                      hint: '搜索结算方式(名称/编号)',
                      initialValue: _keyword,
                      onInputChanged: (kw) {
                        if (inlineEdit.active) return;
                        _loadRequests.begin();
                        setState(() {
                          _keyword = kw;
                          _pageNum = 1;
                          _selectedMethodIds = {};
                          _loading = true;
                        });
                      },
                      onChanged: (kw) => inlineNavigate(() async {
                        setState(() {
                          _keyword = kw;
                          _selectedMethodIds = {};
                          _pageNum = 1;
                        });
                        await _load(1);
                      }),
                    ),
                  ),
                  Expanded(
                    child: MasterDataTableView<SettlementMethodAdminItem>(
                      rowsController: _readViewportRows,
                      expensiveRowMounts: inlineEdit.active,
                      appendRowsSource: inlineAppendRowsSource,
                      bottomContentPadding: (_canCreate || _canEdit)
                          ? UtenFloatingActionGroup.scrollClearance
                          : 0,
                      columnEditingEnabled: _canEdit,
                      tableKey:
                          'features.basic_data.pages.settlement_method_page.SettlementMethodPageState._buildDraftHost.1',
                      columns: inlineColumns(_columns),
                      requiredLeadingColumnKeys: const ['code', 'name'],
                      items: items,
                      selectable: true,
                      idOf: (method) => method.id,
                      selectedIds: _selectedMethodIds,
                      onSelectedIdsChanged: (ids) =>
                          setState(() => _selectedMethodIds = ids),
                      batchActionsBuilder: _settlementActions,
                      // 导出/打印（V717 settlement_method:export）：打印预览用本页列
                      // 渲染，导出列集服务端与表格对齐——「表格显示啥导出啥」。
                      // 导出/打印进左簇（2026-10-18 用户口径）：与「表头设置 / 全屏」同排靠左，
                      // 工具条右侧留给分页；按钮纯文字无 icon（工具条无 icon 口径）。
                      toolbarLeadingActions: [
                        UtenPrintPreviewButton(
                          title: '结算方式', // TODO(l10n): 补 arb
                          subtitle: '全部行', // TODO(l10n): 补 arb
                          loader: _printLoader,
                          exportEndpoint:
                              '/master/reference-methods/settlement-admin/export',
                          exportPermission: Perm.settlementMethodExport,
                          exportReport: '',
                          exportQuery: _exportQuery,
                          exportFilename: '结算方式', // TODO(l10n): 补 arb
                          type: UtenButtonType.primary,
                          size: UtenButtonSize.large,
                          icon: null,
                        ),
                        UtenExportButton(
                          endpoint:
                              '/master/reference-methods/settlement-admin/export',
                          requiredPermission: Perm.settlementMethodExport,
                          report: '',
                          queryParams: _exportQuery,
                          filename: '结算方式', // TODO(l10n): 补 arb
                          label: '导出结算方式', // TODO(l10n): 补 arb
                          type: UtenButtonType.primary,
                          size: UtenButtonSize.large,
                          icon: null,
                        ),
                      ],
                      facets: _labeledFacets,
                      nullCounts: _facets?.nullCounts ?? const {},
                      filters: _filters,
                      onFilterChanged: (key, value) =>
                          inlineNavigate(() => _onFilterChanged(key, value)),
                      // 行底色按状态（ADR-169 收编，同 color_page）：使用=蓝档
                      // 淡底（裸色收编）/ 禁用=灰档淡底（停用归中性终态，
                      // 原浅红把「停用」当异常——停用不是错误）。
                      rowColor: (m) => switch (m.status) {
                        '使用' => UtenColors.info.withValues(alpha: 0.13),
                        '禁用' => UtenColors.statusNeutral.withValues(
                          alpha: 0.10,
                        ),
                        _ => null,
                      },
                      // 点行 = 维护账期/查看口径（系统角色锁定时仅提示）。
                      onRowTap: inlineEdit.active ? null : _showEditTerms,
                      isLoading: _loading && _items == null,
                      loadingMore: _loading && _items != null,
                      error: _error,
                      onRetry: _load,
                      currentPage: _page?.page ?? 1,
                      totalPages: _page?.totalPages ?? 1,
                      paginationScope: _keyword,
                      onPageChange: (page) =>
                          inlineNavigate(() => _load(page, true)),
                      emptyMessage: _keyword.trim().isEmpty
                          ? '暂无结算方式'
                          : '没有匹配的结算方式', // TODO(l10n): 补 arb
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettlementTermsDialog extends ConsumerStatefulWidget {
  const _SettlementTermsDialog({
    required this.item,
    required this.isCurrent,
    required this.fields,
    required this.initialValues,
    required this.onSubmit,
    required this.onHistoryChanged,
  });

  final SettlementMethodAdminItem item;
  final bool Function() isCurrent;
  final List<MasterFieldDef> fields;
  final Map<String, String> initialValues;
  final MasterSubmit onSubmit;
  final VoidCallback onHistoryChanged;

  @override
  ConsumerState<_SettlementTermsDialog> createState() =>
      _SettlementTermsDialogState();
}

class _SettlementTermsDialogState
    extends ConsumerState<_SettlementTermsDialog> {
  final _formKey = GlobalKey<MasterEditFormState>();
  bool _saving = false;

  bool get _canEdit =>
      widget.isCurrent() &&
      !widget.item.lockedBySystemRole &&
      ref.read(currentPermissionsProvider).contains(Perm.settlementMethodEdit);

  Future<void> _save() async {
    if (_saving || !_canEdit) return;
    final body = _formKey.currentState?.buildBody();
    if (body == null) return;
    setState(() => _saving = true);
    try {
      final saved = await widget.onSubmit(body);
      if (saved && mounted && widget.isCurrent()) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(exportContextEpochProvider);
    final current = widget.isCurrent();
    final canEdit = _canEdit;
    return PopScope(
      canPop: !_saving,
      child: UtenDialogSurface(
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              UtenDialogHeader(
                icon: Icons.event_note_outlined,
                title: Text(
                  !current
                      ? '读取范围已更新'
                      : canEdit
                      ? '维护账期 · ${widget.item.name}'
                      : widget.item.name,
                ),
                trailing: MasterRecordHistoryAction(
                  entityType: 'reference-methods',
                  recordId: widget.item.id,
                  enabled: current && !_saving,
                  onChanged: () {
                    final route = ModalRoute.of(context);
                    if (route != null && route.isActive) {
                      route.navigator?.removeRoute(route);
                    }
                    widget.onHistoryChanged();
                  },
                ),
                showCloseButton: true,
                onClose: _saving ? null : () => Navigator.of(context).pop(),
              ),
              if (!current)
                const UtenInlineNotice(
                  level: UtenInlineNoticeLevel.warning,
                  title: '原输入已保留，此窗口不会提交',
                  message: '请关闭窗口，核对当前信息后重新操作。',
                ),
              Flexible(
                child: Visibility(
                  visible: current,
                  maintainState: true,
                  child: MasterEditForm(
                    key: _formKey,
                    fields: widget.fields,
                    initialValues: widget.initialValues,
                    readOnlyKeys: canEdit && !_saving
                        ? null
                        : {for (final field in widget.fields) field.key},
                  ),
                ),
              ),
              UtenDialogActions(
                children: [
                  if (canEdit)
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  if (canEdit)
                    UtenButton(
                      isLoading: _saving,
                      onPressed: _save,
                      child: const Text('保存'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
