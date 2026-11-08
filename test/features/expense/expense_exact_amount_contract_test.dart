import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/widgets/expense_editable_items.dart';
import 'package:uten_imp/core/utils/rmb_amount.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/models/expense_invoice.dart';
import 'package:uten_imp/features/expense/widgets/expense_item_columns.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';

void main() {
  const raw =
      '1234567890123456789012345678901234567890.123456789012345678901234';
  test(
    'current editable grid keeps full raw values through copy/recovery and uppercase never changes them',
    () {
      final row = ExpenseGridRow()
        ..amount.text = raw
        ..description.text = '完整原数';
      expect(row.validationError, isNull);
      expect(row.toItem().toCreateJson()['amount'], raw);
      final copy = row.clone();
      final restored = ExpenseGridRow.restore(copy.exportDraft(), id: copy.id);
      expect(restored.amount.text, raw);
      expect(restored.toItem().toCreateJson()['amount'], raw);
      expect(rmbCapitalExact(raw), contains(raw));
      row.amount.text = '0.000000000000000000000001';
      expect(row.amountUnits, BigInt.one);
      row.amount.text = '1e-25';
      expect(row.validationError?.column, 'amount');
      row.amount.text = '1e40';
      expect(row.validationError?.column, 'amount');
      row.dispose();
      copy.dispose();
      restored.dispose();
    },
  );
  test('item read/copy/draft/create/column use original 40/24 text', () {
    final item = ExpenseItem.fromJson({
      'id': 'one',
      'category': 'TRAVEL',
      'amount': 1.2345678901234568e39,
      'amountExact': raw,
      'date': '2026-09-01',
      'description': '原始费用',
    });
    expect(item.amountText, raw);
    expect(item.withPlatformFields({'version': 0}).amountText, raw);
    expect(item.toCreateJson()['amount'], raw);
    // Look the amount column up by key: a2054a2d0 placed the currency column
    // after it, so it is no longer the last column.
    expect(
      expenseItemColumns
          .singleWhere((column) => column.key == 'amount')
          .exactValueOf!(item),
      raw,
    );
    expect(
      financeExactTrimmed(
        financeExactSumTexts([item.amountText, '0.000000000000000000000001']),
      ),
      '1234567890123456789012345678901234567890.123456789012345678901235',
    );
  });
  test(
    'invoice/OCR original facts and input JSON never take the rounded double alias',
    () {
      final data = {
        'id': 'invoice',
        'lineNo': 1,
        'invoiceType': 'DIGITAL',
        'invoiceNo': '24312000000012345678',
        'totalAmount': 1.2345678901234568e39,
        'totalAmountExact': raw,
        'amountExclTax': '100.12',
        'taxAmount': '0.0034',
        'checkState': 'AMOUNTS_MATCH',
      };
      final invoice = ExpenseClaimInvoice.fromJson(data);
      expect(invoice.totalAmountText, raw);
      expect(RecognizedInvoice.fromJson(data).totalAmountText, raw);
      expect(
        ExpenseClaimInvoiceInput(
          type: ExpenseInvoiceType.digital,
          invoiceNo: invoice.invoiceNo,
          totalAmount: invoice.totalAmount,
          totalAmountExact: invoice.totalAmountText,
        ).toJson()['totalAmount'],
        raw,
      );
      final within = ExpenseClaimInvoice.fromJson({
        ...data,
        'totalAmountExact': '100.1235',
      });
      expect(within.reconciliationDifferenceText, '-0.0001');
      expect(within.checkStateText, contains('在0.01容差内'));
      expect(within.checkStateText, contains('-0.0001'));
    },
  );
}
