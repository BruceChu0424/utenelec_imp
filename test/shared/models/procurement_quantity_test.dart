import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/procurement_quantity.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';

void main() {
  test(
    'legacy annotation is not additional physical stock and new exact facts retain every digit',
    () {
      final legacy = PurchaseDocItem.fromJson({
        'id': 'legacy',
        'qty': 10,
        'giftQty': 1,
        'quantitySemantics': procurementLegacyQuantity,
      });
      expect(legacy.recordedPhysicalQtyText, '10');
      final current = PurchaseDocItem.fromJson({
        'id': 'current',
        'qty': double.parse('99999999999999.1234'),
        'qtyExact': '99999999999999.1234',
        'giftQtyExact': '0.0001',
        'quantitySemantics': procurementChargedPlusGiftQuantity,
      });
      expect(current.recordedPhysicalQtyText, '99999999999999.1235');
      expect(
        procurementPhysicalQuantityText(
          quantitySemantics: 'UNKNOWN',
          chargedQty: '10',
          giftQty: '1',
        ),
        isNull,
      );
    },
  );
  test(
    'zero charged plus positive gift is allowed while negative precision overflow and zero physical fail',
    () {
      expect(procurementQuantityError('0', '1', extraGift: true), isNull);
      for (final pair in [
        ('0', '0'),
        ('10', '-0.0001'),
        ('10', '0.00001'),
        ('99999999999999.9999', '0.0001'),
      ]) {
        expect(
          procurementQuantityError(pair.$1, pair.$2, extraGift: true),
          isNotNull,
        );
      }
      expect(procurementQuantityError('0', '1', extraGift: false), isNotNull);
    },
  );
  test(
    'row draft round trip keeps semantics gift input and explicit legacy confirmation',
    () {
      final row = PurchaseGridRow()
        ..quantitySemantics = procurementLegacyQuantity
        ..qty.text = '10'
        ..giftQty.text = '1'
        ..giftSemanticsConfirmed.value = true;
      addTearDown(row.dispose);
      final restored = PurchaseGridRow.fromDraft(row.exportDraft());
      addTearDown(restored.dispose);
      expect(restored.quantitySemantics, procurementLegacyQuantity);
      expect(restored.physicalQtyText, '11');
      expect(restored.giftQty.text, '1');
    },
  );
}
