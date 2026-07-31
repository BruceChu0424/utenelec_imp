import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  group('MrpRow', () {
    test('parses the complete planning availability contract', () {
      final row = MrpRow.fromJson({
        'goodsId': 'goods-1',
        'goodsCode': 'MAT-001',
        'goodsName': '测试物料',
        'gross': 10,
        'onhand': 8,
        'openPo': 4,
        'net': 0,
        'selfMade': false,
        'bookStock': 8,
        'salesReserved': 2,
        'safetyStock': 1,
        'availableNow': 5,
        'openPoTotal': 4,
        'openPoOnTime': 1,
        'needDate': '2026-08-01',
        'earliestArrivalDate': '2026-08-03',
        'purchaseNetShortage': 1,
        'timelyShortage': 4,
        'materialStatus': 'INBOUND_LATE',
        'allocationBacked': false,
        'planningWriteReady': false,
      });

      expect(row.isLegacyAvailability, isFalse);
      expect(row.availableNow, 5);
      expect(row.openPoOnTime, 1);
      expect(row.purchaseNetShortage, 1);
      expect(row.allocationBacked, isFalse);
      expect(row.planningWriteReady, isFalse);
      expect(row.planningShortage, isNull);
      expect(row.statusLabel, '在途晚到');
    });

    test('exposes planning quantity only for allocation-backed responses', () {
      final row = MrpRow.fromJson({
        'goodsId': 'goods-ready',
        'gross': 10,
        'selfMade': true,
        'bookStock': 8,
        'salesReserved': 2,
        'safetyStock': 1,
        'availableNow': 5,
        'openPoTotal': 4,
        'openPoOnTime': 1,
        'purchaseNetShortage': 1,
        'timelyShortage': 4,
        'materialStatus': 'READY_BY_DATE',
        'allocationBacked': true,
        'planningWriteReady': true,
      });

      expect(row.isLegacyAvailability, isFalse);
      expect(row.allocationBacked, isTrue);
      expect(row.planningWriteReady, isTrue);
      expect(row.planningShortage, 4);
    });

    test('does not infer planning-safe values from a legacy response', () {
      final row = MrpRow.fromJson({
        'goodsId': 'goods-legacy',
        'gross': 10,
        'onhand': 10,
        'openPo': 20,
        'net': 0,
        'selfMade': true,
      });

      expect(row.isLegacyAvailability, isTrue);
      expect(row.availableNow, isNull);
      expect(row.openPoOnTime, isNull);
      expect(row.timelyShortage, isNull);
      expect(row.planningShortage, isNull);
      expect(row.allocationBacked, isFalse);
      expect(row.planningWriteReady, isFalse);
      expect(row.statusLabel, '待复核');
    });
  });

  group('SchedulePendingRow', () {
    test('marks rows without an active BOM as unavailable', () {
      final row = SchedulePendingRow.fromJson({
        'orderItemId': 'order-item-1',
        'orderId': 'order-1',
        'bomReady': false,
      });

      expect(row.bomReady, isFalse);
    });

    test('defaults BOM readiness to true for older API responses', () {
      final row = SchedulePendingRow.fromJson({
        'orderItemId': 'order-item-2',
        'orderId': 'order-2',
      });

      expect(row.bomReady, isTrue);
    });
  });

  test('planning package maps editable subplan fields exactly', () {
    const request = PlanningPackageRequest(
      generatePurchaseRequest: true,
      items: [
        GenerateSubplanLine(
          goodsId: 'goods-1',
          colorId: 'color-1',
          unitId: 'unit-1',
          qty: 12.5,
          departmentId: 'department-1',
          workshopName: '一车间',
          planBeginDate: '2026-08-01',
          planEndDate: '2026-08-03',
          workerId: 'worker-1',
          workerName: '张三',
        ),
      ],
    );

    expect(request.toJson(), {
      'items': [
        {
          'goodsId': 'goods-1',
          'qty': 12.5,
          'colorId': 'color-1',
          'unitId': 'unit-1',
          'departmentId': 'department-1',
          'workshopName': '一车间',
          'planBeginDate': '2026-08-01',
          'planEndDate': '2026-08-03',
          'workerId': 'worker-1',
          'workerName': '张三',
        },
      ],
      'generatePurchaseRequest': true,
    });
  });

  test('planning package result parses subplans and purchase request', () {
    final result = PlanningPackageResult.fromJson({
      'subplans': [
        {
          'planId': 'plan-1',
          'billNo': 'SC-001',
          'lineCount': 2,
          'workshopName': '一车间',
        },
      ],
      'purchaseRequest': {
        'requestId': 'request-1',
        'requestBillNo': 'PR-001',
        'lineCount': 3,
        'skippedSelfMade': ['goods-self-made'],
      },
    });

    expect(result.subplans, hasLength(1));
    expect(result.subplans.single.planId, 'plan-1');
    expect(result.purchaseRequest?.requestBillNo, 'PR-001');
    expect(result.purchaseRequest?.skippedSelfMade, ['goods-self-made']);
  });
}
