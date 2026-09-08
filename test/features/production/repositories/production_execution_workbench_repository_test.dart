import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';

void main() {
  test(
    'workshop defaults to all active tasks and reportable filtering is explicit',
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
      await repository.workshopTasks(status: 'READY_TO_REPORT');
      expect(requests.first.queryParameters, {'page': 1, 'size': 50});
      expect(requests.last.queryParameters, {
        'page': 1,
        'size': 50,
        'status': 'READY_TO_REPORT',
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

  test('workshop task count parses the per-status breakdown', () async {
    late RequestOptions captured;
    final repository = ProductionExecutionWorkbenchRepository(
      _api((request) {
        captured = request;
        return {
          'count': 6,
          'preparing': 3,
          'readyToReport': 2,
          'inProgress': 1,
        };
      }),
    );
    final breakdown = await repository.workshopTaskCount();
    expect(captured.path, '/production/workshop-tasks/count');
    expect(breakdown.count, 6);
    expect(breakdown.preparing, 3);
    expect(breakdown.readyToReport, 2);
    expect(breakdown.inProgress, 1);
    expect(
      breakdown.preparing + breakdown.readyToReport + breakdown.inProgress,
      breakdown.count,
    );
  });
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
