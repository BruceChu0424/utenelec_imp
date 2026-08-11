import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/reportable_plan_line.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  test('reportable plan line preserves authoritative allocation fields', () {
    final line = ReportablePlanLine.fromJson({
      'planItemId': 'plan-item-1',
      'executionSegmentId': 'segment-1',
      'executionSegmentCode': 'SEG-001',
      'executionSegmentStatus': 'DISPATCHED',
      'executionSegmentVersion': 2,
      'orderItemId': 'order-item-1',
      'planNo': 'SJ-001',
      'productNo': 'SJ-001-1',
      'goodsId': 'goods-1',
      'goodsCode': 'P-001',
      'goodsName': '成品灯',
      'goodsSpec': '300mm',
      'colorId': 'color-1',
      'unitId': 'unit-1',
      'unitRate': 12.5,
      'remainingPlanQty': 20,
      'allocatedQty': 15,
      'linkedProducedQty': 5,
      'maxReportQty': 10,
      'orderNo': 'SO-001',
      'orderQty': 30,
      'clientName': '测试客户',
      'departmentId': 'department-1',
      'workshopName': '装配一车间',
      'deliveryDate': '2026-08-01',
    });

    expect(line.planItemId, 'plan-item-1');
    expect(line.executionSegmentId, 'segment-1');
    expect(line.executionSegmentCode, 'SEG-001');
    expect(line.executionSegmentStatus, 'DISPATCHED');
    expect(line.executionSegmentVersion, 2);
    expect(line.orderItemId, 'order-item-1');
    expect(line.unitRate, 12.5);
    expect(line.maxReportQty, 10);
    expect(line.orderNo, 'SO-001');
    expect(line.workshopName, '装配一车间');
  });

  test(
    'repository uses reportable read-side filters and parses page',
    () async {
      late RequestOptions captured;
      final repository = ProductionDailyReportRepository(
        _api((request) {
          captured = request;
          return {
            'items': [
              {
                'planItemId': 'plan-item-1',
                'planNo': 'SJ-001',
                'goodsId': 'goods-1',
                'maxReportQty': 8,
              },
            ],
            'page': 1,
            'size': 100,
            'total': 1,
            'totalPages': 1,
          };
        }),
      );

      final page = await repository.reportablePlanLines(
        size: 100,
        keyword: ' SJ-001 ',
        departmentId: 'department-1',
        executionSegmentId: 'segment-1',
      );

      expect(captured.path, '/production/daily-reports/reportable-plan-lines');
      expect(captured.queryParameters, {
        'page': 1,
        'size': 100,
        'keyword': 'SJ-001',
        'departmentId': 'department-1',
        'executionSegmentId': 'segment-1',
      });
      expect(page.items.single.maxReportQty, 8);
    },
  );
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: responder(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
