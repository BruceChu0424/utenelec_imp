import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/warehouse_document_history.dart';
import '../repositories/warehouse_document_history_repository.dart';

/// Warehouse-owned read-only history list.
///
/// No purchase/subcontract document widget is reused here: columns are an
/// explicit physical-fact allow-list and the server DTO contains no commercial
/// values or business-document actions.
class WarehouseDocumentHistoryListPage extends ConsumerStatefulWidget {
  const WarehouseDocumentHistoryListPage({super.key, required this.type});

  final WarehouseDocumentHistoryType type;

  @override
  ConsumerState<WarehouseDocumentHistoryListPage> createState() =>
      _WarehouseDocumentHistoryListPageState();
}

class _WarehouseDocumentHistoryListPageState
    extends ConsumerState<WarehouseDocumentHistoryListPage> {
  PagedResult<WarehouseDocumentHistorySummary>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  String? _status;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  void _onSearchInput(String _) {
    // Invalidate a slower response immediately, before the search bar's
    // debounced committed value starts the next request.
    _requestVersion++;
  }

  void _applySearch(String value) {
    final keyword = value.trim();
    if (keyword == _keyword) return;
    setState(() => _keyword = keyword);
    _load(1);
  }

  void _selectStatus(String? value) {
    if (value == _status) return;
    setState(() => _status = value);
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
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.type.title,
        subtitle: '仓库实物视图',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/warehouse'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: Key('warehouse-history-refresh-${widget.type.segment}'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && _result != null,
              onPressed: _loading ? null : () => _load(result.page),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PhysicalViewBanner(type: widget.type),
                const SizedBox(height: UtenSpacing.s12),
                _toolbar(result),
                if (_error != null && result.items.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
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
            ),
          ),
        ),
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
    // 全平台统一筛选工具条：状态分段 + 胶囊搜索框。分段键沿用原 Chip 键前缀
    // warehouse-history-status-<segment>（原为每个 Chip 一个键，现为整组）。
    return UtenFilterToolbar<String?>(
      segmentsKey: Key('warehouse-history-status-${widget.type.segment}'),
      searchKey: Key('warehouse-history-search-${widget.type.segment}'),
      segments: [
        for (final option in widget.type.statusFilters)
          UtenFilterSegment(value: option.value, label: option.label),
      ],
      selected: _status,
      onSelectionChanged: _selectStatus,
      searchHint: '搜索单号 / 来源单号 / 货品 / 仓库 / 往来单位',
      initialSearchValue: _keyword,
      onSearchInputChanged: _onSearchInput,
      onSearchChanged: _applySearch,
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
