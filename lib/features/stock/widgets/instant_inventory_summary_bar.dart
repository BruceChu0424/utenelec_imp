import 'package:flutter/material.dart';

import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../models/instant_inventory_summary.dart';

/// 页脚只保留重量和详情入口；请求期间不把旧范围合计冒充成新范围。
class InstantInventorySummaryBar extends StatelessWidget {
  const InstantInventorySummaryBar({
    super.key,
    required this.summary,
    required this.weightDisplay,
    required this.onDetails,
    this.loading = false,
    this.hasError = false,
  });

  final InstantInventorySummary summary;
  final WeightDisplay weightDisplay;
  final VoidCallback onDetails;
  final bool loading;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return UtenTotalsSummaryBar(
      compact: true,
      entries: [
        UtenTotalEntry(
          '合计库存重量',
          loading
              ? '统计更新中…'
              : hasError
              ? '统计暂不可用'
              : summary.weightText(weightDisplay),
        ),
      ],
      trailing: TextButton.icon(
        key: const Key('instant-inventory-summary-details'),
        onPressed: loading || hasError ? null : onDetails,
        icon: const Icon(Icons.insights_outlined, size: 18),
        label: const Text('查看详情'),
      ),
    );
  }
}
