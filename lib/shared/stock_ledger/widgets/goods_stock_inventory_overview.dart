import 'package:flutter/material.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../features/report/shared/report_total.dart';
import '../../../features/stock/models/stock_query.dart';
import '../../measurement/weight_unit.dart';
import '../../models/paged_result.dart';

/// Balance-table footer for the selected warehouse and color scope.
/// Quantities come only from the server's full scoped totals, never page sums.
class GoodsStockInventoryOverview extends StatelessWidget {
  const GoodsStockInventoryOverview({
    super.key,
    required this.data,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.weightDisplay,
    this.showQuantities = true,
  });
  final PagedResult<InstantInventoryRow>? data;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final WeightDisplay weightDisplay;
  final bool showQuantities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('正在读取本范围的货品资料与库存概况…')),
          ],
        ),
      );
    }
    if (error != null) {
      return Wrap(
        key: const ValueKey('stock-inventory-context-error'),
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(error!, style: TextStyle(color: theme.colorScheme.error)),
          TextButton(onPressed: onRetry, child: const Text('重新读取库存概况')),
        ],
      );
    }
    final page = data;
    if (page == null) return const SizedBox.shrink();
    if (!showQuantities) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenTotalsSummaryBar(
          key: const ValueKey('stock-scoped-totals'),
          compact: true,
          density: true,
          entries: reportTotalEntries(
            page.totals.where(
              (t) => const {
                'qty',
                'weight',
                'weight_unknown_rows',
                'weight_estimated_rows',
                'pending_qty',
                'pending_stock_in_qty',
              }.contains(t.key),
            ),
            weightDisplay: weightDisplay,
          ),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 16,
          runSpacing: 4,
          children: [
            for (final row in page.items)
              if ((row.moreQty ?? 0) != 0)
                Text(
                  '多排数量（全局生产计划·${row.colorName ?? '无颜色'}）：${row.moreQty?.toString() ?? '—'}（计划行单位）',
                ),
          ],
        ),
      ],
    );
  }
}
