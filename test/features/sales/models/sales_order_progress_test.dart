import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_order_progress.dart';

void main() {
  test('in-flight shipments surface as their own stages with quantities', () {
    // V631：开了出货单但仓库还没出库——阶段带数量，「出货在途」列按阶段拆分。
    final pendingFinance = SalesOrderProgressRow.fromJson(const {
      'orderId': 'order-ship-1',
      'billNo': 'SO-SHIP-1',
      'orderQty': 10,
      'producedQty': 10,
      'shippedQty': 0,
      'reservedQty': 10,
      'plannedQty': 10,
      'productionPct': 1,
      'stage': 'SHIPMENT_PENDING',
      'shipmentPendingFinanceQty': 10,
    });
    expect(salesProgressStageLabel(pendingFinance.stage), '出货待财审');
    expect(salesProgressStageText(pendingFinance), '出货待财审 10');
    expect(salesProgressShipmentInFlightText(pendingFinance), '待财审 10');
    expect(pendingFinance.shipmentInFlightQty, 10);

    final warehousePending = SalesOrderProgressRow.fromJson(const {
      'orderId': 'order-ship-2',
      'billNo': 'SO-SHIP-2',
      'orderQty': 10,
      'producedQty': 10,
      'shippedQty': 0,
      'reservedQty': 10,
      'plannedQty': 10,
      'productionPct': 1,
      'stage': 'WAREHOUSE_PENDING',
      'shipmentApprovedQty': 6,
      'shipmentFinanceRejectedQty': 4,
    });
    expect(salesProgressStageLabel(warehousePending.stage), '等仓库出货');
    expect(salesProgressStageText(warehousePending), '等仓库出货 6');
    expect(
      salesProgressShipmentInFlightText(warehousePending),
      '财务退回 4 · 待出库 6',
    );
    expect(salesProgressStageLabel('SHIPPED'), '仓库已发货');
    expect(salesProgressShipmentInFlightText(warehousePending), isNotNull);
  });

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

  test(
    'partially planned order stays pending and says how much is planned',
    () {
      // V545：订 10 排 4 → 阶段仍 PENDING（服务端按剩余未排量派生），文案标明已排 4/10。
      final row = SalesOrderProgressRow.fromJson(const {
        'orderId': 'order-partial',
        'billNo': 'SO-PARTIAL',
        'orderQty': 10,
        'producedQty': 0,
        'shippedQty': 0,
        'reservedQty': 0,
        'plannedQty': 4,
        'unplannedQty': 6,
        'productionPct': 0,
        'stage': 'PENDING',
      });

      expect(row.unplannedQty, 6);
      expect(salesProgressStageText(row), '待排产·部分已排 4/10');
      expect(
        salesProgressStageText(
          SalesOrderProgressRow.fromJson(const {
            'orderId': 'order-none',
            'billNo': 'SO-NONE',
            'orderQty': 10,
            'plannedQty': 0,
            'stage': 'PENDING',
          }),
        ),
        '待排产',
      );
      expect(
        salesProgressStageText(
          SalesOrderProgressRow.fromJson(const {
            'orderId': 'order-full',
            'billNo': 'SO-FULL',
            'orderQty': 10,
            'plannedQty': 10,
            'unplannedQty': 0,
            'stage': 'PRODUCING',
          }),
        ),
        '生产中',
      );
    },
  );

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
