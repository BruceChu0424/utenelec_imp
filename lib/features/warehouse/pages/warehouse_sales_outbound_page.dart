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
import '../models/warehouse_sales_outbound.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';

/// Dedicated warehouse projection for released sales outbound work.
class WarehouseSalesOutboundPage extends ConsumerStatefulWidget {
  const WarehouseSalesOutboundPage({super.key});

  @override
  ConsumerState<WarehouseSalesOutboundPage> createState() =>
      _WarehouseSalesOutboundPageState();
}

class _WarehouseSalesOutboundPageState
    extends ConsumerState<WarehouseSalesOutboundPage> {
  PagedResult<WarehouseSalesOutboundSummary>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  String _status = WarehouseSalesOutboundStatus.pendingPick;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .list(page: page, keyword: _keyword, warehouseWorkStatus: _status);
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
    if (keyword == _keyword) return;
    setState(() => _keyword = keyword);
    _load(1);
  }

  void _selectStatus(String value) {
    if (value == _status) return;
    setState(() => _status = value);
    _load(1);
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
    return Scaffold(
      appBar: UtenAppBar(
        title: '仓库销售出库',
        subtitle: '拣货、异常恢复与交接',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/warehouse'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-sales-outbound-refresh'),
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
                const _WarehouseOutboundBoundaryBanner(),
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
                  child: MasterDataTableView<WarehouseSalesOutboundSummary>(
                    key: const Key('warehouse-sales-outbound-table'),
                    columns: _columns,
                    items: result.items,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: (item) => context.push(
                      '/warehouse/sales-outbound/${Uri.encodeComponent(item.id)}',
                    ),
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
    final label = WarehouseSalesOutboundStatus.label(_status);
    if (_keyword.isNotEmpty) return '没有匹配“$_keyword”的销售出库任务';
    return '暂无$label任务';
  }

  Widget _toolbar(PagedResult<WarehouseSalesOutboundSummary> result) {
    // 全平台统一筛选工具条：仓库作业状态分段 + 胶囊搜索框。分段键沿用原
    // Chip 键前缀 warehouse-sales-outbound-status（原为每个 Chip 一个键，现为整组）。
    return UtenFilterToolbar<String>(
      segmentsKey: const Key('warehouse-sales-outbound-status'),
      searchKey: const Key('warehouse-sales-outbound-search'),
      segments: [
        for (final status in const [
          WarehouseSalesOutboundStatus.pendingPick,
          WarehouseSalesOutboundStatus.picking,
          WarehouseSalesOutboundStatus.picked,
          WarehouseSalesOutboundStatus.exception,
        ])
          UtenFilterSegment(
            value: status,
            label: WarehouseSalesOutboundStatus.label(status),
          ),
      ],
      selected: _status,
      onSelectionChanged: _selectStatus,
      searchHint: '搜索出货单号 / 客户 / 仓库',
      initialSearchValue: _keyword,
      onSearchInputChanged: (_) => _requestVersion++,
      onSearchChanged: _applySearch,
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
      label: '仓库销售出库作业视图，只处理实物拣货、异常恢复和交接。',
      child: Container(
        key: const Key('warehouse-sales-outbound-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          '仓库作业视图 · 只处理服务端已放行任务的实物拣货、异常恢复和交接。'
          '本页不包含商业与财务信息，也不提供销售业务编辑操作。',
          style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}
