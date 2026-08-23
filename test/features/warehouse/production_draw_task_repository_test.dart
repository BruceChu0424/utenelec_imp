import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/repositories/production_draw_task_repository.dart';

void main() {
  test('warehouse task count uses the dedicated open-draw endpoint', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {'count': 6},
            ),
          );
        },
      ),
    );
    final repository = ProductionDrawTaskRepository(ApiClient(dio));

    final count = await repository.pendingCount();

    expect(count, 6);
    expect(captured.method, 'GET');
    expect(captured.path, '/operations/workbench/warehouse/count');
  });
}
