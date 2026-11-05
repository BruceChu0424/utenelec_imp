import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/delivery/delivery_processing_target.dart';

void main() {
  test(
    'shared price-free subjects retain exact decimal and rational source text',
    () {
      final targets = DeliveryProcessingTarget.read([
        {
          'path': ['parent-edge', 'child-edge'],
          'code': 'SYNTHETIC-PLATE',
          'name': '合成刻字板',
          'unitName': '片',
          'quantityExact': '1.23000000000000000001',
          'quantityNumerator': '123000000000000000001',
          'quantityDenominator': '100000000000000000000',
          'operations': ['LASER'],
          'unitPrice': 'private-price',
          'amount': 'private-amount',
        },
        {
          'path': ['fractional-edge'],
          'quantityNumerator': '10',
          'quantityDenominator': '3',
          'operations': ['LASER'],
        },
      ]);
      expect(targets.first.id, 'parent-edge/child-edge');
      expect(targets.first.quantity, '1.23000000000000000001');
      expect(targets.first.operations, '激光加工');
      expect(targets.first.data, isNot(contains('unitPrice')));
      expect(targets.first.data, isNot(contains('amount')));
      expect(targets.last.quantity, '10/3');
      expect(
        () => DeliveryProcessingTarget.read('malformed'),
        throwsFormatException,
      );
      expect(
        () => DeliveryProcessingTarget.read([null]),
        throwsFormatException,
      );
    },
  );
}
