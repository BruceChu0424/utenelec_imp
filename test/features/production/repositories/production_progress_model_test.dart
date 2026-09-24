import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  test('plan, nested plan and MRP keep public receipts outside progress', () {
    final json = <String, dynamic>{
      'planId': 'plan',
      'totalQty': 100,
      'inboundQty': 110,
      'plannedInboundQty': 80,
      'actualSurplusInboundQty': 30,
      'percent': 0.8,
      'closed': false,
    };
    final plan = PlanProgressRow.fromJson(json);
    expect(plan.inboundQty, 110);
    expect(plan.plannedInboundQty, 80);
    expect(plan.actualSurplusInboundQty, 30);
    expect(plan.percent, 0.8);
    expect(plan.closed, isFalse);
    expect(plan.copyWith(pinned: true).plannedInboundQty, 80);
    expect(plan.copyWith(important: true).actualSurplusInboundQty, 30);
    expect(SubPlanProgress.fromJson(json).plannedInboundQty, 80);
    expect(SubPlanProgress.fromJson(json).actualSurplusInboundQty, 30);
    expect(MrpSubplanRef.fromJson(json).plannedInboundQty, 80);
    expect(MrpSubplanRef.fromJson(json).actualSurplusInboundQty, 30);
  });
  test('计划进度分别解析报工与成品入库数量', () {
    final row = PlanProgressRow.fromJson({
      'planId': 'plan-1',
      'totalQty': 100,
      'reportedQty': 72,
      'inboundQty': 60,
      'materialState': 'PARTIAL',
      'materialSegmentCount': 5,
      'materialReadySegmentCount': 3,
      'materialTotalQty': 100,
      'materialReadyQty': 60,
      'materialPercent': 0.6,
      'canStartNow': true,
      'percent': 0.6,
      'subplans': [
        {
          'planId': 'subplan-1',
          'totalQty': 40,
          'reportedQty': 30,
          'inboundQty': 20,
          'materialState': 'WAITING',
          'materialSegmentCount': 2,
          'materialReadySegmentCount': 0,
          'materialTotalQty': 40,
          'materialReadyQty': 0,
          'materialPercent': 0,
          'canStartNow': false,
          'percent': 0.5,
        },
      ],
    });

    expect(row.totalQty, 100);
    expect(row.reportedQty, 72);
    expect(row.inboundQty, 60);
    expect(row.materialState, 'PARTIAL');
    expect(row.materialReadyQty, 60);
    expect(row.materialPercent, 0.6);
    expect(row.canStartNow, isTrue);
    expect(row.percent, 0.6);
    expect(row.subplans.single.reportedQty, 30);
    expect(row.subplans.single.inboundQty, 20);
    expect(row.subplans.single.materialState, 'WAITING');
    expect(row.subplans.single.materialSegmentCount, 2);
  });

  test('旧响应没有 reportedQty 时保持兼容', () {
    final row = PlanProgressRow.fromJson({
      'planId': 'plan-legacy',
      'totalQty': 10,
      'inboundQty': 2,
    });

    expect(row.reportedQty, isNull);
    expect(row.inboundQty, 2);
    expect(row.plannedInboundQty, 2);
    expect(row.actualSurplusInboundQty, 0);
    expect(row.materialState, isNull);
    expect(row.materialPercent, isNull);
  });
}
