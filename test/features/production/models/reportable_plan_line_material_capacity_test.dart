import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/reportable_plan_line.dart';

void main() {
  final ordinary = <String, dynamic>{
    'planItemId': 'plan-item',
    'planNo': 'PLAN-1',
    'goodsId': 'goods',
    'maxReportQty': 0,
    'allowActualOverproduction': true,
  };
  test(
    'exhausted partial issue cannot use actual-output allowance to report',
    () {
      final blocked = ReportablePlanLine.fromJson({
        ...ordinary,
        'materialReportQtyExact': '0',
      });
      expect(blocked.canReport, isFalse);
      expect(blocked.blockedReason, contains('物料配套可报数量已用完'));
      expect(
        ReportablePlanLine.fromJson({
          ...ordinary,
          'materialReportQtyExact': '0.0001',
        }).canReport,
        isTrue,
      );
    },
  );
  test(
    'complete issue and legacy optional responses retain actual-output entry',
    () {
      expect(ReportablePlanLine.fromJson(ordinary).canReport, isTrue);
      expect(
        ReportablePlanLine.fromJson({
          ...ordinary,
          'materialReportQtyExact': null,
        }).materialReportQtyExact,
        isNull,
      );
    },
  );
}
