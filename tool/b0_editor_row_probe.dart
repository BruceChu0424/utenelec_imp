import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/forms/prepare_editable_grid_rows.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

const _rowCount = 1000;
const _rawQty = '0001.0000';
const _rawPrice = '0012.5000';
const _rawAmount = '0012.5000';
const _rawRate = '1.0000';
const _rawRemark = 'B0 真实行模型原文';

/// Exercises the same cancellable preparation used by document editors.
///
/// The synchronous baseline is retained in the earlier browser evidence. This
/// probe only runs the responsive path; total preparation time includes yields
/// and must not be described as continuous UI occupation. No API/draft is written.
Future<Map<String, Object?>> runB0EditorRowProbe() async {
  // Give the caller's frame sampler a real event turn before the first case.
  await Future<void>.delayed(const Duration(milliseconds: 40));
  final sales = await _salesProbe();
  // Disposal below is sliced; this additional turn separates the two cases.
  await Future<void>.delayed(const Duration(milliseconds: 40));
  final finance = await _financeProbe();
  return {
    'kind': 'responsive-production-editor-row-factories',
    'rowsPerCase': _rowCount,
    'sales': sales,
    'finance': finance,
    'passed': sales['passed'] == true && finance['passed'] == true,
  };
}

Future<Map<String, Object?>> _salesProbe() async {
  final rows = <SalesGridRow>[];
  try {
    final prepare = Stopwatch()..start();
    await prepareEditableGridRows(
      List<int>.generate(_rowCount, (index) => index),
      create: (_) =>
          SalesGridRow(amountUsesDiscount: true, allowPricingInput: true),
      initialize: (row, _) {
        // Use the production controllers and their existing pricing listeners.
        // Raw text also exercises the draft-recovery representation; do not
        // normalise it merely to make this diagnostic cheaper.
        row.qty.text = _rawQty;
        row.weight.text = '1.2500';
        row.price.text = _rawPrice;
        row.machiningPrice.text = '0.2500';
        row.circumference.text = '2.0000';
        row.inboundQty.text = _rawQty;
        row.materialPrice.text = '3.0000';
        row.dieCastPrice.text = '4.0000';
        row.discount.text = _rawRate;
        row.clientModel.text = 'B0-MODEL';
        row.clientGoodsName.text = 'B0 产品';
        row.remark.text = _rawRemark;
      },
      isCurrent: () => true,
      publish: rows.addAll,
      budget: UiWorkBudget(debugLabel: 'editor-row-sales-prepare'),
    );
    prepare.stop();

    var rawPreserved = true;
    var exactAmounts = true;
    var total = 0.0;
    final facts = UiWorkBudget(debugLabel: 'editor-row-sales-facts');
    for (final row in rows) {
      rawPreserved =
          rawPreserved &&
          row.qty.text == _rawQty &&
          row.price.text == _rawPrice &&
          row.discount.text == _rawRate &&
          row.remark.text == _rawRemark;
      exactAmounts =
          exactAmounts &&
          financeExactTrimmed(row.amountExactNotifier.value) == '12.5' &&
          financeExactTrimmed(row.pricing.amountExact) == '12.5';
      total += row.amountValue;
      await facts.checkpoint();
    }
    return {
      'model': 'SalesGridRow',
      'mode': 'amountUsesDiscount=true,allowPricingInput=true',
      'rows': rows.length,
      'fixedTextControllersPerRow': 13,
      'fixedTextControllers': rows.length * 13,
      'totalPrepareMs': prepare.elapsedMicroseconds / 1000,
      'firstQtyRaw': rows.first.qty.text,
      'lastQtyRaw': rows.last.qty.text,
      'firstPriceRaw': rows.first.price.text,
      'lastRemarkRaw': rows.last.remark.text,
      'firstAmountExact': rows.first.amountExactNotifier.value,
      'lastAmountExact': rows.last.amountExactNotifier.value,
      'displayTotal': total,
      'rawPreserved': rawPreserved,
      'allAmountsExact': exactAmounts,
      'passed':
          rows.length == _rowCount &&
          rawPreserved &&
          exactAmounts &&
          total == 12500,
    };
  } finally {
    final cleanup = UiWorkBudget(debugLabel: 'editor-row-sales-dispose');
    for (final row in rows) {
      row.dispose();
      await cleanup.checkpoint();
    }
  }
}

Future<Map<String, Object?>> _financeProbe() async {
  final rows = <FinanceGridRow>[];
  try {
    final prepare = Stopwatch()..start();
    await prepareEditableGridRows(
      List<int>.generate(_rowCount, (index) => index),
      create: (_) => FinanceGridRow(mode: ItemMode.allocate),
      initialize: (row, _) {
        row.setDepartment('b0-department', 'B0 部门');
        row.qty.text = _rawQty;
        row.price.text = _rawPrice;
        // Finance amount is an independent authoritative input. Never replace
        // it with quantity * price just to imitate the Sales row.
        row.amount.text = _rawAmount;
        row.originalAmountSnapshot = _rawAmount;
        row.amountInputSnapshot = row.amount.text;
        row.exchangeRate.text = _rawRate;
        row.writeOff.text = '0';
        row.remark.text = _rawRemark;
      },
      isCurrent: () => true,
      publish: rows.addAll,
      budget: UiWorkBudget(debugLabel: 'editor-row-finance-prepare'),
    );
    prepare.stop();

    var rawPreserved = true;
    var exactAmounts = true;
    var total = 0.0;
    final facts = UiWorkBudget(debugLabel: 'editor-row-finance-facts');
    for (final row in rows) {
      rawPreserved =
          rawPreserved &&
          row.qty.text == _rawQty &&
          row.price.text == _rawPrice &&
          row.amount.text == _rawAmount &&
          row.exchangeRate.text == _rawRate &&
          row.remark.text == _rawRemark;
      exactAmounts =
          exactAmounts &&
          financeExactTrimmed(row.localAmountExactNotifier.value) == '12.5';
      total += row.amountValue;
      await facts.checkpoint();
    }
    return {
      'model': 'FinanceGridRow',
      'mode': 'allocate',
      'rows': rows.length,
      'fixedTextControllersPerRow': 7,
      'fixedTextControllers': rows.length * 7,
      'totalPrepareMs': prepare.elapsedMicroseconds / 1000,
      'firstQtyRaw': rows.first.qty.text,
      'lastQtyRaw': rows.last.qty.text,
      'firstAmountRaw': rows.first.amount.text,
      'lastRemarkRaw': rows.last.remark.text,
      'firstLocalAmountExact': rows.first.localAmountExactNotifier.value,
      'lastLocalAmountExact': rows.last.localAmountExactNotifier.value,
      'displayTotal': total,
      'rawPreserved': rawPreserved,
      'allAmountsExact': exactAmounts,
      'passed':
          rows.length == _rowCount &&
          rawPreserved &&
          exactAmounts &&
          total == 12500,
    };
  } finally {
    final cleanup = UiWorkBudget(debugLabel: 'editor-row-finance-dispose');
    for (final row in rows) {
      row.dispose();
      await cleanup.checkpoint();
    }
  }
}
