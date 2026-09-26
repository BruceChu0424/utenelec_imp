// 仓库实物单据历史（可嵌入只读视图）：列是显式的实物事实允许清单，服务端 DTO
// 不含商业值或业务单据动作；不复用采购/委外单据组件。
//
// 2026-09-01 起任务中心分段（采购/委外入库的「收货历史」、委外出库的「出仓历史」）
// 内嵌本组件；独立路由 /warehouse/history/:type 由对应页面以 embedded=false 包一层
// 继续承接（含详情深链）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/warehouse_document_history.dart';
import '../repositories/warehouse_document_history_repository.dart';

class WarehouseDocumentHistoryView extends ConsumerStatefulWidget {
  const WarehouseDocumentHistoryView({
    super.key,
    required this.type,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
    this.externalHeader,
    this.dateFrom,
    this.dateTo,
  });

  final WarehouseDocumentHistoryType type;

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在任务中心分段内（状态分段 + 表格，无搜索框）。
  final bool embedded;

  /// 宿主（任务中心大类行/小类行/复合分段行）：挂进折叠头随页滚走
  /// （2026-09-24 用户口径「表格完全置顶」）。
  final Widget? externalHeader;

  /// 业务日期范围（yyyy-MM-dd；「历史单据」时间门控模式下由
  /// WarehouseHistoryGate 下发，变化即重拉）。
  final String? dateFrom;
  final String? dateTo;

  @override
  ConsumerState<WarehouseDocumentHistoryView> createState() =>
      _WarehouseDocumentHistoryViewState();
}

class _WarehouseDocumentHistoryViewState
    extends ConsumerState<WarehouseDocumentHistoryView> {
  PagedResult<WarehouseDocumentHistorySummary>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  String? _status;
  bool _statusSelected = false; // 进页面不预选（不选=不过滤）
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(WarehouseDocumentHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick ||
        oldWidget.dateFrom != widget.dateFrom ||
        oldWidget.dateTo != widget.dateTo) {
      _keyword = widget.keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

  void _onSearchInput(String _) {
    _requestVersion++;
  }

  void _applySearch(String value) {
    final keyword = value.trim();
    if (keyword == _keyword) return;
    setState(() => _keyword = keyword);
    _load(1);
  }

  void _selectStatus(String? value) {
    if (value == _status && _statusSelected) return;
    setState(() {
      _status = value;
      _statusSelected = true;
    });
    _load(1);
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(warehouseDocumentHistoryRepositoryProvider(widget.type))
          .list(
            page: page,
            keyword: _keyword,
            status: _status,
            dateFrom: widget.dateFrom,
            dateTo: widget.dateTo,
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
        _error = '${widget.type.title}加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _openDetail(WarehouseDocumentHistorySummary item) {
    context.push(widget.type.detailPath(item.id));
  }

  @override
  Widget build(BuildContext context) {
    final result =
        _result ??
        const PagedResult<WarehouseDocumentHistorySummary>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    // 2026-09-24 用户口径「表格完全置顶」：状态行/错误行进折叠头随页滚走，
    // body 只剩表格（primary 拾取联动控制器）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.externalHeader != null) ...[
            widget.externalHeader!,
            const SizedBox(height: UtenSpacing.s12),
          ],
          _toolbar(result),
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
        ],
      ),
      body: MasterDataTableView<WarehouseDocumentHistorySummary>(
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        key: Key('warehouse-history-table-${widget.type.segment}'),
        columns: _columns,
        items: result.items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        onRowTap: _openDetail,
        isLoading: _loading && _result == null,
        loadingMore: _loading && _result != null,
        error: result.items.isEmpty ? _error : null,
        onRetry: () => _load(result.page),
        emptyMessage: _emptyMessage,
        currentPage: result.page,
        totalPages: result.totalPages,
        onPageChange: _load,
      ),
    );
  }

  String get _emptyMessage {
    if (_keyword.isNotEmpty) {
      return '没有匹配“$_keyword”的${widget.type.documentLabel}';
    }
    if (_status != null) return '当前状态下暂无${widget.type.documentLabel}';
    return widget.type.emptyMessage;
  }

  Widget _toolbar(PagedResult<WarehouseDocumentHistorySummary> result) {
    return UtenFilterToolbar<String?>(
      segmentsKey: Key('warehouse-history-status-${widget.type.segment}'),
      searchKey: widget.embedded
          ? null
          : Key('warehouse-history-search-${widget.type.segment}'),
      segments: [
        for (final option in widget.type.statusFilters)
          UtenFilterSegment(value: option.value, label: option.label),
      ],
      selected: _statusSelected ? {_status} : const {},
      onSelectionChanged: _selectStatus,
      searchHint: widget.embedded ? null : '搜索单号 / 来源单号 / 货品 / 仓库 / 往来单位',
      initialSearchValue: widget.embedded ? null : _keyword,
      onSearchInputChanged: widget.embedded ? null : _onSearchInput,
      onSearchChanged: widget.embedded ? null : _applySearch,
      trailing: Semantics(
        liveRegion: true,
        label: '共 ${result.total} 张${widget.type.documentLabel}',
        child: Text(
          '共 ${result.total} 张 · 双击打开仓库详情',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  List<MasterColumnDef<WarehouseDocumentHistorySummary>> get _columns => [
    MasterColumnDef(
      key: 'billNo',
      label: '单据号',
      width: 170,
      value: (item) => item.displayBillNo,
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '业务日期',
      width: 116,
      type: 'date',
      value: (item) => item.billDate ?? '—',
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (item) => item.statusLabel,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '往来单位',
      width: 180,
      value: (item) => item.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '仓库',
      width: 140,
      value: (item) => item.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'sourceDocNo',
      label: '来源单据',
      width: 170,
      value: (item) => item.sourceDocNo ?? '—',
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '明细行',
      width: 82,
      type: 'number',
      value: (item) => item.itemCount.toString(),
    ),
    MasterColumnDef(
      key: 'makerName',
      label: '制单人',
      width: 120,
      value: (item) => item.makerName ?? '—',
    ),
    MasterColumnDef(
      key: 'approverName',
      label: '审核人',
      width: 120,
      value: (item) => item.approverName ?? '—',
    ),
  ];
}
