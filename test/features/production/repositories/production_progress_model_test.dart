import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
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
    expect(row.materialState, isNull);
    expect(row.materialPercent, isNull);
  });
}
