import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/procurement_quantity.dart';

void main() {
  test(
    'gift source remains receivable with no paid quantity and subtracts only its own registered gift',
    () {
      final item = InboundExpectationItem.fromJson({
        'id': 'row',
        'orderItemId': 'order-row',
        'goodsId': 'goods',
        'remainingQty': 0,
        'registeredQty': 0,
        'quantitySemantics': procurementChargedPlusGiftQuantity,
        'remainingGiftQtyExact': '1.0001',
        'registeredGiftQtyExact': '0.0001',
      });
      expect(item.effectiveRemainingGiftQtyText, '1');
      expect(item.canReceive, isTrue);
    },
  );
  test(
    'legacy gift source and missing V1 gift authority do not invent a remaining quota',
    () {
      final legacy = InboundExpectationItem.fromJson({
        'id': 'row',
        'orderItemId': 'order-row',
        'goodsId': 'goods',
        'remainingQty': 0,
        'registeredQty': 0,
        'quantitySemantics': procurementLegacyQuantity,
        'remainingGiftQtyExact': '9',
        'registeredGiftQtyExact': '0',
      });
      expect(legacy.effectiveRemainingGiftQtyText, '0');
      expect(legacy.canReceive, isFalse);
      final missing = InboundExpectationItem.fromJson({
        'id': 'row',
        'orderItemId': 'order-row',
        'goodsId': 'goods',
        'remainingQty': 0,
        'registeredQty': 0,
        'quantitySemantics': procurementChargedPlusGiftQuantity,
      });
      expect(missing.effectiveRemainingGiftQtyText, isNull);
      expect(missing.canReceive, isFalse);
    },
  );
}
