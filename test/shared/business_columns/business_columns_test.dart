import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/business_columns/business_columns_row.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/features/finance/models/quote_finance_line_draft.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_revision.dart';

BusinessColumn fee(
  String id,
  String operation,
  String? value, {
  String type = 'AMOUNT',
}) => BusinessColumn(
  id: id,
  name: id,
  operation: operation,
  type: type,
  value: value,
);
String? amount(String base, List<BusinessColumn> columns) =>
    financeExactTrimmed(businessColumnAmount(base, columns));

void main() {
  test('ordered operations use finite decimal values without rounding', () {
    final columns = [
      fee('a', 'ADD', '0.1'),
      fee('b', 'SUBTRACT', '.02'),
      fee('c', 'MULTIPLY', '+2'),
      fee('d', 'DIVIDE', '4.'),
    ];
    expect(amount('0.2', columns), '0.14');
    expect(
      amount('10', [fee('a', 'ADD', '2'), fee('b', 'MULTIPLY', '3')]),
      '36',
    );
    expect(
      amount('10', [fee('b', 'MULTIPLY', '3'), fee('a', 'ADD', '2')]),
      '32',
    );
    expect(
      amount('1', [fee('a', 'DIVIDE', '3'), fee('b', 'DIVIDE', '2')]),
      isNull,
    );
    expect(amount('1', [fee('a', 'DIVIDE', '-0.000')]), isNull);
    expect(amount('1', [fee('a', 'SUBTRACT', '2')]), isNull);
    expect(
      amount('1', [
        fee('a', 'ADD', null),
        fee('b', 'NONE', 'label', type: 'TEXT'),
      ]),
      '1',
    );
  });

  test('server book limits preserve thirty fractional digits', () {
    expect(businessExactDecimal('0.000000000000000000000000000001'), isNotNull);
    expect(businessExactDecimal('0.0000000000000000000000000000001'), isNull);
    expect(businessExactDecimal(List.filled(40, '9').join()), isNotNull);
    expect(
      businessExactDecimal('100000000000000000000000000000000000000000'),
      isNull,
    );
    expect(businessExactDecimal('1e3'), isNull);
  });

  test(
    'sales drafts and copies retain explicit operands and fixed fees block merge',
    () {
      final row = SalesGridRow(amountUsesDiscount: true)
        ..qty.text = '2'
        ..price.text = '10'
        ..discount.text = '0.9';
      final column = fee('packing', 'ADD', '3');
      row.addExtraColumn(column);
      expect(financeExactTrimmed(row.amountExactNotifier.value), '21');
      final restored = SalesGridRow.fromDraft(row.exportDraft());
      final copied = row.clone();
      expect(restored.exportExtraColumns(), row.exportExtraColumns());
      expect(copied.exportExtraColumns(), row.exportExtraColumns());
      expect(restored.extraColumnsPreventMerge, isTrue);
      copied.extraColumnController(column).text = '7';
      expect(row.extraColumnController(column).text, '3');
      expect(
        row.extraColumnsPayload(priceMasked: true).single['value'],
        isNull,
      );
      row.dispose();
      restored.dispose();
      copied.dispose();
    },
  );

  test('new rows inherit definitions without copying another goods fee', () {
    final first = PurchaseGridRow()..addExtraColumn(fee('packing', 'ADD', '5'));
    final next = PurchaseGridRow();
    next.extraColumnController(businessColumnsOf([first]).single).text = '2';
    expect(filledBusinessColumnKeys([next]), {'extra:packing'});
    expect(next.extraColumnsPayload(), [
      {'columnId': 'packing', 'value': '2'},
    ]);
    expect(first.extraColumnsPayload().single['value'], '5');
    final inherited = inheritBusinessColumns(SubcontractGridRow(), [first]);
    expect(inherited.extraColumnsPayload().single['value'], '');
    expect(filledBusinessColumnKeys([inherited]), isEmpty);
    first.dispose();
    next.dispose();
    inherited.dispose();
  });

  test('procurement draft retains row identity and clone starts a new row', () {
    final row = SubcontractGridRow()
      ..documentItemId = 'existing'
      ..addExtraColumn(fee('label', 'NONE', 'A', type: 'TEXT'));
    final restored = SubcontractGridRow.fromDraft(row.exportDraft());
    final copied = row.clone();
    expect(restored.documentItemId, 'existing');
    expect(copied.documentItemId, isNull);
    expect(copied.extraColumnSnapshots.single.value, 'A');
    row.dispose();
    restored.dispose();
    copied.dispose();
  });

  test('finance repricing cannot submit a negative adjusted total', () {
    final draft = QuoteFinanceLineDraft(
      SalesQuoteFinanceLine(
        itemId: 'i',
        qty: '2',
        storedPrice: '10',
        currentMasterPrice: '10',
        discount: '1',
        amount: '5',
        extraColumns: [fee('allowance', 'SUBTRACT', '15')],
      ),
    );
    draft.discount.text = '0.5';
    draft.onDiscountChanged('0.5');
    expect(draft.amountPreview, isNull);
    expect(draft.error, QuoteFinanceLineError.extraAmount);
    expect(draft.valid, isFalse);
    expect(draft.toEdit(), isNull);
    draft.discount.text = '1';
    draft.onDiscountChanged('1');
    expect(draft.valid, isTrue);
    draft.dispose();
  });

  test(
    'finance repricing recalculates frozen fees and revisions highlight them',
    () {
      final draft = QuoteFinanceLineDraft(
        SalesQuoteFinanceLine(
          itemId: 'i',
          qty: '2',
          storedPrice: '10',
          currentMasterPrice: '10',
          discount: '1',
          amount: '25',
          extraColumns: [fee('packing', 'ADD', '5')],
        ),
      );
      draft.discount.text = '0.5';
      draft.onDiscountChanged('0.5');
      expect(financeExactTrimmed(draft.amountPreview), '15');
      final before = FinanceProcurementReviewLine(
        lineNo: 1,
        orderItemId: 'i',
        displaySnapshotComplete: true,
        extraColumns: [fee('packing', 'ADD', '5')],
      );
      final after = FinanceProcurementReviewLine(
        lineNo: 1,
        orderItemId: 'i',
        displaySnapshotComplete: true,
        extraColumns: [fee('packing', 'ADD', '6')],
      );
      expect(
        procurementChangedFields(before, after),
        contains('extra:packing'),
      );
      expect(
        procurementRevisionRows([before], [after]).single.unchanged,
        isFalse,
      );
      draft.dispose();
    },
  );
}
