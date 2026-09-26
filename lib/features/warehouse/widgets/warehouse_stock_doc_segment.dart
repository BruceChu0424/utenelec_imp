// 仓库任务中心 · 通用单据分段（新建 XXX + 历史 XXX 一体化工作台）。
//
// 出库/入库/领料任务中心里，仓库原生单据（其它出库/产成品出库/其它入库/产成品进仓/
// 生产领料/生产退料）共用本组件：状态分段（草稿/已审/红冲，2026-09-03 起无「全部」
// 段；已审+红冲即历史；徽章口径：草稿不计入待办数——单据草稿尚未进入待办流，
// 各分段一律不挂徽章）+ 末尾「历史单据」段（时间门控：时间段/全部，未选时间
// 不发请求；不限状态）+（DRAW/WDRAW 领退料选中状态后另带出库进度分段，
// 无「全部进度」段）+ 总结行（左「共 N 条」右「新建」按钮，按 stock_doc:create
// 门控）+ MasterDataTableView（双击进详情；新建/编辑/详情保存与审核都会 bump
// listRefreshTick，本组件据此重拉）。小类行进页面不预选（未选不发请求，
// 显示引导占位），不再渲染 icon + 标题分段头——分类语境已由上方大类分段表达。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';
import '../pages/warehouse_stock_batch_outbound_page.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

/// 状态小类分段值：真实单据状态（status 非空）或历史单据哨兵。
class _StockSegSeg {
  const _StockSegSeg.stage(int this.status) : history = false;
  const _StockSegSeg.history() : status = null, history = true;

  final int? status;
  final bool history;
  @override
  bool operator ==(Object other) =>
      other is _StockSegSeg &&
      other.status == status &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

class WarehouseStockDocSegment extends ConsumerStatefulWidget {
  const WarehouseStockDocSegment({
    super.key,
    required this.docType,
    this.keyword = '',
    this.createLabel,
    this.refreshTick = 0,
    this.pendingReturnCount,
    this.productionReturnRequests = false,
    this.externalHeader,
  });

  final StockDocType docType;
  final int? pendingReturnCount;
  final bool productionReturnRequests;

  /// 任务中心页级搜索框的关键字（300ms 防抖后的值）。
  final String keyword;

  /// 新建按钮文案；null = 不显示按钮（权限不足时也隐藏）。
  final String? createLabel;

  /// 父页面「返回即刷新」信号：变化时静默重拉当前页。
  final int refreshTick;

  /// 宿主（任务中心大类行 + 小类行）：挂进折叠头随页滚走
  /// （2026-09-24 用户口径「表格完全置顶」）。
  final Widget? externalHeader;

  @override
  ConsumerState<WarehouseStockDocSegment> createState() =>
      _WarehouseStockDocSegmentState();
}

class _WarehouseStockDocSegmentState
    extends ConsumerState<WarehouseStockDocSegment> {
  /// 宿主页路径(创建时捕获), 精准刷新信号只在它就在栈顶时立即重拉。
  String? _hostLocation;

  final _list = PagedListController<StockDocListItem>();
  final Set<String> _selectedIds = {};

  bool get _isOutbound =>
      widget.docType == StockDocType.otherOut ||
      widget.docType == StockDocType.finishedOut;
  bool get _canBatchOutbound =>
      _isOutbound &&
      _seg?.history == false &&
      _seg?.status == 0 &&
      ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove);

  /// 当前选中分段；null = 未选择引导态（不发请求）。
  _StockSegSeg? _seg;

  /// DRAW/WDRAW 出库进度小类；null = 未选择（不附加过滤）。
  int? _issueStatus;

  /// 历史单据段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    _list.keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
    });
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WarehouseStockDocSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick ||
        oldWidget.docType != widget.docType) {
      _selectedIds.clear();
      _list.keyword = widget.keyword;
      if (oldWidget.docType != widget.docType) {
        _list.page = null;
        _seg = null;
        _issueStatus = null;
        _historyTime = const UtenHistoryTimeValue.none();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _reload(1));
    }
  }

  bool get _canCreate =>
      widget.docType.supportsManualDraft &&
      widget.createLabel != null &&
      DocumentPermissionCatalog.stockDocument.allows(
        ref.read(currentPermissionsProvider),
        DocumentPermissionAction.create,
      );

  Future<PagedResult<StockDocListItem>> _fetch() {
    final seg = _seg!;
    final range = seg.history ? _historyTime.range : null;
    final showIssue = !seg.history && widget.docType == StockDocType.draw;
    final sort = _list.sortKey == 'total' ? null : _list.sortKey;
    return ref
        .read(stockDocRepositoryProvider(widget.docType))
        .list(
          page: _list.pageNum,
          filter: StockDocFilter(
            productionReturnRequests:
                widget.productionReturnRequests && !seg.history ? true : null,
            keyword: _list.normalizedKeyword,
            status: seg.history ? null : seg.status,
            issueStatus: showIssue ? _issueStatus : null,
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
            warehouseScope: WarehouseListScope.of(context),
          ),
          sort: sort,
          order: sort == null ? null : _list.sortOrder,
        );
  }

  Future<void> _reload([int? page, bool silent = false]) {
    _selectedIds.clear();
    if (!_shouldLoad) return Future.value();
    return _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);
  }

  Future<void> _openBatch() async {
    if (!_canBatchOutbound ||
        _list.loading ||
        _list.error != null ||
        _selectedIds.isEmpty) {
      return;
    }
    final ids = (_list.page?.items ?? const <StockDocListItem>[])
        .where((d) => d.status == 0 && !d.closed && _selectedIds.contains(d.id))
        .map((d) => d.id)
        .toList();
    if (ids.isEmpty) return;
    if (ids.length == 1) {
      await context.push(
        RoutePath.stockDocDetail(widget.docType.code, ids.single),
      );
      if (mounted) await _reload();
      return;
    }
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WarehouseStockBatchOutboundPage(
          docType: widget.docType,
          documentIds: ids,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  void _selectSeg(_StockSegSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      _issueStatus = null;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _reload(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _reload(1);
  }

  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  List<MasterColumnDef<StockDocListItem>> _columns() {
    final isTransfer = widget.docType == StockDocType.transfer;
    final isDraw = widget.docType == StockDocType.draw;
    return <MasterColumnDef<StockDocListItem>>[
      MasterColumnDef(
        key: 'billNo',
        label: '单据号',
        width: 160,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '日期',
        width: 120,
        type: 'date',
        sortable: true,
        value: (it) => it.billDate == null
            ? null
            : (it.billDate!.length >= 10
                  ? it.billDate!.substring(0, 10)
                  : it.billDate),
      ),
      if (isDraw)
        MasterColumnDef(
          key: 'department',
          label: '领料车间',
          width: 140,
          value: (it) =>
              ref.read(masterNameServiceProvider).department(it.departmentId),
        ),
      MasterColumnDef(
        key: 'warehouse',
        label: '仓库',
        width: 160,
        value: (it) =>
            ref.read(masterNameServiceProvider).warehouse(it.warehouseId),
      ),
      if (isTransfer)
        MasterColumnDef(
          key: 'toWarehouse',
          label: '调入仓',
          width: 160,
          value: (it) =>
              ref.read(masterNameServiceProvider).warehouse(it.toWarehouseId),
        ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 100,
        value: (it) => widget.docType == StockDocType.wdraw
            ? switch (it.status) {
                0 => '待仓库收料',
                1 => '仓库已收料',
                -1 => '已红冲',
                _ => stockStatusLabel(it.status),
              }
            : stockStatusLabel(it.status),
      ),
      if (isDraw)
        MasterColumnDef(
          key: 'issueStatus',
          label: '出库进度',
          width: 110,
          value: (it) => drawIssueStatusLabel(it.issueStatus),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    ref.watch(currentPermissionsProvider);
    ref.watch(masterNameServiceProvider);
    // 详情/编辑页保存、审核、红冲成功都会 bump 本 docType 的 tick：宿主任务中心就在
    // 栈顶时据此重拉；被详情页盖着时由宿主返回时的刷新带着重拉(ADR-108)。
    _hostLocation ??= currentLocationOr(context, '');
    ref.onListRefresh(_hostLocation!, widget.docType.refreshKey, _reload);
    final showIssueStatus = widget.docType == StockDocType.draw;
    final isReturn = widget.docType == StockDocType.wdraw;
    final seg = _seg;
    return ListenableBuilder(
      listenable: _list,
      builder: (context, _) {
        final total = _list.total;
        // 2026-09-24 用户口径「表格完全置顶」：小类行/时间行/总结行全部进
        // 折叠头随页滚走，body 只剩表格（primary 拾取联动控制器）。
        return UtenCollapsingHeaderScrollView(
          collapsingHeader: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.externalHeader != null) ...[
                widget.externalHeader!,
                const SizedBox(height: UtenSpacing.s12),
              ],
              // 小类行 1：单据状态（无「全部」段；末尾历史单据时间门控段）。
              // 进页面不预选（未选不发请求，显示引导占位）。
              // 徽章口径：草稿不计入待办数，各段不挂。
              Padding(
                padding: const EdgeInsets.only(
                  bottom: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: UtenFilterToolbar<_StockSegSeg>(
                  segmentsKey: Key(
                    'stock-doc-segment-status-${widget.docType.code}',
                  ),
                  segments: [
                    UtenFilterSegment(
                      value: const _StockSegSeg.stage(0),
                      label: isReturn ? '待仓库收料' : '草稿',
                      count: isReturn ? widget.pendingReturnCount : null,
                      countForm: UtenSegmentCountForm.actionable,
                    ),
                    UtenFilterSegment(
                      value: const _StockSegSeg.stage(1),
                      label: isReturn ? '仓库已收料' : '已审',
                    ),
                    const UtenFilterSegment(
                      value: _StockSegSeg.stage(-1),
                      label: '红冲',
                    ),
                    const UtenFilterSegment(
                      value: _StockSegSeg.history(),
                      label: '历史单据',
                    ),
                  ],
                  selected: seg == null ? const {} : {seg},
                  onSelectionChanged: _selectSeg,
                ),
              ),
              // 小类行 2（领退料）：出库进度——选中真实状态段后出现；
              // 无「全部进度」段，默认不选 = 不附加过滤。
              if (showIssueStatus && seg != null && !seg.history)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: UtenFilterToolbar<int>(
                    segmentsKey: Key(
                      'stock-doc-segment-issue-${widget.docType.code}',
                    ),
                    segments: const [
                      UtenFilterSegment(value: 0, label: '未出库'),
                      UtenFilterSegment(value: 1, label: '部分出库'),
                      UtenFilterSegment(value: 2, label: '已出完'),
                    ],
                    selected: _issueStatus == null
                        ? const <int>{}
                        : {_issueStatus!},
                    onSelectionChanged: (value) {
                      setState(() => _issueStatus = value);
                      _reload(1);
                    },
                  ),
                ),
              // 历史单据段时间行。
              if (seg?.history == true)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: UtenHistoryTimeFilter(
                    key: Key(
                      'stock-doc-segment-history-time-${widget.docType.code}',
                    ),
                    value: _historyTime,
                    onChanged: _onHistoryTime,
                  ),
                ),
              // 总结行：左「共 N 条」右「新建」。
              Padding(
                padding: const EdgeInsets.only(
                  bottom: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: Row(
                  children: [
                    if (_shouldLoad)
                      Semantics(
                        liveRegion: true,
                        label: '共 $total 张${widget.docType.label}',
                        child: Text(
                          '共 $total 条 · 双击办理',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const Spacer(),
                    if (_canCreate)
                      UtenButton(
                        type: UtenButtonType.tonal,
                        icon: Icons.add_rounded,
                        onPressed: () => context.push(
                          RoutePath.stockDocNew(widget.docType.code),
                        ),
                        child: Text(widget.createLabel!),
                      ),
                  ],
                ),
              ),
            ],
          ),
          body: seg == null
              ? const UtenFilterPlaceholder(
                  message: '在上方选择分类后开始办理',
                  description: '分类默认不选中；历史单据需先选时间段或「全部」',
                )
              : seg.history && _historyTime.isNone
              ? const UtenHistoryTimePlaceholder()
              : MasterDataTableView<StockDocListItem>(
                  // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
                  primary: true,
                  key: Key('stock-doc-segment-table-${widget.docType.code}'),
                  selectable: _canBatchOutbound,
                  rowKeyOf: (d) => d.id,
                  idOf: (d) =>
                      !_list.loading &&
                          _list.error == null &&
                          d.status == 0 &&
                          !d.closed
                      ? d.id
                      : null,
                  selectedIds: _selectedIds,
                  onSelectedIdsChanged: (next) => setState(() {
                    _selectedIds
                      ..clear()
                      ..addAll(next);
                  }),
                  batchActionsBuilder: !_canBatchOutbound
                      ? null
                      : (_, ids) => [
                          UtenButton(
                            key: Key(
                              'stock-doc-batch-outbound-${widget.docType.code}',
                            ),
                            type: UtenButtonType.danger,
                            size: UtenButtonSize.large,
                            icon: Icons.outbound_outlined,
                            onPressed:
                                ids.isEmpty ||
                                    _list.loading ||
                                    _list.error != null
                                ? null
                                : _openBatch,
                            child: Text(l10n.warehouseStockOutboundAction),
                          ),
                        ],
                  bottomContentPadding: _canBatchOutbound
                      ? UtenFloatingActionGroup.scrollClearance
                      : 0,
                  columns: _columns(),
                  items: _list.page?.items ?? const [],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  sortColumn: _list.sortKey == 'total' ? null : _list.sortKey,
                  sortAscending: _list.sortAsc,
                  onSortChange: _onSortChange,
                  onRowTap: (it) => context.push(
                    RoutePath.stockDocDetail(widget.docType.code, it.id),
                  ),
                  isLoading: _list.isLoadingFirst,
                  loadingMore: _list.isLoadingMore,
                  error: _list.error,
                  onRetry: () => _reload(),
                  emptyMessage: seg.history
                      ? '该时间段内暂无${widget.docType.label}'
                      : '暂无${widget.docType.label}',
                  currentPage: _list.currentPage,
                  totalPages: _list.totalPages,
                  onPageChange: (p) => _reload(p),
                ),
        );
      },
    );
  }
}
