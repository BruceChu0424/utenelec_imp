import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_draw_repository.dart';

void main() {
  test(
    'draw endpoint forwards exact line or parent scope and preserves server pagination',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'page': {
                    'items': <Object?>[],
                    'page': 2,
                    'size': 200,
                    'total': 201,
                    'totalPages': 2,
                  },
                  'statusCounts': {'ALL': 201},
                  'capabilities': {'canSubmitDraw': false},
                },
              ),
            );
          },
        ),
      );
      final repository = SubcontractDrawRepository(ApiClient(dio));
      final page = await repository.list(
        page: 2,
        size: 200,
        applicationItemIds: ['line-id'],
        orderId: 'order-id',
      );
      expect(requests.single.path, '/subcontract/draw-tasks');
      expect(requests.single.queryParameters, {
        'page': 2,
        'size': 200,
        'applicationItemIds': 'line-id',
        'orderId': 'order-id',
      });
      expect(page.page.total, 201);
      expect(page.page.totalPages, 2);
      expect(page.statusCounts['ALL'], 201);
      expect(page.canSubmitDraw, isFalse);
      await repository.list(page: 2, size: 200, applicationId: 'parent-id');
      expect(requests.last.queryParameters, {
        'page': 2,
        'size': 200,
        'applicationId': 'parent-id',
      });
    },
  );
}
