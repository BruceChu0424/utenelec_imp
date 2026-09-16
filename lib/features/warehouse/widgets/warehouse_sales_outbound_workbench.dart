// 销售出库工作台（可嵌入）：仓库侧对财务已放行的销售出货一步确认出库。
//
// 2026-09-01 起「出库任务中心 · 销售出库」分段内嵌本组件（embedded=true 时不带
// 搜索框——关键字由任务中心页级工具条统一下发）。独立路由 /warehouse/sales-outbound
// 由 warehouse_sales_outbound_page.dart 以 embedded=false 包一层 Scaffold 继续承接。
//
// 2026-09-03 统一范式：状态小类行默认不选（未选不发请求，显示引导占位）；
// 末尾新增「历史单据」段——时间门控（时间段/全部，选定后才按日期加载，
// 不限作业状态）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_sales_outbound.dart';
import '../pages/warehouse_sales_outbound_batch_page.dart';
import '../providers/warehouse_sales_outbound_count_provider.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import 'warehouse_sales_outbound_table_columns.dart';

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

class WarehouseSalesOutboundWorkbench extends ConsumerStatefulWidget {
  const WarehouseSalesOutboundWorkbench({
    super.key,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
    this.showBoundaryBanner = true,
  });

  /// 任务中心页级搜索关键字（embedded 模式生效；300ms 防抖后的值）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在出库任务中心分段内（状态分段 + 表格，无搜索框）。
  final bool embedded;

  /// 是否显示仓库作业边界提示条（任务中心分段内空间有限可关）。
  final bool showBoundaryBanner;

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
            warehouseWorkStatus: seg.history ? null : seg.status,
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
          );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      // 列表口径变化后同步角标（确认出库会减少待办数）。
      ref.invalidate(warehouseSalesOutboundPendingCountProvider);
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
    });
    if (!seg.history || !_historyTime.isNone) _load(1);
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
        if (widget.showBoundaryBanner) ...[
          const _WarehouseOutboundBoundaryBanner(),
          const SizedBox(height: UtenSpacing.s12),
        ],
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
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
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
    return UtenFilterToolbar<_SalesOutboundSeg>(
      segmentsKey: const Key('warehouse-sales-outbound-status'),
      searchKey: widget.embedded
          ? null
          : const Key('warehouse-sales-outbound-search'),
      segments: [
        for (final status in [
          WarehouseSalesOutboundStatus.pendingPick,
          WarehouseSalesOutboundStatus.shipped,
        ])
          UtenFilterSegment(
            value: _SalesOutboundSeg.stage(status),
            label: WarehouseSalesOutboundStatus.label(status),
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

class _WarehouseOutboundBoundaryBanner extends StatelessWidget {
  const _WarehouseOutboundBoundaryBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '仓库销售出库作业视图，只处理实物出库。',
      child: Container(
        key: const Key('warehouse-sales-outbound-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          '仓库作业视图 · 财务放行后核对货品、数量与库位，一步确认出库。'
          '本页不包含商业与财务信息，也不提供销售业务编辑操作。',
          style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}
