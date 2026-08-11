import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_order_progress.dart';

void main() {
  test('partial finished-goods reservation remains visibly unfulfilled', () {
    final row = SalesOrderProgressRow.fromJson(const {
      'orderId': 'order-1',
      'billNo': 'SO-001',
      'orderQty': 10,
      'producedQty': 5,
      'shippedQty': 0,
      'reservedQty': 5,
      'plannedQty': 10,
      'productionPct': 0.5,
      'stage': 'SHIPPABLE',
    });

    expect(row.shippable, isTrue);
    expect(row.remainingQty, 10);
    expect(salesProgressStageLabel(row.stage), '可分批发货');
  });

  test('remaining quantity decreases only by actual shipped quantity', () {
    final row = SalesOrderProgressRow.fromJson(const {
      'orderId': 'order-1',
      'billNo': 'SO-001',
      'orderQty': 10,
      'producedQty': 10,
      'shippedQty': 4,
      'reservedQty': 6,
      'plannedQty': 10,
      'productionPct': 1,
      'stage': 'SHIPPABLE',
    });

    expect(row.remainingQty, 6);
  });
}
