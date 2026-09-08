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

  test(
    'finance rejection is a first-class progress stage with reason metadata',
    () {
      final row = SalesOrderProgressRow.fromJson(const {
        'orderId': 'order-rejected',
        'billNo': 'SO-REJECTED',
        'orderQty': 10,
        'producedQty': 0,
        'shippedQty': 0,
        'reservedQty': 0,
        'plannedQty': 0,
        'productionPct': 0,
        'stage': 'REJECTED',
        'financeConfirmed': false,
        'financeRejected': true,
        'financeRejectedReason': '结账方式错误',
        'financeRejectedAt': '2026-08-27T08:00:00+08:00',
        'financeRejectedByName': '财务张经理',
      });

      expect(row.financeRejected, isTrue);
      expect(row.financeRejectedReason, '结账方式错误');
      expect(row.financeRejectedByName, '财务张经理');
      expect(salesProgressStageLabel(row.stage), '财务驳回');
    },
  );

  test(
    'terminal stages (canceled/closed) parse and label for history view',
    () {
      final canceled = SalesOrderProgressRow.fromJson(const {
        'orderId': 'order-x',
        'billNo': 'SO-X',
        'orderQty': 10,
        'stage': 'CANCELED',
        'stopped': true,
      });
      final closed = SalesOrderProgressRow.fromJson(const {
        'orderId': 'order-y',
        'billNo': 'SO-Y',
        'orderQty': 10,
        'stage': 'CLOSED',
        'closed': true,
      });

      expect(canceled.stopped, isTrue);
      expect(canceled.closed, isFalse);
      expect(salesProgressStageLabel(canceled.stage), '已中止');
      expect(closed.closed, isTrue);
      expect(salesProgressStageLabel(closed.stage), '已结案');
    },
  );
}
