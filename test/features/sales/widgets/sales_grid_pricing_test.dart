import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_apply.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/pricing/line_pricing_amount_cell.dart';
import 'package:uten_imp/shared/pricing/line_pricing_controller.dart';

void main() {
  test(
    'sales total reverses discounted price and retains exact draft and copy',
    () {
      final row = SalesGridRow(
        amountUsesDiscount: true,
        allowPricingInput: true,
      );
      row.qty.text = '10000';
      row.discount.text = '0.8';
      row.pricing.totalAmount.text = '100';
      expect(row.price.text, '0.0125');
      expect(row.amountExactNotifier.value, '100');
      expect(row.pricing.totalAmountInput, isNull);

      final restored = SalesGridRow.fromDraft(
        row.exportDraft(),
        allowPricingInput: true,
      );
      final copied = row.clone();
      for (final next in [restored, copied]) {
        expect(next.pricing.mode, LinePricingMode.calculatePrice);
        expect(next.pricing.totalAmount.text, '100');
        next.qty.text = '20000';
        expect(next.price.text, '0.00625');
        expect(next.amountExactNotifier.value, '100');
        next.dispose();
      }
      row.dispose();
    },
  );

  test(
    'reverse calculation respects ordered adjustments and rejects inexact price',
    () {
      final row = SalesGridRow(
        amountUsesDiscount: true,
        allowPricingInput: true,
      );
      row.qty.text = '10';
      row.discount.text = '0.8';
      row.addExtraColumn(
        const BusinessColumn(
          id: 'fee',
          name: '服务费',
          type: 'AMOUNT',
          operation: 'ADD',
          value: '2',
        ),
      );
      row.pricing.totalAmount.text = '10';
      expect(row.price.text, '1');
      expect(row.pricing.validate(), isNull);

      row.qty.text = '3';
      row.discount.text = '1';
      expect(row.price.text, isEmpty);
      expect(row.pricing.validate(), contains('精确单价'));
      expect(row.pricing.totalAmount.text, '10');
      expect(row.amountExactNotifier.value, isNull);
      row.dispose();
    },
  );

  test(
    'source links and current document policy do not restore an editable total',
    () {
      final row = SalesGridRow(allowPricingInput: true);
      row.qty.text = '100';
      row.pricing.totalAmount.text = '1';
      final locked = SalesGridRow.fromDraft(row.exportDraft());
      expect(locked.pricing.mode, LinePricingMode.calculateAmount);
      expect(locked.canEditTotal, isFalse);

      row.orderItemId = 'source-line';
      final linked = SalesGridRow.fromDraft(
        row.exportDraft(),
        allowPricingInput: true,
      );
      expect(linked.canEditTotal, isFalse);
      expect(linked.pricing.mode, LinePricingMode.calculateAmount);
      expect(linked.price.text, '0.01');
      row.dispose();
      locked.dispose();
      linked.dispose();
    },
  );

  test(
    'intake list price preserves decimal text without a double conversion',
    () {
      final row = SalesGridRow.fromIntake(
        const SalesIntakePatchRow(
          goodsId: 'g-1',
          qty: '1',
          listPrice: '1234567890123.4567',
          discount: '1',
        ),
      );
      expect(row.price.text, '1234567890123.4567');
      expect(row.amountExactNotifier.value, '1234567890123.4567');
      row.dispose();
    },
  );

  testWidgets(
    'total column enables free pricing only and masks hidden amounts',
    (tester) async {
      final row = SalesGridRow(allowPricingInput: true);
      addTearDown(row.dispose);
      row.qty.text = '2';
      row.price.text = '10';
      Future<void> pump(SalesDocType type, {bool masked = false}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  final column = salesGridColumns(
                    context: context,
                    onPickGoods: (_) async {},
                    docType: type,
                    colorEntries: const {},
                    unitEntries: const {},
                    priceMasked: masked,
                  ).singleWhere((column) => column.key == 'amount');
                  expect(column.label, contains('总金额'));
                  if (masked) expect(column.frozenTextOf!(row), '***');
                  return SizedBox(
                    width: 300,
                    child: column.cellBuilder(context, row),
                  );
                },
              ),
            ),
          ),
        );
      }

      await pump(SalesDocType.customerShipment);
      expect(find.byType(LinePricingAmountCell), findsOneWidget);
      await pump(SalesDocType.order);
      expect(find.byType(LinePricingAmountCell), findsNothing);
      await pump(SalesDocType.customerShipment, masked: true);
      expect(find.text('***'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      row.outItemId = 'original-shipment';
      await pump(SalesDocType.returnDoc);
      expect(find.byType(LinePricingAmountCell), findsNothing);
    },
  );
}
