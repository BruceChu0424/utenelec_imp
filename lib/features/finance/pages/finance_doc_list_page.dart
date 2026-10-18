// 钱流单据列表页（按 docType 参数化，5 单据通用）。
//
// UtenAppBar 保留标题/返回/刷新；正文从分类和搜索开始，新建统一放右下悬浮区。
// 名称解析（客户/供应商/账户）通过 FinanceNameService。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_category.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_document_lifecycle_filter.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/mixins/draft_bulk_delete_mixin.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/document_status_counts_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_table_facets.dart';

class FinanceDocListPage extends ConsumerStatefulWidget {
  const FinanceDocListPage({
    super.key,
    required this.docType,
    this.initialStatus,
  });
  final FinanceDocType docType;

  /// 深链预选（路由 `?status=draft`）：新建页「草稿(N)」按钮进来时直接落在草稿段。
  final String? initialStatus;

  @override
  ConsumerState<FinanceDocListPage> createState() => _FinanceDocListPageState();
}

class _FinanceDocListPageState extends ConsumerState<FinanceDocListPage>
    with DraftBulkDeleteMixin<FinanceDocListPage> {
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.docType);
  final _list = PagedListController<FinanceDocListItem>();
  final _tableRows = MasterDataTableRowsController<FinanceDocListItem>();

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;
  int? _statusFilter; // null=全部
  bool _historyMode = false;
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.all();
  bool _statusFilterSelected = false; // 进页面不预选（不选=不过滤）
  String? _partyIdFilter;
  String? _accountIdFilter;
  String? _receiptKindFilter; // 收款类型（仅收款单；null=不过滤）
  FinanceRecordOrigin? _recordOriginFilter;

  /// 2026-09-25 单号列统一：单据号表头值筛选 + 服务端桶（共享状态，见
  /// MasterServerColumnFilters）。
  final _columnFilters = MasterServerColumnFilters();
  int _reloadGeneration = 0;

  @override
  void initState() {
    super.initState();
    // 深链 ?status=draft：预选「草稿」段（新建页「草稿(N)」按钮的落点）。
    if (isDraftStatusQuery(widget.initialStatus)) {
      _statusFilter = kFinanceStatusDraft;
      _statusFilterSelected = true;
    } else if (widget.docType == FinanceDocType.expense &&
        widget.initialStatus == 'pending-gl-confirmation') {
      _statusFilter = kFinanceStatusApproved;
      _statusFilterSelected = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded();
      _reload(1);
    });
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FinanceDocListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.docType == widget.docType &&
        oldWidget.initialStatus == widget.initialStatus) {
      return;
    }
    clearDraftSelection();
    _myLocation = null;
    _statusFilter = isDraftStatusQuery(widget.initialStatus)
        ? kFinanceStatusDraft
        : widget.docType == FinanceDocType.expense &&
              widget.initialStatus == 'pending-gl-confirmation'
        ? kFinanceStatusApproved
        : null;
    _statusFilterSelected = _statusFilter != null;
    _historyMode = false;
    _historyTime = const UtenHistoryTimeValue.all();
    _partyIdFilter = null;
    _accountIdFilter = null;
    _receiptKindFilter = null;
    _recordOriginFilter = null;
    _columnFilters.reset();
    _list.page = null;
    _list.keyword = '';
    _list.onSortChange(null, true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload(1);
    });
  }

  bool get _canSelectDrafts =>
      !_historyMode &&
      _statusFilterSelected &&
      _statusFilter == kFinanceStatusDraft &&
      _cfg.deletePerm != null &&
      ref.read(currentPermissionsProvider).contains(_cfg.deletePerm);

  bool _isDeletableDraft(FinanceDocListItem item) =>
      item.status == kFinanceStatusDraft && !item.legacyImported;

  Future<void> _deleteDraft(String id, FinanceDocType type) async {
    final scope = ref.read(authenticatedScopeProvider);
    final config = FinanceDocConfig.by(type);
    if (config.deletePerm == null ||
        !ref.read(currentPermissionsProvider).contains(config.deletePerm)) {
      throw ApiException('FORBIDDEN', '没有${config.label}删除权限');
    }
    final repository = ref.read(financeRepositoryProvider(type));
    // 列表没有制单人字段，仅对本次勾选记录读取最新详情，复用详情页写范围。
    final detail = await repository.detail(id);
    if (detail.status != kFinanceStatusDraft) {
      throw ApiException('CONFLICT', '单据状态已变化，仅草稿可删除');
    }
    if (detail.legacyImported) {
      throw ApiException('CONFLICT', financeLegacyReadOnlyMessage);
    }
    if (!mounted ||
        !await loadDocumentOwnerCanWrite(
          ref,
          DocumentDataScope.finance,
          detail.makerId,
        )) {
      throw ApiException('FORBIDDEN', documentScopeReadOnlyMessage);
    }
    if (!mounted ||
        ref.read(authenticatedScopeProvider) != scope ||
        widget.docType != type ||
        !_canSelectDrafts ||
        !selectedDraftIds.contains(id) ||
        !ref.read(currentPermissionsProvider).contains(config.deletePerm)) {
      throw ApiException('FORBIDDEN', '当前身份、选择范围或${config.label}删除权限已变化');
    }
    await repository.delete(id);
  }

  bool get _canCreate {
    final permission = _cfg.createPerm;
    return permission != null &&
        ref.read(currentPermissionsProvider).contains(permission);
  }

  Widget _createButton() => UtenButton(
    key: const Key('finance-doc-list-create'),
    size: UtenButtonSize.large,
    icon: Icons.add_rounded,
    onPressed: () => context.push('/finance/${_cfg.type.pathSegment}/new'),
    child: const Text('新建'),
  );

  /// 当前分段/表头筛选组装查询条件（_fetch 与单号桶共用；[withBillNo] = false
  /// 供桶拉取——桶不算单号列自身的值筛选，2026-09-25 单号列统一）。
  FinanceDocFilter _docFilter({bool withBillNo = true}) => FinanceDocFilter(
    keyword: _list.normalizedKeyword,
    partyId: _cfg.hasParty ? _partyIdFilter : null,
    accountId: _cfg.type == FinanceDocType.bankTransfer
        ? null
        : _accountIdFilter,
    outAccountId: _cfg.type == FinanceDocType.bankTransfer
        ? _accountIdFilter
        : null,
    status: _statusFilter,
    view: widget.docType == FinanceDocType.expense
        ? (_historyMode ? 'HISTORY' : 'ACTIVE')
        : null,
    receiptKind: _cfg.type == FinanceDocType.receipt
        ? _receiptKindFilter
        : null,
    billNo: withBillNo ? _columnFilters['billNo'] : null,
    recordOrigin: _historyMode
        ? _recordOriginFilter
        : FinanceRecordOrigin.current,
    dateFrom: _historyMode && _historyTime.range != null
        ? ChinaDateTime.formatDate(_historyTime.range!.start)
        : null,
    dateTo: _historyMode && _historyTime.range != null
        ? ChinaDateTime.formatDate(_historyTime.range!.end)
        : null,
  );

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<FinanceDocListItem>> _fetch() => ref
      .read(financeRepositoryProvider(widget.docType))
      .list(
        page: _list.pageNum,
        filter: _docFilter(),
        sort: _list.sortKey,
        order: _list.sortOrder,
      );

  /// 单据号值筛选桶随过滤上下文重取（失败静默保持旧桶，不阻断列表）。
  Future<void> _loadBillNoFacets() => _columnFilters.loadFacets(
    () async => {
      'billNo': await ref
          .read(financeRepositoryProvider(widget.docType))
          .billNoFacets(filter: _docFilter(withBillNo: false)),
    },
    onLoaded: () {
      if (mounted) setState(() {});
    },
  );

  /// 分段计数范围(2026-09-21 用户口径: 父分类 hub 卡有草稿红徽章, 子分类也要有数)。
  DocumentStatusScope get _statusScope => DocumentStatusScope(_cfg.draftKind);

  Future<void> _reload([int? page, bool silent = false]) async {
    final generation = ++_reloadGeneration;
    // 列表重拉时同步分段计数(写操作成功 / 返回本页 / 手动刷新都经过这里)。
    ref.invalidate(documentStatusCountsProvider(_statusScope));
    if (!_statusFilterSelected || (_historyMode && _historyTime.isNone)) return;
    unawaited(_loadBillNoFacets());
    await _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);
    if (!mounted || generation != _reloadGeneration || _list.error != null) {
      return;
    }
    final result = _list.page;
    if (widget.docType == FinanceDocType.expense &&
        result != null &&
        result.page > (result.totalPages > 0 ? result.totalPages : 1)) {
      // Confirmation can remove the last row on a later pending page. Requery
      // the current lifecycle scope at its last valid page.
      return _reload(result.totalPages > 0 ? result.totalPages : 1);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _reloadGeneration) return;
      retainDraftSelection(
        _canSelectDrafts
            ? _tableRows.items.where(_isDeletableDraft).map((item) => item.id)
            : const <String>[],
      );
    });
  }

  void _onCategory(int? status) {
    clearDraftSelection();
    setState(() {
      _historyMode = status == null;
      _statusFilter = status;
      _statusFilterSelected = true;
      _recordOriginFilter = null;
    });
    _reload(1);
  }

  void _onHistoryStatus(int? status) {
    clearDraftSelection();
    setState(() => _statusFilter = status);
    _reload(1);
  }

  Widget _lifecycleFilters(Map<String, int>? counts) =>
      UtenDocumentLifecycleFilter(
        selected: _statusFilterSelected,
        history: _historyMode,
        status: _statusFilter,
        hasOngoing: widget.docType == FinanceDocType.expense,
        ongoingLabel: '待财务确认',
        ongoingCount: counts?[DocumentStatusBucket.pendingGlConfirmation],
        historyIncludesDrafts: widget.docType != FinanceDocType.expense,
        draftCount: counts?[DocumentStatusBucket.draft],
        onCategoryChanged: _onCategory,
        onHistoryStatusChanged: _onHistoryStatus,
        historyTime: _historyTime,
        onHistoryTimeChanged: (value) {
          clearDraftSelection();
          setState(() => _historyTime = value);
          _reload(1);
        },
        searchHint: '搜索单据号',
        searchValue: _list.keyword,
        onSearchChanged: (value) {
          clearDraftSelection();
          _list.keyword = value;
          _reload(1);
        },
      );

  void _onColumnFilterChanged(String key, String? value) {
    clearDraftSelection();
    if (key == 'billNo') {
      _columnFilters.handleFilterChanged(
        key,
        value,
        onChanged: _afterServerColumnChanged,
      );
      return;
    }
    setState(() {
      if (key == 'status') {
        _statusFilter = value == null
            ? (_historyMode ? null : _statusFilter ?? kFinanceStatusDraft)
            : int.tryParse(value);
        if (_statusFilter != kFinanceStatusDraft &&
            !(widget.docType == FinanceDocType.expense &&
                _statusFilter == kFinanceStatusApproved)) {
          _historyMode = true;
        }
        _statusFilterSelected = _historyMode || _statusFilter != null;
      } else if (key == 'accountId') {
        _accountIdFilter = value;
      } else if (key == 'recordOrigin') {
        _recordOriginFilter = FinanceRecordOrigin.fromWire(value);
        if (_recordOriginFilter == FinanceRecordOrigin.legacy) {
          _historyMode = true;
          _statusFilterSelected = true;
          _statusFilter = null;
        }
      } else if (key == 'receiptKind') {
        _receiptKindFilter = value;
      } else if (key == 'clientId' || key == 'supplierId') {
        _partyIdFilter = value;
      }
    });
    _reload(1);
  }

  /// 服务端列筛选落地后：setState 刷新表头 + 重拉回第 1 页。
  void _afterServerColumnChanged() {
    clearDraftSelection();
    setState(() {});
    _reload(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    clearDraftSelection();
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  List<MasterColumnDef<FinanceDocListItem>> _columns(FinanceNameService names) {
    return <MasterColumnDef<FinanceDocListItem>>[
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 72,
        value: (it) =>
            widget.docType == FinanceDocType.expense &&
                !it.legacyImported &&
                it.status == kFinanceStatusApproved &&
                it.glStatus == 1
            ? '待财务确认'
            : financeStatusLabel(it.status),
        // 状态分类色（草稿中性/已审绿/红冲红）铺整格底色，替代原格内胶囊
        // （2026-09-27 用户口径）；value 仍是纯文本供列宽/排序/筛选。
        cellColor: (context, it) => utenStatusBadgeCellColor(
          widget.docType == FinanceDocType.expense &&
                  !it.legacyImported &&
                  it.status == kFinanceStatusApproved &&
                  it.glStatus == 1
              ? UtenStatusBadgeType.warning
              : docStatusBadgeType(it.status),
        ),
      ),
      MasterColumnDef(
        // 2026-09-25 单号列统一：可排序 + 表头值筛选（服务端 billNo 白名单/桶）。
        key: 'billNo',
        sortable: true,
        label: '单据号',
        width: 150,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '日期',
        width: 120,
        type: 'date',
        sortable: true,
        value: (it) {
          final date = it.billDate;
          return date == null || date.length <= 10
              ? date
              : date.substring(0, 10);
        },
      ),
      if (_cfg.type == FinanceDocType.receipt)
        MasterColumnDef(
          key: 'receiptKind',
          label: '收款类型',
          width: 130,
          value: (it) => financeReceiptKindLabel(
            it.receiptKind,
            historical: it.legacyImported,
          ),
        ),
      if (_cfg.hasParty)
        MasterColumnDef(
          key: _cfg.isClient ? 'clientId' : 'supplierId',
          label: _cfg.partyLabel,
          width: 200,
          value: (it) => _cfg.isClient
              ? names.client(it.partyId)
              : names.supplier(it.partyId),
        ),
      MasterColumnDef(
        key: 'accountId',
        label: _cfg.accountLabel,
        width: 180,
        value: (it) => names.account(it.accountId ?? it.outAccountId),
      ),
      MasterColumnDef(
        key: 'amountLocal',
        label: '合计',
        width: 140,
        type: 'money',
        sortable: true,
        value: (it) => financeExactMoneyDisplay(
          it.amountLocalText ?? financeDecimalText(it.amountLocal),
        ),
      ),
      MasterColumnDef(
        key: 'recordOrigin',
        label: '来源',
        width: 130,
        value: (it) => it.legacyImported ? '历史记录（只读）' : '当前单据',
      ),
    ];
  }

  FormDraftCategoryScope get _formDraftScope =>
      FormDraftCategoryScope(kind: _cfg.draftKind.name);

  Widget _withFormDraftRows(MasterDataTableView<FinanceDocListItem> table) =>
      !_historyMode && _statusFilter == kFinanceStatusDraft
      ? FormDraftCategoryTable<FinanceDocListItem>(
          scope: _formDraftScope,
          table: table,
          search: _list.keyword,
          formalId: (item) => item.id,
        )
      : table;

  @override
  Widget build(BuildContext context) {
    final docType = widget.docType;
    ref.watch(currentPermissionsProvider);
    final names = ref.watch(financeNameServiceProvider);
    // 分段计数(一次请求带回草稿/已审/红冲三桶); 加载中或无权限为 null, 不渲染数字。
    final statusCounts = ref
        .watch(effectiveDocumentStatusCountsProvider(_statusScope))
        .valueOrNull;
    // 返回即刷新(ADR-108): 回到本列表时, 只有本端写过数据或离开超过 30 秒才重拉,
    // 且推迟到返回转场结束; 详情/编辑页保存成功 bump 的 tick 在本页就在栈顶时立即重拉,
    // 被详情页盖着时只记下、返回再拉——此前 tick 与返回各拉一次, 一次保存重拉两遍。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(
      _myLocation!,
      () => _reload(null, true),
      refreshKeys: [_cfg.refreshKey],
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: _cfg.label,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _reload(1),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _canCreate && !_canSelectDrafts
          ? UtenFloatingActionGroup(children: [_createButton()])
          : null,
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: ListenableBuilder(
              listenable: _list,
              builder: (context, _) {
                return UtenListTwoPane(
                  filterPane: _lifecycleFilters(statusCounts),
                  tablePane: _withFormDraftRows(
                    MasterDataTableView<FinanceDocListItem>(
                      rowsController: _tableRows,
                      tableKey: 'finance.${widget.docType.name}.list',
                      bottomContentPadding:
                          UtenFloatingActionGroup.scrollClearance,
                      selectable: _canSelectDrafts,
                      idOf: (item) =>
                          !draftDeleteBusy &&
                              !_list.loading &&
                              _isDeletableDraft(item)
                          ? item.id
                          : null,
                      rowKeyOf: (item) => item.id,
                      selectedIds: selectedDraftIds,
                      onSelectedIdsChanged: draftDeleteBusy || _list.loading
                          ? null
                          : selectDraftIds,
                      batchActionsBuilder: (_, _) => [
                        if (_canCreate) _createButton(),
                        buildDraftDeleteButton(
                          documentLabel: _cfg.label,
                          delete: (id) => _deleteDraft(id, docType),
                          reload: () => _reload(),
                        ),
                      ],
                      columns: _columns(names),
                      items: _list.page?.items ?? const [],
                      facets: {
                        // 单据号桶与列表同一过滤口径（2026-09-25 单号列统一）。
                        'billNo': _columnFilters.bucketOf('billNo'),
                        if (_cfg.type == FinanceDocType.receipt)
                          'receiptKind': financeReceiptKindFacets,
                        if (_cfg.hasParty)
                          _cfg.isClient
                              ? 'clientId'
                              : 'supplierId': financeDictionaryFacets(
                            _cfg.isClient
                                ? names.clientEntries
                                : names.supplierEntries,
                          ),
                        'accountId': financeDictionaryFacets(
                          names.accountEntries,
                        ),
                        'recordOrigin': const [
                          MasterFacetBucket(
                            value: 'CURRENT',
                            count: 0,
                            label: '当前单据',
                          ),
                          MasterFacetBucket(
                            value: 'LEGACY',
                            count: 0,
                            label: '历史记录（只读）',
                          ),
                        ],
                        'status': widget.docType == FinanceDocType.expense
                            ? [
                                if (!_historyMode)
                                  const MasterFacetBucket(
                                    value: '0',
                                    count: 0,
                                    label: '草稿',
                                  ),
                                MasterFacetBucket(
                                  value: '1',
                                  count: 0,
                                  label: _historyMode ? '已审' : '待财务确认',
                                ),
                                if (_historyMode)
                                  const MasterFacetBucket(
                                    value: '-1',
                                    count: 0,
                                    label: '已反审',
                                  ),
                              ]
                            : financeDocumentStatusFacets,
                      },
                      nullCounts: const {},
                      filters: {
                        'billNo': _columnFilters['billNo'],
                        if (_cfg.type == FinanceDocType.receipt)
                          'receiptKind': _receiptKindFilter,
                        if (_cfg.hasParty)
                          _cfg.isClient ? 'clientId' : 'supplierId':
                              _partyIdFilter,
                        'accountId': _accountIdFilter,
                        'recordOrigin': _recordOriginFilter?.wireValue,
                        'status': _statusFilter?.toString(),
                      },
                      onFilterChanged: _onColumnFilterChanged,
                      sortColumn: _list.sortKey,
                      sortAscending: _list.sortAsc,
                      onSortChange: _onSortChange,
                      onRowTap: (it) => context.push(
                        '/finance/${_cfg.type.pathSegment}/${it.id}',
                      ),
                      isLoading: _list.isLoadingFirst,
                      loadingMore: _list.isLoadingMore,
                      error: _list.error,
                      onRetry: () => _reload(),
                      emptyMessage: '暂无${_cfg.shortLabel}单',
                      currentPage: _list.currentPage,
                      totalPages: _list.totalPages,
                      paginationRevision: _list.page,
                      paginationScope: (
                        widget.docType,
                        _list.normalizedKeyword,
                        _statusFilter,
                        _historyMode,
                        _historyTime,
                        _recordOriginFilter,
                      ),
                      onPageChange: (p) => _reload(p),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
