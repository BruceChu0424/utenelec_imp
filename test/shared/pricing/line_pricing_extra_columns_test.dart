import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/pricing/line_pricing_controller.dart';

void main() {
  late TextEditingController qty;
  late TextEditingController price;
  late TextEditingController discount;
  late ValueNotifier<List<BusinessColumn>> columns;
  late LinePricingController pricing;

  setUp(() {
    qty = TextEditingController(text: '10');
    price = TextEditingController(text: '10');
    discount = TextEditingController(text: '1');
    columns = ValueNotifier([]);
    pricing = LinePricingController(
      qty: qty,
      price: price,
      discount: discount,
      extraColumns: () => columns.value,
      extraColumnsChanged: columns,
      supportsTotalInput: true,
    );
  });

  tearDown(() {
    pricing.dispose();
    qty.dispose();
    price.dispose();
    discount.dispose();
    columns.dispose();
  });

  test('editing and clearing a fee changes the total, preserving its base', () {
    pricing.totalAmount.text = '200';
    columns.value = [_column('ADD', '12')];
    expect(pricing.totalAmount.text, '212');
    expect(pricing.totalAmountInput, '200');
    expect(price.text, '20');
    columns.value = [_column('ADD', '17')];
    expect(pricing.amountExact, '217');
    columns.value = [_column('ADD', '')];
    expect(pricing.amountExact, '200');
    expect(pricing.validate(), isNull);
  });

  test('explicit total edits establish a fresh base before the next fee', () {
    pricing.totalAmount.text = '200';
    columns.value = [_column('ADD', '12')];
    pricing.totalAmount.text = '250';
    expect(pricing.totalAmountInput, '238');
    columns.value = [_column('ADD', '22')];
    expect(pricing.amountExact, '260');
    expect(pricing.totalAmountInput, '238');
    pricing.totalAmount.clear();
    columns.value = [_column('ADD', '30')];
    expect(pricing.amountExact, isNull);
    expect(pricing.totalAmountInput, isNull);
  });

  test('invalid fee corrections and removal recover the original base', () {
    pricing.totalAmount.text = '200';
    columns.value = [_column('DIVIDE', '0')];
    expect(pricing.amountExact, isNull);
    expect(pricing.totalAmountInput, isNull);
    expect(pricing.validate(), isNotNull);
    columns.value = [_column('DIVIDE', '4')];
    expect(pricing.amountExact, '50');
    expect(pricing.totalAmountInput, '200');
    columns.value = [_column('DIVIDE', '3')];
    expect(pricing.validate(), isNotNull);
    columns.value = [];
    expect(pricing.amountExact, '200');
    expect(price.text, '20');
  });

  test(
    'zero multiplier can be changed back without destroying consideration',
    () {
      pricing.totalAmount.text = '200';
      columns.value = [_column('MULTIPLY', '0')];
      expect(pricing.amountExact, '0');
      expect(pricing.totalAmountInput, '200');
      expect(pricing.validate(), isNull);
      columns.value = [_column('MULTIPLY', '2')];
      expect(pricing.amountExact, '400');
      expect(price.text, '20');
    },
  );

  test('fees retain exact base instead of using a rounded reference price', () {
    qty.text = '3';
    pricing.totalAmount.text = '10';
    columns.value = [_column('ADD', '0.000000000000000000000000000001')];
    expect(pricing.amountExact, '10.000000000000000000000000000001');
    expect(pricing.totalAmountInput, '10');
    expect(price.text, '3.3333333333');
    expect(pricing.isApproximate, isTrue);
    expect(pricing.validate(), isNull);
  });

  test('fee changes in quantity mode preserve the existing quantity basis', () {
    pricing.setMode(LinePricingMode.calculateQuantity);
    pricing.totalAmount.text = '200';
    expect(qty.text, '20');
    columns.value = [_column('ADD', '12')];
    expect(qty.text, '20');
    expect(price.text, '10');
    expect(pricing.amountExact, '212');
    pricing.setMode(LinePricingMode.calculatePrice);
    columns.value = [_column('ADD', '22')];
    expect(pricing.amountExact, '222');
    qty.text = '10';
    expect(price.text, '20');
    expect(pricing.totalAmountInput, '200');
  });

  test(
    'discount changes retain total-mode semantics and do not absorb fees',
    () {
      pricing.totalAmount.text = '200';
      columns.value = [_column('ADD', '12')];
      discount.text = '0.5';
      expect(price.text, '40');
      expect(pricing.amountExact, '212');
      columns.value = [_column('ADD', '22')];
      expect(price.text, '40');
      expect(pricing.amountExact, '222');
      price.text = '50';
      expect(pricing.mode, LinePricingMode.calculateAmount);
      expect(pricing.amountExact, '272');
      columns.value = [_column('ADD', '30')];
      expect(pricing.amountExact, '280');
      expect(pricing.totalAmountInput, isNull);
    },
  );

  test('recorded totals restore once even when a fee cannot be inverted', () {
    columns.value = [_column('MULTIPLY', '0')];
    pricing.restoreRecordedTotal('200');
    expect(pricing.amountExact, '0');
    expect(pricing.totalAmountInput, '200');
    expect(pricing.validate(), isNull);
    columns.value = [_column('MULTIPLY', '2')];
    expect(pricing.amountExact, '400');
  });

  test(
    'draft recovery preserves base through invalid fee and zero multiplier',
    () {
      for (final value in ['invalid', '0']) {
        columns.value = [];
        qty.text = '3';
        pricing.totalAmount.text = '10';
        columns.value = [_column('MULTIPLY', value)];
        final recoveredQty = TextEditingController(text: qty.text);
        final recoveredPrice = TextEditingController(text: price.text);
        final recoveredColumns = ValueNotifier<List<BusinessColumn>>([]);
        final recovered = LinePricingController(
          qty: recoveredQty,
          price: recoveredPrice,
          supportsTotalInput: true,
          extraColumns: () => recoveredColumns.value,
          extraColumnsChanged: recoveredColumns,
        );
        // Business row draft recovery restores the saved columns before pricing.
        recoveredColumns.value = columns.value;
        recovered.restoreState(pricing.exportState());
        recoveredColumns.value = [_column('MULTIPLY', '2')];
        expect(recovered.totalAmountInput, '10');
        expect(recovered.amountExact, '20');
        expect(recoveredPrice.text, '3.3333333333');
        expect(recovered.validate(), isNull);
        recovered.dispose();
        recoveredQty.dispose();
        recoveredPrice.dispose();
        recoveredColumns.dispose();
      }
    },
  );
}

BusinessColumn _column(String operation, String? value) => BusinessColumn(
  id: 'fee',
  name: '附加费用',
  type: 'AMOUNT',
  operation: operation,
  value: value,
);
