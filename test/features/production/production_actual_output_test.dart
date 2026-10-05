import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/models/reportable_plan_line.dart';

/// ADR-148：报工产出批次由服务端分好(outputBatches)，页面只按批内 itemIds 把各份合回一行。
ProductionDailyReportDetail _detail(
  List<Map<String, dynamic>> items,
  List<(String, List<String>, double)> batches,
) => ProductionDailyReportDetail.fromJson({
  'id': 'report',
  'items': items,
  'outputBatches': [
    for (final (key, ids, qty) in batches)
      {
        'batchKey': key,
        'sourceItemId': ids.first,
        'itemIds': ids,
        'qty': qty,
        'summary': '服务端摘要 $key',
        'groups': const <Object>[],
      },
  ],
});

void main() {
  test(
    'approved supplement reopens as one original input across two plans',
    () {
      final groups = _detail(
        [
          _supplementItem(
            'original',
            quantity: 100,
            total: 130,
            original: true,
          ),
          _supplementItem('supplement', quantity: 30, total: 130),
        ],
        [
          ('physical-batch', ['original', 'supplement'], 130),
        ],
      ).inputGroups;
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
    final group = _detail(
      [_supplementItem('supplement-only', quantity: 25, total: 25)],
      [
        ('physical-batch', ['supplement-only'], 25),
      ],
    ).inputGroups.single;
    expect(group.qty, 25);
    expect(group.planId, 'original-plan');
    expect(group.executionSegmentId, 'original-segment');
    expect(group.planNo, isNull, reason: '不得把追加计划号作为原计划快照提交');
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

  test('editing joins only the server output batch and keeps its identity', () {
    final groups = _detail(
      [
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
      ],
      [
        ('batch-a', ['demand', 'public'], 400),
        ('batch-b', ['other-demand', 'other-public'], 400),
        ('legacy-a', ['legacy-a'], 10),
        ('legacy-b', ['legacy-b'], 20),
      ],
    ).inputGroups;
    expect(groups, hasLength(4));
    expect(groups.first.qty, 400);
    expect(groups.first.weight, 4);
    expect(groups.first.source.salesOrderItemId, 'order-demand');
    expect(groups.first.source.directTransferDemandId, 'target-demand');
    expect(groups[1].source.salesOrderItemId, 'order-other-demand');
    expect(groups[2].qty, 10);
    expect(groups[3].qty, 20);
  });

  test('a server batch naming an unknown slice is never editable', () {
    expect(
      () => _detail(
        [_item('demand', batch: 'batch', qty: 300)],
        [
          ('batch', ['demand', 'missing'], 400),
        ],
      ).inputGroups,
      throwsFormatException,
    );
  });

  test('server summaries are shown as-is for approval review', () {
    final detail = _detail(
      [_item('demand', batch: 'batch', qty: 400)],
      [
        ('batch', ['demand'], 400),
      ],
    );
    expect(detail.outputBatches.single.summary, '服务端摘要 batch');
  });

  test(
    'public-only batch retains warehouse destination and no sales identity',
    () {
      final group = _detail(
        [_item('public', batch: 'batch', qty: 400, public: true)],
        [
          ('batch', ['public'], 400),
        ],
      ).inputGroups.single;
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

Map<String, dynamic> _supplementItem(
  String id, {
  required double quantity,
  required double total,
  bool original = false,
  String proof = 'proof',
}) => {
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
};

Map<String, dynamic> _item(
  String id, {
  String? batch,
  required double qty,
  bool public = false,
  double? weight,
  String planItemId = 'plan-item',
}) => {
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
};
