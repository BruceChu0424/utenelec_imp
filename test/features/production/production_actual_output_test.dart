import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/models/reportable_plan_line.dart';

void main() {
  test(
    'approved supplement reopens as one original input across two plans',
    () {
      final groups = productionDailyReportInputGroups([
        _supplementItem('original', quantity: 100, total: 130, original: true),
        _supplementItem('supplement', quantity: 30, total: 130),
      ]);
      final group = groups.single;
      expect(group.qty, 130);
      expect(group.planId, 'original-plan');
      expect(group.planItemId, 'original-item');
      expect(group.executionSegmentId, 'original-segment');
      expect(group.allocationId, 'original-allocation');
      expect(group.salesOrderItemId, 'original-order');
      expect(group.source.supplementProofId, 'proof');
      expect(group.weight, 13);
    },
  );

  test('all supplemental output still edits against the original identity', () {
    final group = productionDailyReportInputGroups([
      _supplementItem('supplement-only', quantity: 25, total: 25),
    ]).single;
    expect(group.qty, 25);
    expect(group.planId, 'original-plan');
    expect(group.executionSegmentId, 'original-segment');
    expect(group.planNo, isNull, reason: '不得把追加计划号作为原计划快照提交');
    final forged = _supplementItem(
      'different-proof',
      quantity: 30,
      total: 130,
      proof: 'other',
    );
    expect(
      () => productionDailyReportInputGroups([
        _supplementItem('original', quantity: 100, total: 130, original: true),
        forged,
      ]),
      throwsFormatException,
    );
  });

  test('actual output permission is explicit and never bypasses recovery', () {
    final source = <String, dynamic>{
      'planItemId': 'item',
      'planNo': 'plan',
      'goodsId': 'goods',
      'maxReportQty': 0,
    };
    expect(ReportablePlanLine.fromJson(source).canReport, isFalse);
    source['allowActualOverproduction'] = true;
    expect(ReportablePlanLine.fromJson(source).canReport, isTrue);
    source['fqcRecoveryAuthorizationId'] = 'rework';
    expect(ReportablePlanLine.fromJson(source).canReport, isFalse);
    source['maxReportQty'] = 10;
    source['fqcRecoveryRequiresMaterial'] = true;
    expect(ReportablePlanLine.fromJson(source).canReport, isFalse);
  });

  test(
    'editing joins only exact output batch and preserves request identity',
    () {
      final rows = [
        _item('public', batch: 'batch-a', qty: 100, public: true, weight: 1),
        _item('demand', batch: 'batch-a', qty: 300, weight: 3),
        _item('other-demand', batch: 'batch-b', qty: 300, weight: 3),
        _item(
          'other-public',
          batch: 'batch-b',
          qty: 100,
          public: true,
          weight: 1,
        ),
        _item('legacy-a', qty: 10),
        _item('legacy-b', qty: 20),
      ];
      final groups = productionDailyReportInputGroups(rows);
      expect(groups, hasLength(4));
      expect(groups.first.qty, 400);
      expect(groups.first.weight, 4);
      expect(groups.first.source.salesOrderItemId, 'order-demand');
      expect(groups.first.source.directTransferDemandId, 'target-demand');
      expect(groups[1].source.salesOrderItemId, 'order-other-demand');
      expect(groups[2].qty, 10);
      expect(groups[3].qty, 20);
    },
  );

  test('incomplete output batch is never editable as a fresh total', () {
    expect(
      () => productionDailyReportInputGroups([
        _item('demand', batch: 'batch', qty: 300),
      ]),
      throwsFormatException,
    );
    expect(
      () => productionDailyReportInputGroups([
        _item('demand', batch: 'batch', qty: 300),
        _item('public', batch: 'batch', qty: 100, planItemId: 'another-plan'),
      ]),
      throwsFormatException,
    );
  });

  test(
    'public-only batch retains warehouse destination and no sales identity',
    () {
      final group = productionDailyReportInputGroups([
        _item('public', batch: 'batch', qty: 400, public: true),
      ]).single;
      expect(group.qty, 400);
      expect(group.source.salesOrderItemId, isNull);
      expect(group.source.destination, 'WAREHOUSE');
      expect(group.source.outputKindLabel, '实际超产 · 公共备货');
      expect(group.weight, isNull);
    },
  );

  test('public output cannot inflate planned receipt completion', () {
    final task = ProductionExecutionWorkbenchSegment.fromJson({
      'plannedQty': 300,
      'reportedQty': 400,
      'inboundQty': 100,
      'actualSurplusReportedQty': 100,
      'actualSurplusInboundQty': 100,
      'plannedInboundQty': 0,
    });
    expect(task.actualSurplusReportedQty, 100);
    expect(task.inboundQty, 100);
    expect(task.plannedInboundProgressRatio, 0);
    final legacy = ProductionExecutionWorkbenchSegment.fromJson({
      'plannedQty': 300,
      'inboundQty': 150,
    });
    expect(legacy.actualSurplusInboundQty, 0);
    expect(legacy.plannedInboundProgressRatio, 0.5);
  });
}

ProductionDailyReportItem _supplementItem(
  String id, {
  required double quantity,
  required double total,
  bool original = false,
  String proof = 'proof',
}) => ProductionDailyReportItem.fromJson({
  'id': id,
  'goodsId': 'goods',
  'unitId': 'unit',
  'unitRate': 1,
  'planId': original ? 'original-plan' : 'supplement-plan',
  'planItemId': original ? 'original-item' : 'supplement-item',
  'executionSegmentId': original ? 'original-segment' : 'supplement-segment',
  'planNo': original ? 'SJ-ORIGINAL' : 'SJ-SUPPLEMENT',
  'qty': quantity,
  'weight': quantity / 10,
  'outputBatchId': 'physical-batch',
  'outputBatchQty': total,
  'supplementProofId': proof,
  'publicOutput': !original,
  'outputSourcePlanId': 'original-plan',
  'outputSourcePlanItemId': 'original-item',
  'outputSourceExecutionSegmentId': 'original-segment',
  'outputSourceSalesAllocationId': 'original-allocation',
  'outputSourceSalesOrderItemId': 'original-order',
});

ProductionDailyReportItem _item(
  String id, {
  String? batch,
  required double qty,
  bool public = false,
  double? weight,
  String planItemId = 'plan-item',
}) => ProductionDailyReportItem.fromJson({
  'id': id,
  'planItemId': planItemId,
  'executionSegmentId': 'segment',
  'goodsId': 'goods',
  'unitId': 'unit',
  'unitRate': 1,
  'qty': qty,
  'weight': weight,
  'outputBatchId': batch,
  if (batch != null) 'outputBatchQty': 400,
  'allowActualOverproduction': true,
  'publicOutput': public,
  'actualSurplus': public,
  'outputKind': public ? 'ACTUAL_SURPLUS' : 'PLANNED',
  'destination': public ? 'WAREHOUSE' : 'WORKSHOP',
  if (!public) 'salesOrderItemId': 'order-$id',
  if (!public) 'directTransferDemandId': 'target-$id',
});
