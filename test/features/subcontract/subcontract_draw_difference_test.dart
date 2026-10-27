import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_draw.dart';

void main() {
  test(
    'draw row keeps exact order delivery difference separate from draw quantities',
    () {
      final row = SubcontractDrawTaskRow.fromJson({
        'orderItemId': 'order-item',
        'orderQty': 10,
        'drawnQty': 10,
        'pendingQty': 0,
        'drawableQty': 0,
        'shortQty': 0,
        'differenceQty': -1,
        'differenceQtyExact': '-9007199254740993.0001',
        'unitName': '套',
      });
      expect(row.differenceQtyText, '-9007199254740993.0001');
      expect(row.unitName, '套');
      expect(row.shortQty, 0);
    },
  );

  test(
    'draw row never derives missing delivery facts from order or draw quantity',
    () {
      final row = SubcontractDrawTaskRow.fromJson({
        'orderItemId': 'order-item',
        'orderQty': 10,
        'shortQty': 10,
      });
      expect(row.differenceQtyText, isNull);
      expect(
        SubcontractDrawTaskRow.fromJson({
          'orderItemId': 'order-item',
          'differenceQty': -10,
          'differenceQtyExact': null,
        }).differenceQtyText,
        isNull,
      );
    },
  );
}
