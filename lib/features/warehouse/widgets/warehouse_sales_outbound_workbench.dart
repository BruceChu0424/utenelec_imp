// 销售出库工作台（可嵌入）：仓库侧对财务已放行的销售出货一步确认出库。
//
// 2026-09-01 起「出库任务中心 · 销售出库」分段内嵌本组件（embedded=true 时不带
// 搜索框——关键字由任务中心页级工具条统一下发）。独立路由 /warehouse/sales-outbound
// 由 warehouse_sales_outbound_page.dart 以 embedded=false 包一层 Scaffold 继续承接。
//
// 2026-09-03 统一范式：状态小类行默认不选（未选不发请求，显示引导占位）；
// 末尾新增「历史单据」段——时间门控（时间段/全部，选定后才按日期加载，
// 不限作业状态）。
//
// 2026-09-20 小类行计数: 待出库挂红徽章(与父分类「销售出库」同源同数)、已出库挂中性
// 括号数、历史单据不挂(已出库本身就是历史, 不数两遍); 计数来自
// GET /warehouse/sales-outbound/counts 一次请求(warehouse_sales_outbound_count_provider.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_sales_outbound.dart';
import '../pages/warehouse_sales_outbound_batch_page.dart';
import '../providers/warehouse_sales_outbound_count_provider.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import 'warehouse_sales_outbound_table_columns.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

/// 状态小类分段值：真实作业状态或历史单据哨兵。
class _SalesOutboundSeg {
  const _SalesOutboundSeg.stage(String this.status) : history = false;
  const _SalesOutboundSeg.history() : status = null, history = true;

  final String? status;
  final bool history;
  @override
  bool operator ==(Object other) =>
      other is _SalesOutboundSeg &&
      other.status == status &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

/// 「仓库作业」表头筛选桶：固定枚举（服务端 warehouseWorkStatus 参数已在，
/// 与销售出货同五个状态）；count=0 表示不强调计数。分段条之外的三个状态
///（取消/红冲/迁移异常）只能从表头进入。
const List<MasterFacetBucket> _workStatusFacets = [
  MasterFacetBucket(
    value: WarehouseSalesOutboundStatus.pendingPick,
    count: 0,
    label: '待出库',
  ),
  MasterFacetBucket(
    value: WarehouseSalesOutboundStatus.shipped,
    count: 0,
    label: '已出库',
  ),
  MasterFacetBucket(value: 'CANCELLED', count: 0, label: '已取消'),
  MasterFacetBucket(value: 'REVERSED', count: 0, label: '已红冲'),
  MasterFacetBucket(value: 'LEGACY_PENDING', count: 0, label: '历史迁移异常'),
];

class WarehouseSalesOutboundWorkbench extends ConsumerStatefulWidget {
  const WarehouseSalesOutboundWorkbench({
    super.key,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
  });

  /// 任务中心页级搜索关键字（embedded 模式生效；300ms 防抖后的值）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在出库任务中心分段内（状态分段 + 表格，无搜索框）。
  final bool embedded;

  @override
  ConsumerState<WarehouseSalesOutboundWorkbench> createState() =>
      _WarehouseSalesOutboundWorkbenchState();
}

class _WarehouseSalesOutboundWorkbenchState
    extends ConsumerState<WarehouseSalesOutboundWorkbench> {
  PagedResult<WarehouseSalesOutboundSummary>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  bool _searchPending = false;
  final Set<String> _selectedIds = {};

  /// 当前选中分段；null = 未选择引导态（不发请求）。
  _SalesOutboundSeg? _seg;

  /// 表头「仓库作业」列筛选（固定枚举桶）；非空时优先于分段的状态口径。
  String? _workStatusColumnFilter;

  /// 历史单据段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    // 默认不选分类：进页面不发列表请求。
  }

  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void didUpdateWidget(WarehouseSalesOutboundWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _keyword = widget.keyword;
      _selectedIds.clear();
      _loading = _shouldLoad;
      ++_requestVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

  Future<void> _load(int page) async {
    if (!mounted || !_shouldLoad) return;
    final version = ++_requestVersion;
    final seg = _seg!;
    final range = seg.history ? _historyTime.range : null;
    setState(() {
      _loading = true;
      _error = null;
      _selectedIds.clear();
    });
    try {
      final result = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .list(
            page: page,
            keyword: _keyword,
            warehouseWorkStatus:
                _workStatusColumnFilter ?? (seg.history ? null : seg.status),
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
            scope: WarehouseListScope.of(context),
          );
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
        _error = '销售出库任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _applySearch(String value) {
    final keyword = value.trim();
    if (keyword == _keyword && !_searchPending) return;
    setState(() {
      _keyword = keyword;
      _searchPending = false;
    });
    _load(1);
  }

  void _onSearchInput(String value) {
    if (value.trim() == _keyword && !_searchPending) return;
    setState(() {
      _keyword = value.trim();
      _searchPending = true;
      _selectedIds.clear();
      ++_requestVersion;
    });
  }

  void _selectSeg(_SalesOutboundSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      _selectedIds.clear();
      _result = null;
      _error = null;
      ++_requestVersion;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
      // 分段与表头筛选用同一服务端参数：切段时清表头状态桶。
      _workStatusColumnFilter = null;
    });
    if (!seg.history || !_historyTime.isNone) _load(1);
  }

  /// 表头筛选回调：仓库作业固定枚举桶；值优先于分段状态回传，重拉回第 1 页。
  void _onColumnFilterChanged(String key, String? value) {
    if (key != 'warehouseWorkStatus') return;
    setState(() => _workStatusColumnFilter = value);
    _load(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _load(1);
  }

  WarehouseSalesOutboundAction? get _batchAction =>
      _seg?.status == WarehouseSalesOutboundStatus.pendingPick
      ? WarehouseSalesOutboundAction.confirmShipment
      : null;

  bool _canSelect(WarehouseSalesOutboundSummary item) =>
      !_loading &&
      !_searchPending &&
      _error == null &&
      _batchAction != null &&
      item.warehouseWorkStatus == _seg?.status &&
      warehouseSalesOutboundPrimaryAction(item) == _batchAction;

  Future<void> _openBatch(Set<String> ids) async {
    final action = _batchAction;
    if (_loading || action == null) return;
    final targets = (_result?.items ?? const <WarehouseSalesOutboundSummary>[])
        .where((item) => ids.contains(item.id) && _canSelect(item))
        .toList();
    if (targets.isEmpty || targets.length != ids.length) return;
    if (targets.length == 1) {
      await _openDetail(targets.single);
      return;
    }
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            WarehouseSalesOutboundBatchPage(targets: targets, action: action),
      ),
    );
    if (!mounted) return;
    await _load(_result?.page ?? 1);
  }

  Future<void> _openDetail(WarehouseSalesOutboundSummary item) async {
    if (_loading || _searchPending || _error != null) return;
    await context.push(
      '/warehouse/sales-outbound/${Uri.encodeComponent(item.id)}',
    );
    if (mounted) await _load(_result?.page ?? 1);
  }

  List<Widget> _batchActions(BuildContext context, Set<String> ids) {
    final action = _batchAction;
    if (action == null) return const [];
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    return [
      UtenButton(
        key: const Key('warehouse-sales-outbound-open-batch'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.fact_check_outlined,
        onPressed: _loading || _error != null || ids.isEmpty
            ? null
            : () => _openBatch(ids),
        child: Text(
          l10n.warehouseOutboundBatchAction(
            warehouseSalesOutboundActionLabel(l10n, action),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final result =
        _result ??
        const PagedResult<WarehouseSalesOutboundSummary>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(result),
        if (_seg?.history == true) ...[
          const SizedBox(height: UtenSpacing.s8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
            child: UtenHistoryTimeFilter(
              key: const Key('warehouse-sales-outbound-history-time'),
              value: _historyTime,
              onChanged: _onHistoryTime,
            ),
          ),
        ],
        if (_error != null && result.items.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Expanded(
          child: _seg == null
              ? const UtenFilterPlaceholder(
                  message: '在上方选择分类后开始办理',
                  description: '分类默认不选中；历史单据需先选时间段或「全部」',
                )
              : _seg!.history && _historyTime.isNone
              ? const UtenHistoryTimePlaceholder()
              : MasterDataTableView<WarehouseSalesOutboundSummary>(
                  key: const Key('warehouse-sales-outbound-table'),
                  columns: _columns,
                  items: result.items,
                  facets: const {'warehouseWorkStatus': _workStatusFacets},
                  nullCounts: const {},
                  filters: {'warehouseWorkStatus': _workStatusColumnFilter},
                  onFilterChanged: _onColumnFilterChanged,
                  onRowTap: _openDetail,
                  selectable: _batchAction != null,
                  idOf: (item) => _canSelect(item) ? item.id : null,
                  rowKeyOf: (item) => item.id,
                  selectedIds: _selectedIds,
                  onSelectedIdsChanged: (ids) {
                    if (_loading || _searchPending || _error != null) return;
                    setState(
                      () => _selectedIds
                        ..clear()
                        ..addAll(ids),
                    );
                  },
                  batchActionsBuilder: _batchAction == null
                      ? null
                      : _batchActions,
                  isLoading: _loading && _result == null,
                  loadingMore: _loading && _result != null,
                  error: result.items.isEmpty ? _error : null,
                  onRetry: () => _load(result.page),
                  emptyMessage: _emptyMessage,
                  currentPage: result.page,
                  totalPages: result.totalPages,
                  onPageChange: _load,
                ),
        ),
      ],
    );
  }

  String get _emptyMessage {
    if (_keyword.isNotEmpty) return '没有匹配“$_keyword”的销售出库任务';
    if (_seg?.history == true) return '该时间段内暂无销售出库单';
    final label = _seg?.status == null
        ? ''
        : WarehouseSalesOutboundStatus.label(_seg!.status!);
    return '暂无$label任务';
  }

  Widget _toolbar(PagedResult<WarehouseSalesOutboundSummary> result) {
    // 全平台统一筛选工具条：仓库作业状态分段 + 末尾「历史单据」时间门控段。
    // 分段键沿用 warehouse-sales-outbound-status（独立页既有测试锚点不变）；
    // 默认不选（未选=引导占位，不发请求）。
    // 小类行计数(2026-09-20 用户口径: 父分类有红徽章, 小类也要有数):
    // 待出库 = 红徽章(等仓库动手, 与父分类「销售出库」/hub 卡同源同数);
    // 已出库 = 中性括号数(已完结, 供掂量); 历史单据不挂——已出库本身就是历史,
    // 再挂一次是同一批单在一行里数两遍. 数字随徽章汇总带回(刷新期间带住旧值),
    // 汇总未到/无权为 null 时两种形态都不渲染数字(不把未知伪装成 0).
    final counts = ref.watch(warehouseSalesOutboundCountsProvider);
    return UtenFilterToolbar<_SalesOutboundSeg>(
      segmentsKey: const Key('warehouse-sales-outbound-status'),
      searchKey: widget.embedded
          ? null
          : const Key('warehouse-sales-outbound-search'),
      segments: [
        UtenFilterSegment(
          value: const _SalesOutboundSeg.stage(
            WarehouseSalesOutboundStatus.pendingPick,
          ),
          label: WarehouseSalesOutboundStatus.label(
            WarehouseSalesOutboundStatus.pendingPick,
          ),
          count: counts?.pendingPick,
          countForm: UtenSegmentCountForm.actionable,
        ),
        UtenFilterSegment(
          value: const _SalesOutboundSeg.stage(
            WarehouseSalesOutboundStatus.shipped,
          ),
          label: WarehouseSalesOutboundStatus.label(
            WarehouseSalesOutboundStatus.shipped,
          ),
          count: counts?.shipped,
        ),
        const UtenFilterSegment(
          value: _SalesOutboundSeg.history(),
          label: '历史单据',
        ),
      ],
      selected: _seg == null ? const {} : {_seg!},
      onSelectionChanged: _selectSeg,
      searchHint: widget.embedded ? null : '搜索出货单号 / 客户 / 仓库',
      initialSearchValue: widget.embedded ? null : _keyword,
      onSearchInputChanged: widget.embedded ? null : _onSearchInput,
      onSearchChanged: widget.embedded ? null : _applySearch,
      trailing: Semantics(
        liveRegion: true,
        label: '共 ${result.total} 项销售出库任务',
        child: Text(
          '共 ${result.total} 项 · 双击进入仓库详情',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  List<MasterColumnDef<WarehouseSalesOutboundSummary>> get _columns => [
    MasterColumnDef(
      key: 'billNo',
      label: '出货单号',
      width: 170,
      value: (item) => item.billNo ?? '—',
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '业务日期',
      width: 116,
      type: 'date',
      value: (item) => item.billDate ?? '—',
    ),
    MasterColumnDef(
      key: 'clientName',
      label: '客户',
      width: 190,
      value: (item) => item.clientName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '仓库',
      width: 150,
      value: (item) => item.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseWorkStatus',
      label: '仓库作业',
      width: 160,
      value: (item) => item.statusLabel,
    ),
    MasterColumnDef(
      key: 'nextStep',
      label: '下一步',
      width: 240,
      value: (item) =>
          WarehouseSalesOutboundStatus.nextStep(item.warehouseWorkStatus),
    ),
  ];
}
