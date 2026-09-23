import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';

void main() {
  test(
    'preparation status filters and draw eligibility use server facts',
    () async {
      late RequestOptions captured;
      final repository = ProductionExecutionWorkbenchRepository(
        _api((request) {
          captured = request;
          return {
            'items': [
              {
                'segmentId': 'task-1',
                'drawRequested': false,
                'canRequestDraw': true,
              },
            ],
            'page': 2,
            'size': 50,
            'total': 51,
            'totalPages': 2,
          };
        }),
      );
      final result = await repository.workshopTasks(
        page: 2,
        status: 'PREPARING',
        preparationFilter: 'DRAW_NOT_REQUESTED',
        workshopDepartmentId: 'workshop-1',
      );
      expect(captured.queryParameters, {
        'page': 2,
        'size': 50,
        'status': 'PREPARING',
        'preparationFilter': 'DRAW_NOT_REQUESTED',
        'workshopDepartmentId': 'workshop-1',
      });
      expect(result.items.single.canRequestDraw, isTrue);
      expect(result.items.single.drawRequested, isFalse);
    },
  );
  test(
    'workshop defaults to all active tasks; history segment sends the date gate',
    () async {
      final requests = <RequestOptions>[];
      final repository = ProductionExecutionWorkbenchRepository(
        _api((request) {
          requests.add(request);
          return {
            'items': <Object>[],
            'page': 1,
            'size': 50,
            'total': 0,
            'totalPages': 0,
          };
        }),
      );
      await repository.workshopTasks();
      await repository.workshopTasks(
        status: 'COMPLETED',
        dateFrom: '2026-09-01',
        dateTo: '2026-09-10',
      );
      expect(requests.first.queryParameters, {'page': 1, 'size': 50});
      // ADR-066 §1.3：历史任务段按 dateFrom/dateTo 时间门控加载。
      expect(requests.last.queryParameters, {
        'page': 1,
        'size': 50,
        'status': 'COMPLETED',
        'dateFrom': '2026-09-01',
        'dateTo': '2026-09-10',
      });
    },
  );

  test(
    'group query keeps paging and keyword; workshop/sort params retired',
    () async {
      late RequestOptions captured;
      final repository = ProductionExecutionWorkbenchRepository(
        _api((request) {
          captured = request;
          return {
            'items': [
              {
                'rootType': 'ANALYSIS',
                'rootId': 'analysis-1',
                'rootLabel': '联合分析 SO-1 / SO-2',
                'status': 'PARTIALLY_SCHEDULED',
                'salesOrderCount': 2,
                'workOrderCount': 1,
                'workshopCount': 1,
                'productCount': 1,
                'executionUnitCount': 1,
                'planCount': 1,
                'segmentCount': 1,
              },
            ],
            'page': 2,
            'size': 50,
            'total': 51,
            'totalPages': 2,
          };
        }),
      );

      final result = await repository.groups(page: 2, keyword: '  SO-1  ');

      expect(captured.path, '/production/execution-workbench');
      expect(captured.queryParameters, {
        'page': 2,
        'size': 50,
        'keyword': 'SO-1',
      });
      expect(result.items.single.statusLabel, '部分已排 · 仍有待排数量');
    },
  );
}

ApiClient _api(Map<String, dynamic> Function(RequestOptions) response) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: response(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}
