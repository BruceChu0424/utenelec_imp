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
    this.showBanner = true,
  });

  final WarehouseDocumentHistoryType type;

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在任务中心分段内（状态分段 + 表格，无搜索框）。
  final bool embedded;

  /// 是否显示「仓库实物视图」提示条。
  final bool showBanner;

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
        oldWidget.refreshTick != widget.refreshTick) {
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
          .list(page: page, keyword: _keyword, status: _status);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showBanner) ...[
          _PhysicalViewBanner(type: widget.type),
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
        Expanded(
          child: MasterDataTableView<WarehouseDocumentHistorySummary>(
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
        ),
      ],
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

class _PhysicalViewBanner extends StatelessWidget {
  const _PhysicalViewBanner({required this.type});

  final WarehouseDocumentHistoryType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '仓库实物视图。仅显示数量、重量、当前建议库位、质量、来源与经办人员。',
      child: Container(
        key: Key('warehouse-history-physical-banner-${type.segment}'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(type.icon, color: theme.colorScheme.primary),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '仓库实物视图',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '${type.description}。库位为当前货品主档建议，不是历史库位快照。'
                    '本页不包含商业与财务信息，也不提供跨部门业务操作。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.45,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
