import 'package:flutter/material.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../features/report/shared/report_total.dart';
import '../../../features/stock/models/stock_query.dart';
import '../../measurement/weight_unit.dart';
import '../../models/paged_result.dart';
import '../../stock_inventory/measurement_hold.dart';

/// Master data is displayed once, apart from warehouse × color balances.
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
    if (page == null || page.items.isEmpty) return const SizedBox.shrink();
    final goods = page.items.first;
    var measurementPending = false;
    String? holdReason;
    for (final row in page.items.where((row) => row.measurementPending)) {
      measurementPending = true;
      holdReason = row.measurementHoldReason;
      if (holdReason == historicalMeasurementHold) break;
    }
    measurementPending =
        measurementPending ||
        page.totals.any(
          (total) =>
              total.key == 'missing_unit_rows' &&
              total.groups.any((group) => group.value > 0),
        );
    final facts = <(String, String?)>[
      ('名称', goods.name),
      ('编号', goods.goodsCode),
      ('所属类型', goods.categoryName),
      ('物料系列', goods.series),
      ('型号', goods.model),
      ('客户型号', goods.cNumber),
      ('规格', goods.spec),
      (
        '基本单位',
        measurementPending ? measurementHoldLabel(holdReason) : goods.unitName,
      ),

      ('货品备注', goods.remark),
    ];
    return Container(
      key: const ValueKey('stock-inventory-context'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              for (final (label, value) in facts)
                if (value?.trim().isNotEmpty == true)
                  Text(
                    '$label：${value?.isNotEmpty == true ? value : '—'}',
                    style: theme.textTheme.bodyMedium,
                  ),
            ],
          ),
          if (showQuantities) ...[
            const SizedBox(height: UtenSpacing.s8),
            if (measurementPending) Text(measurementHoldNotice(holdReason)),
            UtenTotalsSummaryBar(
              key: const ValueKey('stock-scoped-totals'),
              compact: true,
              density: true,
              entries: reportTotalEntries(
                page.totals.where(
                  (t) =>
                      const {
                        'qty',
                        'weight',
                        'weight_unknown_rows',
                        'weight_estimated_rows',
                        'pending_qty',
                        'pending_stock_in_qty',
                      }.contains(t.key) &&
                      !(measurementPending &&
                          const {
                            'qty',
                            'pending_qty',
                            'pending_stock_in_qty',
                          }.contains(t.key)),
                ),
                weightDisplay: weightDisplay,
              ),
            ),
            Wrap(
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
        ],
      ),
    );
  }
}
