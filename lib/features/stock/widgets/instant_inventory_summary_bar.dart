import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        children: [
          Text.rich(
            TextSpan(
              text: '合计库存重量  ',
              style: theme.textTheme.bodySmall,
              children: [
                TextSpan(
                  text: loading
                      ? '统计更新中…'
                      : hasError
                      ? '统计暂不可用'
                      : summary.weightText(weightDisplay),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            key: const Key('instant-inventory-summary-details'),
            onPressed: loading || hasError ? null : onDetails,
            icon: const Icon(Icons.insights_outlined, size: 18),
            label: const Text('查看详情'),
          ),
        ],
      ),
    );
  }
}
