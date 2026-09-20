import 'package:flutter/material.dart';

import '../../components/data_display/uten_totals_summary_bar.dart';
import '../models/historical_receipt_facts.dart';

/// Original line facts only: a header total never fills a missing cost or currency amount.
class HistoricalReceiptTotals extends StatelessWidget {
  const HistoricalReceiptTotals({
    super.key,
    required this.lines,
    required this.showAmounts,
    required this.currencyLabel,
    this.subcontract = false,
  });

  final List<HistoricalReceiptLineFacts> lines;
  final bool showAmounts;
  final String currencyLabel;
  final bool subcontract;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<HistoricalReceiptLineFacts>>{};
    for (final line in lines) {
      groups.putIfAbsent(line.unitId ?? '', () => []).add(line);
    }
    return UtenTotalsSummaryBar(
      density: true,
      compact: true,
      entries: [
        for (final group in groups.entries)
          UtenTotalEntry(
            group.key.isEmpty ? '单据数量' : '单据数量（${group.value.first.unitName}）',
            group.key.isEmpty
                ? '未知（单位未记载）'
                : historicalReceiptTotal(
                    group.value.map((line) => line.quantity),
                  ),
          ),
        if (showAmounts) ...[
          UtenTotalEntry(
            subcontract
                ? '原币对应值（$currencyLabel，仅已核验）'
                : '原币行金额合计（$currencyLabel）',
            historicalReceiptTotal(lines.map((line) => line.original)),
            danger: true,
          ),
          UtenTotalEntry(
            subcontract ? '本币成本合计（STotal）' : '本币行金额合计',
            historicalReceiptTotal(lines.map((line) => line.local)),
          ),
        ],
      ],
    );
  }
}
