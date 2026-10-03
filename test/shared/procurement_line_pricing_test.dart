import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/pricing/line_pricing_controller.dart';
import 'package:uten_imp/shared/models/procurement_commercial_terms.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test(
    'explicit total consumes learned-price marker even when price stays equal',
    () {
      final row = PurchaseGridRow(supportsTotalInput: true)
        ..goods = const GoodsOption(id: 'goods')
        ..supplierId = 'supplier-a'
        ..currencyId = 'CNY'
        ..unitId = 'unit';
      addTearDown(row.dispose);
      row.taxRate.text = '0';
      row.qty.text = '100';
      row.price.text = '2';
      row.markTermsAutofilled('price', '2');
      row.watchDefaultPrice(
        price: row.price,
        supplier: row.supplierIdNotifier,
        context: const ProcurementPriceContext(
          supplierId: 'supplier-a',
          currencyId: 'CNY',
          unitId: 'unit',
          taxRate: 0,
        ),
        goodsId: 'goods',
        currentGoodsId: () => row.goods?.id,
        currentColorId: () => row.colorId,
        currentUnitId: () => row.unitId,
      );
      row.pricing.setMode(LinePricingMode.calculatePrice);
      expect(row.price.text, '2');
      expect(row.termsAutofilled, isNot(contains('price')));
      row.supplierId = 'supplier-b';
      expect(row.price.text, '2');
      expect(row.pricing.totalAmountInput, '200');
    },
  );

  test(
    'additional fee edits preserve base through invalid input, clear and clone',
    () {
      final row = SubcontractGridRow(supportsTotalInput: true);
      addTearDown(row.dispose);
      row.qty.text = '3000';
      row.pricing.totalAmount.text = '100';
      const fee = BusinessColumn(
        id: 'fee',
        name: '包装费',
        type: 'AMOUNT',
        operation: 'ADD',
        value: '5',
      );
      row.addExtraColumn(fee);
      expect(row.pricing.totalAmountInput, '100');
      expect(row.amountExactNotifier.value, '105');
      row.extraColumnController(fee).text = 'abc';
      expect(row.pricing.validate(), isNotNull);
      row.extraColumnController(fee).text = '10';
      expect(row.pricing.validate(), isNull);
      expect(row.amountExactNotifier.value, '110');
      expect(row.pricing.totalAmountInput, '100');
      row.pricing.totalAmount.text = '120';
      expect(row.pricing.totalAmountInput, '110');
      row.extraColumnController(fee).clear();
      expect(row.amountExactNotifier.value, '110');
      final clone = row.clone();
      final restored = SubcontractGridRow.fromDraft(row.exportDraft());
      addTearDown(clone.dispose);
      addTearDown(restored.dispose);
      expect(clone.pricing.totalAmountInput, '110');
      expect(restored.pricing.totalAmountInput, '110');
      expect(clone.amountExactNotifier.value, '110');
      expect(restored.amountExactNotifier.value, '110');
    },
  );
  test(
    'purchase total and reference price survive clone and draft independently',
    () {
      final row = PurchaseGridRow(supportsTotalInput: true);
      addTearDown(row.dispose);
      row.qty.text = '3000';
      row.pricing.totalAmount.text = '100';
      final clone = row.clone();
      final recovered = PurchaseGridRow.fromDraft(row.exportDraft());
      addTearDown(clone.dispose);
      addTearDown(recovered.dispose);
      for (final copy in [clone, recovered]) {
        expect(copy.price.text, '0.0333333333');
        expect(copy.pricing.totalAmountInput, '100');
        expect(copy.amountExactNotifier.value, '100');
      }
      clone.qty.text = '6000';
      expect(clone.pricing.totalAmountInput, '100');
      expect(clone.price.text, '0.0166666666');
      expect(row.qty.text, '3000');
      expect(row.pricing.totalAmountInput, '100');
      recovered.price.text = '0.05';
      expect(recovered.pricing.totalAmountInput, isNull);
      expect(recovered.amountExactNotifier.value, '150');
    },
  );

  test('subcontract final total reverses fee before saving the base total', () {
    final row = SubcontractGridRow(supportsTotalInput: true);
    addTearDown(row.dispose);
    row.addExtraColumn(
      const BusinessColumn(
        id: 'fee',
        name: '包装费',
        type: 'AMOUNT',
        operation: 'ADD',
        value: '5',
      ),
    );
    row.qty.text = '3000';
    row.pricing.totalAmount.text = '105';
    expect(row.pricing.totalAmountInput, '100');
    expect(row.price.text, '0.0333333333');
    expect(row.amountExactNotifier.value, '105');
    final recovered = SubcontractGridRow.fromDraft(row.exportDraft());
    addTearDown(recovered.dispose);
    expect(recovered.pricing.totalAmountInput, '100');
    expect(recovered.amountExactNotifier.value, '105');
  });

  test('old order drafts opt in without changing their numbers', () {
    final row = PurchaseGridRow.fromDraft({
      'text': {'qty': '10000', 'price': '0.0037'},
    }, supportsTotalInput: true);
    addTearDown(row.dispose);
    expect(row.amountExactNotifier.value, '37');
    row.pricing.totalAmount.text = '29';
    expect(row.price.text, '0.0029');
    expect(row.pricing.totalAmountInput, '29');
  });

  test(
    'source receipt cannot turn its quantity or price into a derived input',
    () {
      final row = PurchaseGridRow(sourceLocked: true)
        ..upstreamItemId = 'order-line';
      addTearDown(row.dispose);
      row.qty.text = '2';
      row.price.text = '1';
      row.pricing.setMode(LinePricingMode.calculateQuantity);
      expect(row.pricing.validate(), contains('来源单据'));
      expect(row.qty.text, '2');
    },
  );

  test(
    'recorded total uses the exact API text, not its floating-point companion',
    () {
      final json = <String, dynamic>{
        'id': 'line',
        'totalAmountInput': 123.123456789,
        'totalAmountInputExact': '123.123456789012345678901234',
      };
      expect(
        PurchaseDocItem.fromJson(json).totalAmountInputText,
        '123.123456789012345678901234',
      );
      expect(
        SubcontractDocItem.fromJson(json).totalAmountInputText,
        '123.123456789012345678901234',
      );
    },
  );

  test(
    'source receipt keeps recorded amount and defers after a quantity edit',
    () {
      final row = PurchaseGridRow(sourceLocked: true)
        ..upstreamItemId = 'order-line';
      addTearDown(row.dispose);
      row.qty.text = '3000';
      row.price.text = '0.0333333333';
      row.recordSourceAmount('100');
      expect(row.amountExactNotifier.value, '100');
      final recovered = PurchaseGridRow.fromDraft(row.exportDraft());
      addTearDown(recovered.dispose);
      expect(recovered.amountExactNotifier.value, '100');
      recovered.qty.text = '1000';
      expect(recovered.sourceAmountPending, isTrue);
      expect(recovered.amountExactNotifier.value, isNull);
      recovered.qty.text = '3000';
      expect(recovered.amountExactNotifier.value, '100');
      recovered.addExtraColumn(
        const BusinessColumn(
          id: 'fee',
          name: '包装费',
          type: 'AMOUNT',
          operation: 'ADD',
          value: '5',
        ),
      );
      expect(recovered.sourceAmountPending, isTrue);
      expect(recovered.amountExactNotifier.value, isNull);
    },
  );
}
