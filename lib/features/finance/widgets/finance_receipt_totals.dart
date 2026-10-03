import 'package:flutter/material.dart';

import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../models/finance_decimal.dart';
import 'finance_entry_l10n.dart';
import 'finance_grid_columns.dart';

/// The table's converted amounts are reference totals, never bank facts.
class FinanceReceiptTotals extends StatelessWidget {
  const FinanceReceiptTotals({super.key, required this.controller});

  final UtenEditableGridController<FinanceGridRow> controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.rowsListenable,
    builder: (context, _) {
      final rows = controller.rows;
      return ListenableBuilder(
        listenable: Listenable.merge([
          for (final row in rows) row.localAmountExactNotifier,
        ]),
        builder: (context, _) => UtenTotalsSummaryBar(
          density: true,
          rowCount: rows.length,
          entries: [
            UtenTotalEntry(
              financeEntryText(context, 'receiptCnyTotal'),
              financeExactMoneyDisplay(
                rows.isEmpty
                    ? null
                    : financeExactSumTexts([
                        for (final row in rows)
                          row.localAmountExactNotifier.value,
                      ]),
              ),
              danger: true,
            ),
          ],
        ),
      );
    },
  );
}
