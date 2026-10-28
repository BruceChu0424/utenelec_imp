import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/search/table_column_query.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart'
    show nativeReadAccessDenied;
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/procurement_iqc_rejection.dart';
import '../repositories/procurement_iqc_rejection_repository.dart';
import '../widgets/procurement_iqc_rejection_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';

class ProcurementIqcRejectionListPage extends ConsumerStatefulWidget {
  const ProcurementIqcRejectionListPage({
    super.key,
    this.source,
    this.repository,
    this.embedded = false,
    this.externalHeader,
    this.refreshTick = 0,
    this.refreshCompletion,
  });

  final String? source;
  final ProcurementIqcRejectionGateway? repository;

  /// 嵌入「业务审核中心」分段时为 true——去掉本页 AppBar 与内容容器
  /// （外层提供标题/刷新/容器）。
  final bool embedded;

  /// 宿主（业务审核中心）的大类行：挂进本页折叠头，随页一起滚走
  /// （2026-09-24 用户口径「表格滑到顶」，置顶后只剩表格自身工具条）。
  final Widget? externalHeader;

  /// 外层（业务审核中心）触发的刷新信号；数值变化时重拉当前页。
  final int refreshTick;
  final Completer<void>? refreshCompletion;

  @override
  ConsumerState<ProcurementIqcRejectionListPage> createState() =>
      _ProcurementIqcRejectionListPageState();
}

class _ProcurementIqcRejectionListPageState
    extends ConsumerState<ProcurementIqcRejectionListPage>
    with ScopedPagedReadViewMixin<ProcurementIqcRejectionListPage> {
  final _tableRows =
      MasterDataTableRowsController<ProcurementIqcRejectionCase>();
  PagedResult<ProcurementIqcRejectionCase>? _result;
  Object? _acceptedQuery;
  ProcurementIqcRejectionCounts? _counts;
  ProcurementIqcReceiptType? _receiptType;
  String? _status = 'ACTIVE';
  bool get _historyStatus => const {
    'TERMINAL',
    'CREDIT_CONFIRMED',
    'CLOSED_NO_CREDIT',
    'REVERSED',
  }.contains(_status);
  bool _hasAcceptedList = false;
  bool _statusSelected = false; // 进页面不预选（不选=不过滤）
  String _keyword = '';
  TableColumnQuery _headers = const TableColumnQuery();
  Object get _query =>
      (_receiptType, _status, _statusSelected, _keyword, _headers);
  bool get _canQueryAmount =>
      (ref.read(isSuperAdminProvider) ||
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.procurementIqcRejectionAmountView)) &&
      !(_result?.items.any((item) => item.priceMasked) ?? false);
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  @override
  void scopedPagedReadOwnerChanged() => setState(() {
    _requestId++;
    _tableRows.update(const []);
    _result = null;
    _acceptedQuery = null;
    _headers = const TableColumnQuery();
    _counts = null;
    _selectedIds.clear();
    _hasAcceptedList = false;
    _loading = false;
    _error = scopedPagedReadRejection?.message;
  });

  /// 行勾选集（2026-10-10 审核页防看岔行口径：纯阅读辅助，无批量动作）。
  final Set<String> _selectedIds = <String>{};

  /// 「返回即刷新」登记用的本页路径（独立路由形态，build 首次捕获）。
  String? _myLocation;

  ProcurementIqcRejectionGateway get _repository =>
      widget.repository ?? ref.read(procurementIqcRejectionRepositoryProvider);

  String get _defaultBackPath => switch (widget.source) {
    'warehouse' => RouteName.warehouse,
    'finance' => RouteName.finance,
    _ => RouteName.dashboard,
  };

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      if (!mounted) return;
      final completion = widget.refreshCompletion;
      await _load(1).whenComplete(() {
        if (completion != null && !completion.isCompleted) {
          completion.complete();
        }
      });
    });
  }

  @override
  void didUpdateWidget(ProcurementIqcRejectionListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      final completion = widget.refreshCompletion;
      _load(_tableRows.visiblePage ?? _result?.page ?? 1).whenComplete(() {
        if (completion != null && !completion.isCompleted) {
          completion.complete();
        }
      });
    }
  }

  @override
  void dispose() {
    final completion = widget.refreshCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
    super.dispose();
  }

  Future<void> _load(int page, {bool useCache = false}) async {
    final requestId = ++_requestId;
    final repository = _repository;
    final ownerCurrent = captureReadOwner(ref);
    final query = _query;
    final headers = _headers;
    bool current() => mounted && requestId == _requestId && ownerCurrent();
    setState(() {
      if (_acceptedQuery != query) {
        _result = null;
        _selectedIds.clear();
      }
      _loading = true;
      _error = null;
    });
    try {
      final filter = ProcurementIqcRejectionFilter(
        receiptType: _receiptType,
        status: _status,
        keyword: _keyword,
        page: page,
        columnSearch: headers.searches,
        sort: headers.sort,
        ascending: headers.ascending,
      );
      final countFilter = ProcurementIqcRejectionFilter(
        receiptType: _receiptType,
        keyword: _keyword,
        columnSearch: headers.searches,
      );
      unawaited(_loadCounts(countFilter, current));
      final result = _statusSelected
          ? await readScopedPage<ProcurementIqcRejectionCase>(
              page,
              query: (repository, query),
              currentQuery: () => (_repository, _query),
              useCache: useCache,
              fetchPage: (page) => repository.list(
                ProcurementIqcRejectionFilter(
                  receiptType: filter.receiptType,
                  status: filter.status,
                  keyword: filter.keyword,
                  page: page,
                  columnSearch: filter.columnSearch,
                  sort: filter.sort,
                  ascending: filter.ascending,
                ),
              ),
            )
          : const PagedResult<ProcurementIqcRejectionCase>(
              items: [],
              page: 1,
              size: 20,
              total: 0,
              totalPages: 1,
            );
      if (!current()) return;
      setState(() {
        _result = result;
        _acceptedQuery = query;
        if (_statusSelected) _hasAcceptedList = true;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!current()) return;
      setState(() {
        if (nativeReadAccessDenied(error)) {
          ++_requestId;
          _result = null;
          _acceptedQuery = null;
          _counts = null;
          _selectedIds.clear();
          _hasAcceptedList = false;
        }
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!current()) return;
      setState(() {
        _loading = false;
        _error = 'IQC 不合格退回与贷项任务加载失败，请检查网络后重试';
      });
    }
  }

  Future<void> _loadCounts(
    ProcurementIqcRejectionFilter filter,
    bool Function() current,
  ) async {
    try {
      final counts = await _repository.counts(filter);
      if (current()) setState(() => _counts = counts);
    } on ApiException catch (error) {
      if (!current()) return;
      if (error.httpStatus == 401 ||
          error.httpStatus == 403 ||
          error.code == 'UNAUTHORIZED' ||
          error.code == 'FORBIDDEN') {
        ++_requestId;
        setState(() {
          _result = null;
          _hasAcceptedList = false;
          _counts = null;
          _loading = false;
          _error = error.message;
        });
      }
    } catch (_) {
      // Keep the accepted list usable when only its badge request failed.
    }
  }

  void _changeReceiptType(ProcurementIqcReceiptType? value) {
    if (_receiptType == value) return;
    setState(() => _receiptType = value);
    _load(1);
  }

  void _changeStatus(String? value) {
    if (_status == value && _statusSelected) return;
    setState(() {
      _status = value ?? (_historyStatus ? 'TERMINAL' : 'ACTIVE');
      _statusSelected = true;
    });
    _load(1);
  }

  /// 表头筛选回调：来源只在表头筛选（receiptType/status 参数均已在），
  /// 复用既有 [_changeReceiptType]/[_changeStatus]，重拉回第 1 页。
  void _onColumnFilterChanged(String key, String? value) {
    if (key == 'receiptType') {
      _changeReceiptType(
        value == null ? null : ProcurementIqcReceiptType.tryParse(value),
      );
    } else if (key == 'status') {
      _changeStatus(value);
    } else if (key.startsWith('search.')) {
      setState(() {
        _headers = _headers.search(key, value);
        _statusSelected = true;
      });
      _load(1);
    }
  }

  void _search(String value) {
    setState(() => _keyword = value.trim());
    _load(1);
  }

  void _open(ProcurementIqcRejectionCase item) {
    context.push(
      RoutePath.procurementIqcRejectionDetail(item.id, source: widget.source),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    // 独立路由形态注册「返回即刷新」（2026-09-24）：从本页 push 进详情办结/反审/
    // 登记退回后返回，重拉当前页——此前只靠嵌入宿主的 refreshTick，独立入口
    // （通知深链/收藏直达）返回后行状态停留在旧值，要手动刷新。
    if (!widget.embedded) {
      _myLocation ??= currentLocationOr(context, _defaultBackPath);
      ref.onPageResume(
        _myLocation!,
        () => _load(_tableRows.visiblePage ?? _result?.page ?? 1),
      );
    }
    final body = SafeArea(child: _buildContent());
    if (widget.embedded) return body;
    return Scaffold(
      appBar: UtenAppBar(
        title: 'IQC 不合格退回与贷项',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: _defaultBackPath),
        ),
        actions: [
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading,
            onPressed: _loading
                ? null
                : () => _load(_tableRows.visiblePage ?? _result?.page ?? 1),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildContent() {
    final result =
        _result ??
        const PagedResult<ProcurementIqcRejectionCase>(
          items: [],
          page: 1,
          size: 50,
          total: 0,
          totalPages: 1,
        );
    Widget buildContent(BoxConstraints constraints) {
      final expanded = constraints.maxWidth >= 840;
      final header = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 宿主大类行随页滚走（2026-09-24「表格滑到顶」）。
          if (widget.externalHeader != null) ...[
            widget.externalHeader!,
            const SizedBox(height: UtenFilterRow.rowGap),
          ],
          _buildCounts(_counts),
          const SizedBox(height: UtenSpacing.s12),
          _buildFilters(),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Icon(
                    Icons.sync_problem_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      !_hasAcceptedList ? '无法加载 IQC 不合格任务' : '刷新失败：${_error!}',
                    ),
                  ),
                  TextButton(
                    onPressed: _loading ? null : () => _load(result.page),
                    child: Text(!_hasAcceptedList ? '重新加载' : '重试'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
        ],
      );
      if (expanded) {
        // 2026-09-24 对齐物料分析页口径：责任横幅/计数卡/筛选行进折叠头
        //（上滑先收走，表头顶到头再表内滚）；独立页与嵌入态同款。
        return UtenCollapsingHeaderScrollView(
          collapsingHeader: header,
          body: _buildTable(result),
        );
      }
      // 大小屏共用一张表：与宽屏同走折叠头 + 表格，窄屏横向滚动（卡片形态已退役）。
      return UtenCollapsingHeaderScrollView(
        collapsingHeader: header,
        body: _buildTable(result),
      );
    }

    // 嵌入形态不复套容器与内边距（业务审核中心已提供），避免双重 gutter。
    if (widget.embedded) {
      return LayoutBuilder(
        builder: (context, constraints) => buildContent(constraints),
      );
    }
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
        child: LayoutBuilder(
          builder: (context, constraints) => buildContent(constraints),
        ),
      ),
    );
  }

  /// 状态分段工具条：红徽章只挂在「待退回」(本页用户——采购/委外要登记退回
  /// 的动作)；「已退回待财务」「财务异常」球已经在财务手上、案子还没结,
  /// 2026-09-21 起改挂黄色在办徽章(ADR-100); 「终态」已结束, 中性括号。
  /// 原「点击已选 Chip 取消筛选」由显式「全部」分段承担。
  /// 2026-10-10 用户口径：页首「品质拒收、实物退回与财务贷项分步留痕」责任
  /// 横幅退役（全站提示卡口径），流程说明留在详情页。
  Widget _buildCounts(ProcurementIqcRejectionCounts? counts) {
    return UtenFilterToolbar<String?>(
      segmentsKey: const Key('iqc-rejection-status-segments'),
      segments: [
        const UtenFilterSegment(value: 'ACTIVE', label: '待办与进行中'),
        UtenFilterSegment(
          value: 'PENDING_RETURN',
          label: '待退回',
          count: (counts?.actionablePendingReturn ?? 0) > 0
              ? counts?.actionablePendingReturn
              : counts?.pendingReturn,
          countForm: (counts?.actionablePendingReturn ?? 0) > 0
              ? UtenSegmentCountForm.actionable
              : UtenSegmentCountForm.browsing,
        ),
        // 2026-09-21 用户口径: 父分类有红徽章, 子分类也要有数。退回登记完、贷项
        // 还没落地的两段是「已经在办、球在财务手上、还没完」→ 黄色在办徽章
        // (ADR-100); 分段计数一律不进任何累加注册表。
        UtenFilterSegment(
          value: 'RETURN_RECORDED',
          label: '已退回待财务',
          count: (counts?.actionableReturnRecorded ?? 0) > 0
              ? counts?.actionableReturnRecorded
              : counts?.returnRecorded,
          countForm: (counts?.actionableReturnRecorded ?? 0) > 0
              ? UtenSegmentCountForm.actionable
              : UtenSegmentCountForm.browsing,
        ),
        UtenFilterSegment(
          value: 'FINANCE_EXCEPTION',
          label: '财务异常',
          count: (counts?.actionableFinanceException ?? 0) > 0
              ? counts?.actionableFinanceException
              : counts?.financeException,
          countForm: (counts?.actionableFinanceException ?? 0) > 0
              ? UtenSegmentCountForm.actionable
              : UtenSegmentCountForm.browsing,
        ),
        const UtenFilterSegment(value: 'TERMINAL', label: '历史单据'),
      ],
      selected: _statusSelected
          ? {_historyStatus ? 'TERMINAL' : _status}
          : const {},
      onSelectionChanged: _changeStatus,
    );
  }

  Widget _buildFilters() => UtenFilterToolbar<String>(
    searchKey: const Key('iqc-rejection-search'),
    searchHint: '搜索收货单、订货单、供应商/委外商、货品',
    searchWidth: 195,
    initialSearchValue: _keyword,
    onSearchInputChanged: (_) => _requestId++,
    onSearchChanged: _search,
    trailing: Text(
      '共 ${_result?.total ?? 0} 条',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );

  Widget _buildTable(PagedResult<ProcurementIqcRejectionCase> result) {
    return MasterDataTableView<ProcurementIqcRejectionCase>(
      rowsController: _tableRows,
      expensiveRowMounts: false,
      tableKey:
          'features.procurement_iqc_rejection.pages.procurement_iqc_rejection_list_page.ProcurementIqcRejectionListPageState._buildTable.1',
      key: const Key('iqc-rejection-task-table'),
      // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
      primary: true,
      bottomContentPadding: widget.embedded
          ? 0
          : UtenCapsuleNavScope.occlusionOf(context),
      columns: _columns,
      serverColumnSearchKeys: {
        'receiptBillNo',
        'orderBillNo',
        'supplierName',
        'goodsName',
        'goodsCode',
        'colorName',
        'failedQty',
        'holdReason',
        if (_canQueryAmount) 'amount',
      },
      items: result.items,
      // 来源/状态是固定枚举（服务端 receiptType/status 参数均已在），前端
      // 固定枚举桶；count=0 表示不强调计数。状态仍与主工作阶段同源。
      facets: const {
        'receiptType': [
          MasterFacetBucket(value: 'PURCHASE', count: 0, label: '采购'),
          MasterFacetBucket(value: 'SUBCONTRACT', count: 0, label: '委外'),
        ],
        'status': [
          MasterFacetBucket(
            value: 'PENDING_RETURN',
            count: 0,
            label: '待登记实物退回',
          ),
          MasterFacetBucket(
            value: 'RETURN_RECORDED',
            count: 0,
            label: '已退回 / 待财务',
          ),
          MasterFacetBucket(
            value: 'FINANCE_EXCEPTION',
            count: 0,
            label: '财务投影异常',
          ),
          MasterFacetBucket(value: 'TERMINAL', count: 0, label: '终态'),
        ],
      },
      nullCounts: const {},
      filters: {
        'receiptType': _receiptType?.apiValue,
        'status': _statusSelected ? _status : null,
        ..._headers.searches,
      },
      onFilterChanged: _onColumnFilterChanged,
      sortColumn: _headers.sort,
      sortAscending: _headers.ascending,
      onSortChange: (column, ascending) {
        setState(() {
          _headers = _headers.sorted(column, ascending);
          _statusSelected = true;
        });
        _load(1);
      },
      // 行勾选（2026-10-10 审核页防看岔行口径）：纯阅读辅助——单选互斥（点
      // 其他行自动换选、再点取消），双击进详情；办理仍逐条进入。选中态由行
      // 高亮表达，不画勾选框列也不驻「已选」胶囊。
      selectable: true,
      showSelectionColumn: false,
      singleSelection: true,
      showSelectionSummary: false,
      idOf: (item) => item.id.isEmpty ? null : item.id,
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      onRowTap: _open,
      rowColor: (item) =>
          item.status == ProcurementIqcRejectionStatus.financeException
          ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.32)
          : item.status == ProcurementIqcRejectionStatus.returnRecorded
          ? Theme.of(
              context,
            ).colorScheme.secondaryContainer.withValues(alpha: 0.26)
          : null,
      isLoading: _loading,
      loadingMore: _loading && _result != null,
      error: result.items.isEmpty ? _error : null,
      onRetry: () => _load(result.page),
      emptyMessage: _emptyMessage,
      currentPage: result.page,
      totalPages: result.totalPages,
      paginationScope: _query,
      onPageChange: (page) => _load(page, useCache: true),
    );
  }

  List<MasterColumnDef<ProcurementIqcRejectionCase>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 210,
      value: (item) =>
          '${item.receiptType?.label ?? '未知来源'} · ${item.status.label}',
      // 2026-09-27 用户口径「表格状态列整格底色」：与徽章同源分类色。
      cellColor: (context, item) => utenStatusBadgeCellColor(
        procurementIqcRejectionBadgeType(item.status),
      ),
    ),
    MasterColumnDef(
      key: 'receiptType',
      label: '来源',
      width: 90,
      value: (item) => item.receiptType?.label ?? '—',
    ),
    MasterColumnDef(
      key: 'receiptBillNo',
      sortable: true,
      label: '收货 / 回厂单',
      width: 170,
      value: (item) => item.receiptBillNo,
    ),
    MasterColumnDef(
      key: 'orderBillNo',
      sortable: true,
      label: '订货单',
      width: 160,
      value: (item) => item.orderBillNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      sortable: true,
      label: '供应商 / 委外商',
      width: 200,
      value: (item) => item.supplierName,
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    MasterColumnDef(
      key: 'goodsName',
      sortable: true,
      label: '不合格货品名称',
      width: 200,
      value: (item) => item.goodsName ?? '—',
    ),
    MasterColumnDef(
      key: 'goodsCode',
      sortable: true,
      label: '编号',
      width: 130,
      value: (item) => item.goodsCode ?? '—',
    ),
    MasterColumnDef(
      key: 'colorName',
      sortable: true,
      label: '颜色',
      width: 96,
      value: (item) => item.colorName ?? '—',
    ),
    MasterColumnDef(
      key: 'failedQty',
      label: '不合格数量',
      width: 130,
      type: 'number',
      sortable: true,
      columnSearchEnabled: true,
      exactValueOf: (item) => item.failedQty,
      value: (item) => '${item.failedQty ?? '—'} ${item.unitName ?? ''}'.trim(),
    ),
    MasterColumnDef(
      key: 'amount',
      label: '不合格金额(本币)',
      info: '按本币原始金额筛选；未知金额不当零，脱敏金额不支持筛选或排序。',
      width: 150,
      type: 'money',
      sortable: _canQueryAmount,
      columnSearchEnabled: _canQueryAmount,
      exactValueOf: (item) => item.priceMasked ? null : item.failedAmountLocal,
      value: (item) => item.localAmountLabel(item.failedAmountLocal),
    ),
    MasterColumnDef(
      key: 'holdReason',
      sortable: true,
      columnSearchEnabled: true,
      label: '异常原因 / 下一步',
      width: 280,
      value: (item) => item.reasonLabel,
    ),
  ];

  String get _emptyMessage {
    if (_keyword.isNotEmpty) return '没有匹配的 IQC 不合格任务';
    if (_status == 'PENDING_RETURN') return '当前没有待登记实物退回的任务';
    if (_status == 'RETURN_RECORDED') return '当前没有已退回待财务处理的任务';
    if (_status == 'FINANCE_EXCEPTION') return '当前没有财务投影异常';
    if (_status == 'TERMINAL') return '当前没有已结案或已反向的任务';
    return '当前没有 IQC 不合格退回与贷项任务';
  }
}
