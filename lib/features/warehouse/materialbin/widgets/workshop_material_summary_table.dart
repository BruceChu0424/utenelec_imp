import 'package:flutter/material.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/buttons/uten_refresh_button.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';

/// Plain complete summaries own no row controllers or editable cells. Opening
/// a product is an explicit detail read; local scrolling never requests data.
class WmProductSummaryTable extends StatelessWidget {
  const WmProductSummaryTable({
    super.key,
    required this.tableKey,
    required this.items,
    required this.openedIds,
    required this.onOpen,
    required this.onRetry,
    this.loading = false,
    this.error,
    this.pending = false,
    this.enabled = true,
  });

  final String tableKey;
  final List<Map<String, dynamic>> items;
  final Set<String> openedIds;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final VoidCallback onRetry;
  final bool loading;
  final String? error;
  final bool pending;
  final bool enabled;

  @override
  Widget build(
    BuildContext context,
  ) => MasterDataTableView<Map<String, dynamic>>(
    tableKey: tableKey,
    items: items,
    rowKeyOf: (row) => row['productGoodsId'] as String?,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    virtualized: true,
    expensiveRowMounts: false,
    showPaginationControls: false,
    isLoading: loading && items.isEmpty,
    isRefreshing: loading && items.isNotEmpty,
    error: items.isEmpty ? error : null,
    refreshError: items.isEmpty ? null : error,
    onRetry: onRetry,
    toolbarActions: [UtenRefreshButton(busy: loading, onRefresh: onRetry)],
    emptyMessage: pending ? '没有需要认料的在产产品' : '没有要准备的产品',
    columns: [
      for (final field in <(String, String, double)>[
        ('productCode', '产品编号', 125),
        ('productName', '产品', 180),
        ('productSpec', '规格', 130),
        if (pending) ('workshopNames', '在产车间', 160),
        if (pending) ('segmentCount', '在产工单', 100),
        if (!pending) ('legacyMaterial', '老库材质', 140),
        if (!pending) ('status', '状态', 110),
      ])
        MasterColumnDef<Map<String, dynamic>>(
          key: field.$1,
          label: field.$2,
          width: field.$3,
          filterFromRows: true,
          value: (row) {
            final value = row[field.$1];
            if (field.$1 == 'status') {
              return switch (value) {
                'WEIGHED' => '已填单重',
                'CHOSEN' => '已选料，待填单重',
                'NOT_FROM_STORE' => '不用内料仓的料',
                _ => '待准备',
              };
            }
            return value is List ? value.join('、') : value?.toString() ?? '';
          },
        ),
      MasterColumnDef<Map<String, dynamic>>(
        key: 'edit',
        label: '操作',
        width: 110,
        value: (row) =>
            openedIds.contains(row['productGoodsId']) ? '已打开' : '编辑',
        cellBuilder: (_, row) => UtenButton(
          key: ValueKey('wm-summary-open-${row['productGoodsId']}'),
          type: UtenButtonType.secondary,
          onPressed: enabled && !openedIds.contains(row['productGoodsId'])
              ? () => onOpen(row)
              : null,
          child: Text(openedIds.contains(row['productGoodsId']) ? '已打开' : '编辑'),
        ),
      ),
    ],
  );
}
