import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/models/sales_shipment_prefill.dart';
import 'package:uten_imp/shared/delivery/order_delivery_plan.dart';

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
  test(
    'BOM uses service-authorized draft capacity without changing reserved stock',
    () {
      final plan = OrderDeliveryPlan.assembled().copyWith(
        mode: 'BOM',
        packaging: 'BULK',
      );
      final intent = SalesShipmentPrefill.parse('order', 'item:7.1250');
      intent.validate(order, [
        OrderPlanProgressLine(
          orderItemId: 'item',
          reservedQty: 0,
          shippableQty: 0,
          deliveryPlan: plan,
          deliveryDraftQty: 8,
          deliveryDraftQtyExact: '8',
        ),
      ]);
      expect(intent.exactQuantities, {'item': '7.1250'});
      expect(
        () => intent.validate(order, [
          OrderPlanProgressLine(
            orderItemId: 'item',
            reservedQty: 0,
            shippableQty: 0,
            deliveryPlan: plan,
            deliveryDraftQty: 7,
            deliveryDraftQtyExact: '7',
          ),
        ]),
        throwsFormatException,
      );
    },
  );
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
