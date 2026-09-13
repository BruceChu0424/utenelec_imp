import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/models/sales_shipment_prefill.dart';

void main() {
  final order = SalesDocDetail.fromJson({
    'id': 'order',
    'status': 1,
    'writable': true,
    'financeConfirmed': true,
    'items': [
      {'id': 'item', 'goodsId': 'goods', 'qty': 1000},
    ],
  });
  const progress = [
    OrderPlanProgressLine(
      orderItemId: 'item',
      qty: 1000,
      shippableQty: 10,
      pendingShipmentQty: 5,
    ),
  ];

  test('prefill keeps reviewed UUID and partial quantity', () {
    final intent = SalesShipmentPrefill.parse('order', 'item:7.125');
    intent.validate(order, progress);
    expect(intent.quantities, {'item': 7.125});
  });
  test('stale quantity, foreign UUID and unknown availability fail closed', () {
    expect(
      () => SalesShipmentPrefill.parse(
        'order',
        'item:11',
      ).validate(order, progress),
      throwsFormatException,
    );
    expect(
      () => SalesShipmentPrefill.parse(
        'order',
        'other:1',
      ).validate(order, progress),
      throwsFormatException,
    );
    expect(
      () => SalesShipmentPrefill.parse('order', 'item:1').validate(
        order,
        const [OrderPlanProgressLine(orderItemId: 'item', reservedQty: 100)],
      ),
      throwsFormatException,
    );
  });
  test(
    'invalid quantity and duplicate references cannot silently overwrite intent',
    () {
      for (final invalid in [
        'item:0',
        'item:-1',
        'item:NaN',
        'item:1.00001',
        'item:1,item:2',
      ]) {
        expect(
          () => SalesShipmentPrefill.parse('order', invalid),
          throwsFormatException,
        );
      }
    },
  );
}
