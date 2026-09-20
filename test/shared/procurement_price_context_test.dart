import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/models/procurement_commercial_terms.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';

void main() {
  const context = ProcurementPriceContext(
    supplierId: 'supplier-a',
    colorId: 'red',
    unitId: 'box',
    currencyId: 'USD',
    taxRate: 13,
  );
  bool matches({
    String supplier = 'supplier-a',
    String? color = 'red',
    String unit = 'box',
    String currency = 'USD',
    double? tax = 13,
  }) => context.matches(
    supplierId: supplier,
    colorId: color,
    unitId: unit,
    currencyId: currency,
    taxRate: tax,
  );

  test(
    'price requires every commercial dimension and never guesses legacy context',
    () {
      expect(matches(), isTrue);
      expect(matches(supplier: 'supplier-b'), isFalse);
      expect(matches(color: null), isFalse);
      expect(matches(unit: 'piece'), isFalse);
      expect(matches(currency: 'CNY'), isFalse);
      expect(matches(tax: 0), isFalse);
      expect(matches(tax: null), isFalse);
      expect(
        const ProcurementPriceContext().matches(
          supplierId: null,
          colorId: null,
          unitId: null,
          currencyId: null,
          taxRate: null,
        ),
        isFalse,
      );
    },
  );

  PurchaseGridRow row() {
    final row = PurchaseGridRow()
      ..goods = const GoodsOption(id: 'goods', code: 'G', name: '测试货品')
      ..supplierId = 'supplier-a'
      ..unitId = 'box'
      ..colorId = 'red'
      ..currencyId = 'USD';
    row.taxRate.text = '13';
    row.price.text = '78';
    row.markTermsAutofilled('price', '78');
    row.watchDefaultPrice(
      price: row.price,
      supplier: row.supplierIdNotifier,
      context: context,
      goodsId: 'goods',
      currentGoodsId: () => row.goods?.id,
      currentColorId: () => row.colorId,
      currentUnitId: () => row.unitId,
    );
    addTearDown(row.dispose);
    return row;
  }

  test(
    'changing supplier currency or tax clears only a still-automatic price',
    () {
      final supplier = row()..supplierId = 'supplier-b';
      expect(supplier.price.text, isEmpty);
      final currency = row()..currencyId = 'CNY';
      expect(currency.price.text, isEmpty);
      final unit = row()..unitId = 'piece';
      unit.revalidateDefaultPrice();
      expect(unit.price.text, isEmpty);
      final tax = row();
      tax.taxRate.text = '0';
      expect(tax.price.text, isEmpty);
    },
  );

  test('explicit user confirmation preserves even the same numeric price', () {
    final confirmed = row();
    // Price TextField onChanged/onSubmitted explicitly consumes the autofill marker.
    confirmed.clearTermsAutofilled('price');
    confirmed.currencyId = 'CNY';
    expect(confirmed.price.text, '78');
    final edited = row();
    edited.price.text = '80';
    edited.supplierId = 'supplier-b';
    expect(edited.price.text, '80');
  });
  test(
    'copying an automatic price preserves its context without sharing row listeners',
    () {
      final original = row();
      final copied = original.clone();
      addTearDown(copied.dispose);
      expect(copied.price.text, '78');
      copied.supplierId = 'supplier-b';
      expect(copied.price.text, isEmpty);
      expect(original.price.text, '78');
      final unitCopy = original.clone()..unitId = 'piece';
      addTearDown(unitCopy.dispose);
      unitCopy.revalidateDefaultPrice();
      expect(unitCopy.price.text, isEmpty);
      original.clearTermsAutofilled('price');
      final manualCopy = original.clone()..currencyId = 'CNY';
      addTearDown(manualCopy.dispose);
      expect(manualCopy.price.text, '78');
    },
  );

  test('subcontract copy also retains the automatic price context', () {
    final original = SubcontractGridRow()
      ..goods = const GoodsOption(id: 'goods', code: 'G', name: '测试货品')
      ..supplierId = 'supplier-a'
      ..unitId = 'box'
      ..colorId = 'red'
      ..currencyId = 'USD';
    addTearDown(original.dispose);
    original.price.text = '78';
    original.taxRate.text = '13';
    original.markTermsAutofilled('price', '78');
    original.watchDefaultPrice(
      price: original.price,
      supplier: original.supplierIdNotifier,
      context: context,
      goodsId: 'goods',
      currentGoodsId: () => original.goods?.id,
      currentColorId: () => original.colorId,
      currentUnitId: () => original.unitId,
    );
    final copied = original.clone();
    addTearDown(copied.dispose);
    copied.taxRate.text = '0';
    expect(copied.price.text, isEmpty);
    expect(original.price.text, '78');
  });
  test(
    'pending defaults detect editing then clearing a field even when its value returns empty',
    () {
      final target = PurchaseGridRow();
      addTearDown(target.dispose);
      target.trackCommercialEdits(
        price: target.price,
        supplier: target.supplierIdNotifier,
      );
      final capturedRevision = target.commercialRevision;
      target.price.text = '100';
      target.price.clear();
      expect(target.price.text, isEmpty);
      expect(target.commercialRevision, greaterThan(capturedRevision));
      final nextRevision = target.commercialRevision;
      target.currencyId = 'USD';
      target.currencyId = null;
      expect(target.commercialRevision, greaterThan(nextRevision));
      final sameValueRevision = target.commercialRevision;
      target.clearTermsAutofilled('price');
      expect(target.commercialRevision, greaterThan(sameValueRevision));
    },
  );
}
