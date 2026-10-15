import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/task_form_drafts.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/drafts/task_form_draft_recovery_notice.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../models/warehouse_task_form_drafts.dart';
import '../repositories/warehouse_quality_result_repository.dart';
import '../widgets/warehouse_quality_slice_table.dart'
    show warehouseQualityDateTime;
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';

/// 品质部检查结果：原「IQC 合格待入库」+「IQC 不合格实物退回」的合并任务中心。
/// 与预计到货任务中心同款表格工作台——列表按收货单聚合作业状态（等待检查结果 /
/// 全部合格待入库 / 部分合格 / 全部不合格需退回 / 已完结），作业状态列整格底色
/// （ADR-169：黄/绿/橙/红/灰五档互区分，与详情页头部徽章同一份映射）；
/// 可多选批量入库（整批同事务），双击行进入完整详情页办理入库或登记退回。
///
/// 2026-09-03 分类范式收口：来源大类行不再有「全部来源」段，状态小类行不再有
/// 「全部」段；两行默认都不选（不加载，引导占位），末尾新增「历史记录」段
///（时间段/全部时间门控，未选时间不请求）。
class WarehouseQualityResultsPage extends ConsumerStatefulWidget {
  const WarehouseQualityResultsPage({
    super.key,
    this.embedded = false,
    this.externalHeader,
    this.externalKeyword,
    this.externalRefreshTick,
  });

  /// 嵌入态（2026-09-24 仓库任务中心合并）：作为合并页（/warehouse/tasks）
  /// 「品质检查结果」大类的正文——不渲染 Scaffold/AppBar/页面容器与搜索框
  /// （搜索与刷新由宿主页承担），页内来源行/状态行原样保留。
  final bool embedded;

  /// 宿主（合并页大类行）：挂进折叠头随页滚走（2026-09-24 用户口径
  /// 「表格完全置顶」，置顶后只剩表格自身工具条）。
  final Widget? externalHeader;

  /// 宿主页搜索词（嵌入态非 null 时隐藏自身搜索框并直接采用）。
  final String? externalKeyword;

  /// 宿主页刷新信号（嵌入态变化时静默重拉当前页）。
  final int? externalRefreshTick;

  @override
  ConsumerState<WarehouseQualityResultsPage> createState() =>
      _WarehouseQualityResultsPageState();
}

/// 状态小类分段值：真实作业状态或历史记录哨兵。
class _QStatusSeg {
  const _QStatusSeg.all() : status = null, history = false;
  const _QStatusSeg.stage(WarehouseQualityWorkStatus this.status)
    : history = false;
  const _QStatusSeg.history([this.status]) : history = true;

  final WarehouseQualityWorkStatus? status;
  final bool history;

  @override
  bool operator ==(Object other) =>
      other is _QStatusSeg &&
      other.status == status &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

class _WarehouseQualityResultsPageState
    extends ConsumerState<WarehouseQualityResultsPage> {
  PagedResult<WarehouseQualityResultTask>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  int _statusCountRequestVersion = 0;

  // 作业阶段保留为办理入口；采购/委外共用同一任务表和行级动作，来源改由
  // 表头筛选。未筛选来源时走服务端 ALL，不因默认只选一个来源漏掉另一来源。
  WarehouseIqcStockInReceiptType? _receiptType;
  _QStatusSeg? _statusSeg = const _QStatusSeg.all();

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.all();
  String _keyword = '';

  /// 状态分段计数（后端全量口径）；null = 尚未返回，分段显示 '—'。
  Map<WarehouseQualityWorkStatus, int>? _statusCounts;

  /// 表头排序 + 收货单号列值筛选 + facets 桶 + 防串台代数
  /// （2026-09-25 单号列统一，共享状态见 MasterServerColumnFilters）；
  /// 排序列 key 见 [_kSortFields]，null = 服务端默认序。
  final _columnFilters = MasterServerColumnFilters();

  /// 表格多选：键为「receiptType:receiptId」，跨页保留。
  Set<String> _selectedIds = {};

  bool get _shouldLoad {
    final seg = _statusSeg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  /// 入库确认：与旧 IQC 待入库详情同口径——查看 + 确认双权限。
  bool get _canConfirmStockIn {
    if (ref.read(authenticatedScopeProvider)?.readOnly == true) return false;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseIqcStockInView) &&
        permissions.contains(Perm.warehouseIqcStockInConfirm);
  }

  /// 登记实物退回：V440 拒收案件的仓库退回凭证动作权限。
  bool get _canRecordReturn {
    if (ref.read(authenticatedScopeProvider)?.readOnly == true) return false;
    if (!locationAllowedFor(
      ref.read(currentPermissionsProvider),
      false,
      RouteName.warehouseIqcReturns,
    )) {
      return false;
    }
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.procurementIqcRejectionRecordReturn);
  }

  /// 先入库后检(V596)：查看 + 先入库上架双权限(与确认入库相互独立)。
  bool get _canPreStockIn {
    if (ref.read(authenticatedScopeProvider)?.readOnly == true) return false;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseIqcStockInView) &&
        permissions.contains(Perm.warehouseIqcStockInBeforeInspection);
  }

  /// 等待检查结果的收货单先落库位：进逐行上架页，回来重拉列表。
  Future<void> _openPreStockIn(WarehouseQualityResultTask task) async {
    if (!_canPreStockIn || !task.hasPreStockableLines) return;
    final drafts = qualityStockInTaskDrafts(
      ref.read(formDraftsProvider),
      task.receiptTypeValue,
      task.receiptId,
    );
    if (drafts.isNotEmpty) {
      await resumeTaskFormDraft(context, ref, drafts);
      if (mounted) await _load(_result?.page ?? 1);
      return;
    }
    final done = await context.push<bool>(
      RouteName.warehouseQualityPreStockIn(
        task.receiptTypeValue,
        task.receiptId,
      ),
    );
    if (!mounted) return;
    if (done == true) await _load(_result?.page ?? 1);
  }

  @override
  void initState() {
    super.initState();
    // 全来源与全部作业是明确的默认范围；徽章只报告工作量，不代用户收窄。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshStatusCounts();
      _load(1);
    });
  }

  /// 生效搜索词：嵌入态由宿主页（合并页）传入，自身搜索框隐藏。
  String get _effectiveKeyword => widget.externalKeyword ?? _keyword;

  @override
  void didUpdateWidget(covariant WarehouseQualityResultsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 嵌入态：宿主页搜索词/刷新信号变化 → 静默重拉当前页（与独立页搜索一致）。
    if (widget.externalKeyword != oldWidget.externalKeyword ||
        (widget.externalRefreshTick ?? 0) !=
            (oldWidget.externalRefreshTick ?? 0)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

  /// 仓库任务中心选的仓(ADR-149)；没选 = 本人默认范围(服务端强制)。范围变化时任务中心推进
  /// externalRefreshTick, 本页随之重拉列表与计数。
  String? get _scopeWarehouseId =>
      ref.read(warehouseTaskScopeProvider).warehouseId;

  /// 状态小类计数（后端全量口径；null = 尚未返回，分段按钮显示 '—'）。
  /// 独立于列表加载：进页面（全来源）/ 切换来源时主动刷新，列表加载时联动刷新。
  void _refreshStatusCounts() {
    final version = ++_statusCountRequestVersion;
    final receiptType = _receiptType;
    final keyword = _effectiveKeyword;
    ref
        .read(warehouseQualityResultRepositoryProvider)
        .statusCounts(
          receiptType: receiptType,
          keyword: keyword.isEmpty ? null : keyword,
          scopeWarehouseId: _scopeWarehouseId,
        )
        .then((counts) {
          if (mounted && version == _statusCountRequestVersion) {
            setState(() => _statusCounts = counts);
          }
        })
        .catchError((_) {});
  }

  void _selectStatus(_QStatusSeg seg) {
    if (seg == _statusSeg) return;
    setState(() {
      _statusSeg = seg;
      _selectedIds = {};
      _result = null;
      ++_requestVersion;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.all();
    });
    if (!seg.history || !_historyTime.isNone) _load(1);
  }

  void _selectWorkStatusFilter(String? value) {
    final normalized = value?.trim().toUpperCase();
    final parsed = WarehouseQualityWorkStatus.values
        .where((status) => status.apiValue == normalized)
        .firstOrNull;
    final history = _statusSeg?.history == true;
    final status = parsed?.isCompleted == history ? parsed : null;
    // A cleared/obsolete header value means every work status; never use the
    // model's unknown-value fallback (completed) as a query filter.
    _selectStatus(
      history
          ? _QStatusSeg.history(status)
          : status == null
          ? const _QStatusSeg.all()
          : _QStatusSeg.stage(status),
    );
  }

  void _selectType(WarehouseIqcStockInReceiptType? type) {
    if (_receiptType == type) return;
    setState(() {
      _receiptType = type;
      // 来源是独立表头筛选，保留已选作业阶段、历史日期及其他列条件。
      _selectedIds = {};
      _result = null;
      ++_requestVersion;
      // 切换来源后旧计数口径失效，清空待新值（避免显示上一来源的数字）。
      _statusCounts = null;
    });
    _refreshStatusCounts();
    _load(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _load(1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (normalized == _keyword) return;
    setState(() => _keyword = normalized);
    _load(1);
  }

  Future<void> _load(int page) async {
    if (!_shouldLoad) return;
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(warehouseQualityResultRepositoryProvider);
      final seg = _statusSeg!;
      final range = seg.history ? _historyTime.range : null;
      final result = await repo.list(
        page: page,
        view: seg.history
            ? WarehouseTaskView.history
            : WarehouseTaskView.active,
        receiptType: _receiptType,
        workStatus: seg.status,
        keyword: _effectiveKeyword.isEmpty ? null : _effectiveKeyword,
        dateFrom: range == null ? null : ChinaDateTime.formatDate(range.start),
        dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
        sort: _kSortFields[_columnFilters.sortColumn],
        order: _columnFilters.sortColumn == null
            ? null
            : (_columnFilters.sortAscending ? 'asc' : 'desc'),
        billNo: _columnFilters['billNo'],
        scopeWarehouseId: _scopeWarehouseId,
      );
      // 状态计数失败不阻断列表（分段按钮降级为 '—'）。
      _refreshStatusCounts();
      // 单号 facets 与列表同口径（2026-09-25 单号列统一）；失败静默（下拉降级为空）。
      unawaited(_loadBillNoFacets());
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '品质检查结果加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 表头排序键 → 服务端 sort 参数（2026-09-25 单号列统一；未列出的列不可排序）。
  static const _kSortFields = <String, String>{'billNo': 'billNo'};

  /// 表头排序变化：服务端重排整个结果集，回第 1 页（勾选跨页保留，不清）。
  void _onSortChange(String? column, bool ascending) {
    final next = column != null && _kSortFields.containsKey(column)
        ? column
        : null;
    if (next == _columnFilters.sortColumn &&
        (next == null || ascending == _columnFilters.sortAscending)) {
      return;
    }
    _columnFilters.handleSortChanged(
      next,
      ascending,
      onChanged: () {
        if (mounted) setState(() {});
        _load(1);
      },
    );
  }

  /// 收货单号 facets（2026-09-25 单号列统一）：与列表同过滤口径
  /// （不含单号列自身值筛选）。
  Future<void> _loadBillNoFacets() {
    final seg = _statusSeg;
    if (seg == null) return Future.value();
    final range = seg.history ? _historyTime.range : null;
    return _columnFilters.loadFacets(
      () async => {
        'billNo': await ref
            .read(warehouseQualityResultRepositoryProvider)
            .billNoFacets(
              view: seg.history
                  ? WarehouseTaskView.history
                  : WarehouseTaskView.active,
              receiptType: _receiptType,
              workStatus: seg.status,
              keyword: _effectiveKeyword.isEmpty ? null : _effectiveKeyword,
              dateFrom: range == null
                  ? null
                  : ChinaDateTime.formatDate(range.start),
              dateTo: range == null
                  ? null
                  : ChinaDateTime.formatDate(range.end),
              scopeWarehouseId: _scopeWarehouseId,
            ),
      },
      onLoaded: () {
        if (mounted) setState(() {});
      },
    );
  }

  int? _statusCount(WarehouseQualityWorkStatus status) {
    final counts = _statusCounts;
    if (counts == null) return null;
    return counts[status] ?? 0;
  }

  List<WarehouseQualityResultTask> get _pageTasks =>
      _result?.items ?? const <WarehouseQualityResultTask>[];

  WarehouseQualityResultTask? _taskById(String id) {
    for (final task in _pageTasks) {
      if (_taskId(task) == id) return task;
    }
    return null;
  }

  static String _taskId(WarehouseQualityResultTask task) =>
      '${task.receiptTypeValue}:${task.receiptId}';

  /// 当前选中且仍有待入库切片的任务（批量入库目标）。
  List<WarehouseQualityResultTask> get _selectedStockInTasks => [
    for (final id in _selectedIds)
      if (_taskById(id) case final task?
          when task.pendingSliceCount > 0 &&
              task.workStatus != WarehouseQualityWorkStatus.completed)
        task,
  ];

  /// 多选批量入库（2026-09-12 弹窗改页）：进批量入库页——所选任务的放行切片
  /// 集中成一张表，可勾选、可改数量/库位，整批同事务提交。
  Future<void> _openBatchStockIn([WarehouseQualityResultTask? single]) async {
    final targets = single == null
        ? _selectedStockInTasks
        : (single.pendingSliceCount > 0
              ? [single]
              : <WarehouseQualityResultTask>[]);
    if (targets.isEmpty) {
      context.appWarning('请先选择有「品质放行待入库」的任务');
      return;
    }
    if (!_canConfirmStockIn) {
      context.appWarning(
        '当前账号没有仓库入库确认权限（需要 IQC 待入库查看 + 确认入库），'
        '请联系管理员在权限管理中授权',
      );
      return;
    }
    // 只选中一张时不进批量页——那是一张单据，直接进它自己的详情页办理
    // （用户 2026-09-11：「只选中一个的情况，点击批量入库也应该去到对应的详情页」）。
    // 详情页信息全、能逐行核对，批量页是为「跨多张单一次过」才存在的。
    if (targets.length == 1) {
      await _openDetail(targets.single);
      return;
    }
    final done = await context.push<bool>(
      RouteName.warehouseQualityBatchStockIn,
      extra: targets,
    );
    if (!mounted) return;
    if (done == true) {
      setState(() => _selectedIds = {});
      await _load(_result?.page ?? 1);
    }
  }

  /// 双击行 / 右键「查看检查结果」：进入完整详情页（单据信息 + 逐行判定表 +
  /// 就地办理入库 / 退回 / 查看历史），返回后重拉列表。
  List<FormDraft> _taskDrafts(WarehouseQualityResultTask task) =>
      _statusSeg?.history == true || task.workStatus.isCompleted
      ? const []
      : qualityStockInTaskDrafts(
          ref.read(formDraftsProvider),
          task.receiptTypeValue,
          task.receiptId,
        );

  Future<void> _openDetail(WarehouseQualityResultTask task) async {
    if (_loading) return;
    final drafts = _taskDrafts(task);
    if (drafts.isNotEmpty) {
      await resumeTaskFormDraft(context, ref, drafts);
      if (mounted) await _load(_result?.page ?? 1);
      return;
    }
    await context.push(
      RouteName.warehouseQualityResultDetail(
        task.receiptTypeValue,
        task.receiptId,
      ),
    );
    if (!mounted) return;
    await _load(_result?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(authenticatedScopeProvider);
    ref.watch(formDraftsProvider);
    final result =
        _result ??
        const PagedResult<WarehouseQualityResultTask>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 0,
        );
    // 正文（来源/状态分段 + 表格）：独立页与嵌入态共用一份。
    // 2026-09-24 用户口径「表格完全置顶」：分段行/错误行进折叠头随页滚走，
    // body 只剩表格（primary 拾取联动控制器）。
    final bodyContent = Padding(
      padding: widget.embedded
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
      child: UtenCollapsingHeaderScrollView(
        collapsingHeader: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.externalHeader != null) ...[
              widget.externalHeader!,
              const SizedBox(height: UtenFilterRow.rowGap),
            ],
            _buildToolbars(result),
            if (_error != null && result.items.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              Semantics(
                liveRegion: true,
                child: Text(
                  '刷新失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
          ],
        ),
        body: !_shouldLoad
            ? (_statusSeg != null && _statusSeg!.history
                  ? const UtenHistoryTimePlaceholder()
                  : const UtenFilterPlaceholder(
                      message: '在上方选择作业阶段后开始办理',
                      description: '采购与委外任务一起显示，可在表头筛选来源类型',
                    ))
            : MasterDataTableView<WarehouseQualityResultTask>(
                tableKey:
                    'features.warehouse.pages.warehouse_quality_results_page.WarehouseQualityResultsPageState.build.1',
                // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
                primary: true,
                key: const Key('warehouse-quality-result-table'),
                requiredLeadingColumnKeys: const ['workStatus'],
                columns: _columns,
                items: result.items,
                // 收货单号表头值筛选（2026-09-25 单号列统一）：服务端分组计数桶。
                facets: {
                  'workStatus': [
                    for (final status
                        in WarehouseQualityWorkStatus.values.where(
                          (status) =>
                              status.isCompleted ==
                              (_statusSeg?.history == true),
                        ))
                      MasterFacetBucket(
                        value: status.apiValue,
                        label: status.label,
                        count: 0,
                      ),
                  ],
                  'billNo': _columnFilters.bucketOf('billNo'),
                  'receiptType': [
                    for (final type in WarehouseIqcStockInReceiptType.values)
                      MasterFacetBucket(
                        value: type.apiValue,
                        label: type.label,
                        count: 0,
                      ),
                  ],
                },
                nullCounts: const {},
                filters: {
                  'workStatus': _statusSeg?.status?.apiValue,
                  'billNo': _columnFilters['billNo'],
                  'receiptType': _receiptType?.apiValue,
                },
                // 表头排序走服务端（2026-09-25 单号列统一）。
                sortColumn: _columnFilters.sortColumn,
                sortAscending: _columnFilters.sortAscending,
                onSortChange: _onSortChange,
                onFilterChanged: (key, value) {
                  if (key == 'workStatus') {
                    _selectWorkStatusFilter(value);
                    return;
                  }
                  if (key == 'receiptType') {
                    _selectType(WarehouseIqcStockInReceiptType.tryParse(value));
                    return;
                  }
                  if (key == 'billNo') {
                    _columnFilters.handleFilterChanged(
                      key,
                      value,
                      onChanged: () {
                        if (mounted) setState(() {});
                        _load(1);
                      },
                    );
                  }
                },
                selectable: true,
                idOf: _taskId,
                rowKeyOf: _taskId,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: (next) =>
                    setState(() => _selectedIds = next),
                batchActionsBuilder: _batchActions,
                onRowTap: _openDetail,
                rowMenuBuilder: _rowMenu,
                isLoading: _loading && _result == null,
                loadingMore: _loading && _result != null,
                error: result.items.isEmpty ? _error : null,
                onRetry: () => _load(result.page),
                emptyMessage: _emptyMessage,
                currentPage: result.page,
                totalPages: result.totalPages,
                paginationScope: (
                  _effectiveKeyword,
                  _receiptType,
                  _statusSeg,
                  _historyTime,
                ),
                onPageChange: _load,
              ),
      ),
    );
    // 嵌入态：宿主页（仓库任务中心合并页）负责 Scaffold/AppBar/搜索/刷新。
    if (widget.embedded) return bodyContent;
    return Scaffold(
      appBar: UtenAppBar(
        title: '品质部检查结果',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          UtenAppBarActionButton(
            key: const Key('warehouse-quality-result-refresh'),
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && _result != null,
            onPressed: _loading ? null : () => _load(1),
          ),
        ],
      ),
      body: SafeArea(child: UtenContentContainer.wide(child: bodyContent)),
    );
  }

  String get _emptyMessage {
    if (_effectiveKeyword.isNotEmpty) {
      return '没有匹配“$_effectiveKeyword”的检查结果任务';
    }
    if (_statusSeg?.history == true) return '该时间段内暂无检查结果记录';
    return switch (_statusSeg?.status) {
      WarehouseQualityWorkStatus.waitingInspection => '没有等待检查结果的收货单',
      WarehouseQualityWorkStatus.allPassed => '没有全部合格待入库的任务',
      WarehouseQualityWorkStatus.partialPassed => '没有部分合格的任务',
      WarehouseQualityWorkStatus.returnRequired => '没有待退回的不合格任务',
      WarehouseQualityWorkStatus.completed => '暂无已完结记录',
      _ => '目前没有品质检查结果任务',
    };
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final stockInCount = _selectedStockInTasks.length;
    return [
      UtenButton(
        key: const Key('warehouse-quality-result-batch-stock-in'),
        size: UtenButtonSize.large,
        type: UtenButtonType.danger,
        icon: Icons.move_to_inbox_rounded,
        onPressed: _loading ? null : () => _openBatchStockIn(),
        child: Text(stockInCount > 0 ? '批量入库($stockInCount 单)' : '批量入库'),
      ),
    ];
  }

  List<UtenContextMenuEntry> _rowMenu(WarehouseQualityResultTask task) {
    return [
      UtenMenuItem(
        label: '查看检查结果详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _openDetail(task),
      ),
      if (task.pendingSliceCount > 0)
        UtenMenuItem(
          label: '本单入库',
          icon: Icons.move_to_inbox_rounded,
          onTap: () => _openBatchStockIn(task),
        ),
      if (task.pendingReturnCount > 0 && _canRecordReturn)
        UtenMenuItem(
          label: '登记实物退回',
          icon: Icons.assignment_return_outlined,
          onTap: () => _openDetail(task),
        ),
      // 先入库后检(V596)：品质没空时先把货落到库位；合格自动转正，不合格从库位退回。
      if (task.hasPreStockableLines && _canPreStockIn)
        UtenMenuItem(
          label: '先入库上架(待检)',
          icon: Icons.shelves,
          onTap: () => _openPreStockIn(task),
        ),
    ];
  }

  Widget _buildToolbars(PagedResult<WarehouseQualityResultTask> result) {
    final seg = _statusSeg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded && seg?.history != true)
          const TaskDraftRecoveryNotice(
            scope: FormDraftCategoryScope(
              module: BadgeModule.warehouse,
              routePrefix: '/warehouse/quality-results/',
            ),
          ),
        // 作业阶段对应等待检查、入库、退回等不同办理入口，保留一行；
        // 来源由表头筛选，计数与列表均采用当前来源范围（未选=全来源）。
        // 计数形态：红徽章只挂需要仓库下一步操作的状态（全部合格/部分合格/
        // 不合格退回，见 WarehouseQualityWorkStatus.actionable）；「等待结果」
        // 货已经收进来了、结论在品质部手上, 仓库这一档还没完结但也不用动手
        // -> 黄色进行中徽章(ADR-100); 「已完结」「历史记录」不传 count。
        UtenFilterToolbar<_QStatusSeg>(
          segmentsKey: const Key('warehouse-quality-result-status'),
          autoSelectBadge: false,
          searchKey: const Key('warehouse-quality-result-search'),
          segments: [
            const UtenFilterSegment(value: _QStatusSeg.all(), label: '进行中'),
            for (final status in WarehouseQualityWorkStatus.values.where(
              (status) => !status.isCompleted,
            ))
              UtenFilterSegment(
                value: _QStatusSeg.stage(status),
                label: status.shortLabel,
                count: status.isCompleted ? null : _statusCount(status),
                countForm: switch (status) {
                  WarehouseQualityWorkStatus.waitingInspection =>
                    UtenSegmentCountForm.inProgress,
                  // 已完结不带数, 形态只是占位。
                  WarehouseQualityWorkStatus.completed =>
                    UtenSegmentCountForm.browsing,
                  _ => UtenSegmentCountForm.actionable,
                },
              ),
            const UtenFilterSegment(
              value: _QStatusSeg.history(),
              label: '历史单据',
            ),
          ],
          selected: seg == null
              ? const {}
              : {seg.history ? const _QStatusSeg.history() : seg},
          onSelectionChanged: _selectStatus,
          searchHint: widget.embedded ? null : '搜索收货单 / 供应商 / 仓库 / 货品',
          initialSearchValue: widget.embedded ? null : _keyword,
          onSearchInputChanged: widget.embedded
              ? null
              : (_) => _requestVersion++,
          onSearchChanged: widget.embedded ? null : _applyKeyword,
          trailing: Semantics(
            liveRegion: true,
            label: '共 ${result.total} 项品质检查结果任务',
            child: Text(
              '共 ${result.total} 项 · 单击勾选，双击详情',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (seg?.history == true) ...[
          const SizedBox(height: UtenFilterRow.rowGap),
          UtenHistoryTimeFilter(
            key: const Key('warehouse-quality-result-history-time'),
            value: _historyTime,
            onChanged: _onHistoryTime,
          ),
        ],
      ],
    );
  }

  List<MasterColumnDef<WarehouseQualityResultTask>> get _columns => [
    MasterColumnDef(
      key: 'workStatus',
      label: '状态',
      width: 190,
      // 先入库后检(V596)：等待结果时补「已上架 n 行」，仓库一眼看出实物已在库位。
      value: (task) {
        final drafts = _taskDrafts(task);
        final source =
            task.receiptType == WarehouseIqcStockInReceiptType.purchase
            ? '采购'
            : '委外';
        return drafts.isEmpty
            ? '$source · ${task.workStatusLabel}'
            : '$source · ${taskDraftStatus(drafts)}';
      },
      // 2026-09-27 用户口径「表格状态列整格底色」（ADR-169 重定档位）：
      // 等待结果=黄 / 全部合格=绿 / 部分合格=橙 / 不合格退回=红 / 已完结=灰，
      // 与详情页头部徽章同一份映射（见模型 warehouseQualityWorkStatusBadgeType）。
      cellColor: (context, task) => utenStatusBadgeCellColor(
        _taskDrafts(task).isEmpty
            ? warehouseQualityWorkStatusBadgeType(task.workStatus)
            : UtenStatusBadgeType.neutral,
      ),
    ),
    // 2026-10-08 用户口径「状态或进度列默认放最前」：品质结论是本表的第二条
    // 行级结果列（合格/部分/退回汇总），紧跟作业状态前置。
    MasterColumnDef(
      key: 'verdict',
      label: '品质结论',
      width: 200,
      value: (task) => task.verdictLabel,
    ),
    MasterColumnDef(
      key: 'receiptType',
      label: '来源类型',
      width: 100,
      value: (task) => task.receiptType.label,
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '收货单号',
      width: 160,
      sortable: true, // 2026-09-25 单号列统一：表头排序 + 值筛选。
      value: (task) => task.billNo ?? '—',
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '收货日期',
      width: 110,
      type: 'date',
      value: (task) => task.billDate ?? '—',
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 180,
      value: (task) => task.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '收货参考仓',
      width: 130,
      value: (task) => task.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'pendingSliceCount',
      label: '待入库切片',
      width: 110,
      type: 'number',
      value: (task) =>
          task.pendingSliceCount > 0 ? '${task.pendingSliceCount} 个' : '—',
    ),
    MasterColumnDef(
      key: 'pendingReturnCount',
      label: '待退回笔数',
      width: 104,
      type: 'number',
      value: (task) =>
          task.pendingReturnCount > 0 ? '${task.pendingReturnCount} 笔' : '—',
    ),
    MasterColumnDef(
      key: 'lastActivityAt',
      label: '最近动态',
      width: 150,
      value: (task) => warehouseQualityDateTime(task.lastActivityAt),
    ),
  ];
}
