import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/pricing/line_pricing_controller.dart';

void main() {
  late TextEditingController qty;
  late TextEditingController price;
  late LinePricingController pricing;

  void create({
    bool supportsTotalInput = false,
    bool Function()? canCalculateQuantity,
    bool Function()? canCalculatePrice,
    Iterable<BusinessColumn> Function()? extraColumns,
    TextEditingController? discount,
  }) {
    pricing = LinePricingController(
      qty: qty,
      price: price,
      supportsTotalInput: supportsTotalInput,
      canCalculateQuantity: canCalculateQuantity,
      canCalculatePrice: canCalculatePrice,
      extraColumns: extraColumns,
      discount: discount,
    );
  }

  setUp(() {
    qty = TextEditingController();
    price = TextEditingController();
  });
  tearDown(() {
    pricing.dispose();
    qty.dispose();
    price.dispose();
  });

  test('empty new row stays empty, finite products retain exact precision', () {
    create();
    expect(qty.text, '');
    expect(price.text, '');
    expect(pricing.totalAmount.text, '');
    expect(pricing.error.value, isNull);
    qty.text = '1234.5678';
    price.text = '0.1234567891';
    expect(pricing.amountExact, '152.41577651425098');
    expect(pricing.totalAmountInput, isNull);
  });

  test('packaging quantity and total calculate a cheap unit price exactly', () {
    create(supportsTotalInput: true);
    qty.text = '10000';
    pricing.totalAmount.text = '28.50';
    expect(pricing.mode, LinePricingMode.calculatePrice);
    expect(price.text, '0.00285');
    expect(pricing.totalAmount.text, '28.50');
    expect(pricing.amountExact, '28.5');
    expect(pricing.totalAmountInput, '28.5');
    expect(pricing.validate(), isNull);
  });

  test('repeating price preserves entered amount only on a supported API', () {
    create(supportsTotalInput: true);
    qty.text = '3';
    pricing.totalAmount.text = '10.00';
    expect(price.text, '3.3333333333');
    expect(pricing.totalAmount.text, '10.00');
    expect(pricing.amountExact, '10');
    expect(pricing.totalAmountInput, '10');
    expect(pricing.isApproximate, isTrue);
    expect(pricing.validate(), isNull);
    qty.text = '6';
    expect(price.text, '1.6666666666');
    expect(pricing.totalAmountInput, '10');
  });

  test('unsupported APIs reject an inexact price instead of losing cents', () {
    create();
    qty.text = '3';
    price.text = '2';
    pricing.totalAmount.text = '10';
    expect(price.text, isEmpty);
    expect(pricing.amountExact, isNull);
    expect(pricing.totalAmount.text, '10');
    expect(pricing.validate(), contains('精确单价'));
  });

  test('typing a derived price explicitly returns to amount calculation', () {
    create(supportsTotalInput: true);
    qty.text = '3';
    pricing.totalAmount.text = '10';
    price.selection = const TextSelection.collapsed(offset: 1);
    expect(pricing.mode, LinePricingMode.calculatePrice);
    price.text = '4';
    expect(pricing.mode, LinePricingMode.calculateAmount);
    expect(pricing.amountExact, '12');
    expect(pricing.totalAmountInput, isNull);
    expect(pricing.isApproximate, isFalse);
  });

  test('price and total infer quantity, with exact four-place bound', () {
    create();
    price.text = '0.25';
    pricing.totalAmount.text = '12.50';
    expect(pricing.mode, LinePricingMode.calculateQuantity);
    expect(qty.text, '50');
    expect(pricing.validate(), isNull);
    price.text = '3';
    expect(qty.text, isEmpty);
    expect(pricing.validate(), contains('精确数量'));
    pricing.totalAmount.text = '3.0003';
    expect(qty.text, '1.0001');
    expect(pricing.validate(), isNull);
  });

  test(
    'explicit quantity calculation and manual quantity edits are distinct',
    () {
      create();
      qty.text = '10';
      price.text = '2';
      pricing.setMode(LinePricingMode.calculateQuantity);
      pricing.totalAmount.text = '30';
      expect(qty.text, '15');
      qty.text = '20';
      expect(pricing.mode, LinePricingMode.calculateAmount);
      expect(pricing.amountExact, '40');
    },
  );

  test('zero total yields zero price, zero divisors and negatives fail', () {
    create(supportsTotalInput: true);
    qty.text = '5';
    pricing.totalAmount.text = '0';
    expect(price.text, '0');
    expect(pricing.validate(), isNull);
    qty.text = '0';
    expect(price.text, isEmpty);
    expect(pricing.validate(), contains('数量必须大于 0'));
    qty.text = '5';
    pricing.totalAmount.text = '-1';
    expect(pricing.validate(), contains('总金额不能小于 0'));
    pricing.totalAmount.text = 'NaN';
    expect(pricing.validate(), contains('有效数字'));
  });

  test('clearing total clears the derived price and blocks save', () {
    create();
    qty.text = '100';
    pricing.totalAmount.text = '20';
    pricing.totalAmount.clear();
    expect(price.text, '');
    expect(pricing.amountExact, isNull);
    expect(pricing.validate(), contains('请输入数量和总金额'));
  });

  test('source locks prevent mutation even when restored mode requests it', () {
    create(canCalculateQuantity: () => false, canCalculatePrice: () => false);
    qty.text = '10';
    price.text = '2';
    pricing.restoreState({'mode': 'calculateQuantity', 'totalAmount': '40'});
    expect(qty.text, '10');
    expect(pricing.validate(), contains('不能反算数量'));
    pricing.setMode(LinePricingMode.calculatePrice);
    expect(price.text, '2');
    expect(pricing.validate(), contains('不能反算单价'));
  });

  test('extra columns reverse in exact reverse order and keep final total', () {
    var fee = '2';
    create(
      supportsTotalInput: true,
      extraColumns: () => [
        _column('packing', 'ADD', fee),
        _column('multiplier', 'MULTIPLY', '3'),
        _column('rebate', 'SUBTRACT', '1'),
        _column('split', 'DIVIDE', '2'),
      ],
    );
    qty.text = '4';
    pricing.totalAmount.text = '17.5';
    expect(price.text, '2.5');
    expect(pricing.totalAmountInput, '10');
    expect(pricing.amountExact, '17.5');
    fee = '3';
    pricing.refresh();
    expect(pricing.totalAmount.text, '17.5');
    expect(price.text, '2.25');
    expect(pricing.totalAmountInput, '9');
  });

  test('non-invertible extras reject rather than fabricate a base amount', () {
    var multiplier = '3';
    create(
      supportsTotalInput: true,
      extraColumns: () => [_column('factor', 'MULTIPLY', multiplier)],
    );
    qty.text = '1';
    pricing.totalAmount.text = '10';
    expect(pricing.validate(), contains('有限小数'));
    expect(pricing.totalAmountInput, isNull);
    multiplier = '0';
    pricing.refresh();
    expect(pricing.validate(), contains('乘数为 0'));
  });

  test(
    'discount is included once in both forward and inverse calculations',
    () {
      final discount = TextEditingController(text: '0.9');
      addTearDown(discount.dispose);
      create(discount: discount);
      qty.text = '10';
      price.text = '20';
      expect(pricing.amountExact, '180');
      pricing.totalAmount.text = '90';
      expect(price.text, '10');
      expect(pricing.validate(), isNull);
      discount.text = '0.5';
      expect(price.text, '18');
      expect(pricing.amountExact, '90');
    },
  );

  test(
    'draft and copy preserve total text, calculation mode and precision',
    () {
      create(supportsTotalInput: true);
      qty.text = '3';
      pricing.totalAmount.text = '10.000';
      final otherQty = TextEditingController(text: qty.text);
      final otherPrice = TextEditingController(text: price.text);
      final other = LinePricingController(
        qty: otherQty,
        price: otherPrice,
        supportsTotalInput: true,
      );
      pricing.copyStateTo(other);
      expect(other.exportState(), pricing.exportState());
      expect(other.totalAmountInput, '10');
      expect(other.isApproximate, isTrue);
      other.dispose();
      otherQty.dispose();
      otherPrice.dispose();
    },
  );

  test(
    'total entered first remains authoritative when price is entered next',
    () {
      create(supportsTotalInput: true);
      pricing.totalAmount.text = '28.50';
      expect(qty.text, isEmpty);
      price.text = '0.00285';
      expect(pricing.mode, LinePricingMode.calculateQuantity);
      expect(qty.text, '10000');
      expect(pricing.totalAmount.text, '28.50');
      expect(pricing.validate(), isNull);
    },
  );

  test('total entered first remains authoritative when quantity follows', () {
    create(supportsTotalInput: true);
    pricing.totalAmount.text = '28.50';
    qty.text = '10000';
    expect(pricing.mode, LinePricingMode.calculatePrice);
    expect(price.text, '0.00285');
    expect(pricing.totalAmount.text, '28.50');
    expect(pricing.validate(), isNull);
  });

  test(
    'explicit quantity mode can infer price when quantity is filled first',
    () {
      create();
      pricing.setMode(LinePricingMode.calculateQuantity);
      pricing.totalAmount.text = '12';
      qty.text = '4';
      expect(pricing.mode, LinePricingMode.calculatePrice);
      expect(price.text, '3');
      expect(pricing.totalAmount.text, '12');
    },
  );

  test(
    'discount precision matches the server four-place quantity contract',
    () {
      final discount = TextEditingController(text: '0.12345');
      addTearDown(discount.dispose);
      create(discount: discount);
      qty.text = '10';
      price.text = '20';
      expect(pricing.validate(), contains('折扣最多支持 4 位小数'));
      expect(pricing.amountExact, isNull);
    },
  );

  test('recorded base total is restored with extras exactly once', () {
    create(
      supportsTotalInput: true,
      extraColumns: () => [_column('fee', 'ADD', '2')],
    );
    qty.text = '3';
    price.text = '3.3333333333';
    pricing.restoreRecordedTotal('10.00');
    expect(pricing.totalAmount.text, '12');
    expect(pricing.totalAmountInput, '10');
    expect(price.text, '3.3333333333');
    expect(pricing.isApproximate, isTrue);
  });
}

BusinessColumn _column(String name, String operation, String value) =>
    BusinessColumn(
      id: name,
      name: name,
      type: 'AMOUNT',
      operation: operation,
      value: value,
    );
