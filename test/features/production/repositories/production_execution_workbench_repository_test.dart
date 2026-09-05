import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';

void main() {
  test(
    'group query keeps paging, workshop, mine and server sort together',
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

      final result = await repository.groups(
        page: 2,
        keyword: '  SO-1  ',
        workshopDepartmentId: 'workshop-1',
        mine: true,
        sort: 'status',
        order: 'desc',
      );

      expect(captured.path, '/production/execution-workbench');
      expect(captured.queryParameters, {
        'page': 2,
        'size': 50,
        'keyword': 'SO-1',
        'workshopDepartmentId': 'workshop-1',
        'mine': true,
        'sort': 'status',
        'order': 'desc',
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
