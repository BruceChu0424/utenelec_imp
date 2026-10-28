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
                  'facets': {
                    'colorName': [
                      {'value': '浅灰', 'count': 201},
                    ],
                  },
                  'nullCounts': {'colorName': 3},
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
      expect(page.facets['colorName']!.single.value, '浅灰');
      expect(page.facets['colorName']!.single.count, 201);
      expect(page.nullCounts['colorName'], 3);
      await repository.list(page: 2, size: 200, applicationId: 'parent-id');
      expect(requests.last.queryParameters, {
        'page': 2,
        'size': 200,
        'applicationId': 'parent-id',
      });
      await repository.list(
        applicationId: 'parent-id',
        sort: 'differenceQty',
        order: 'desc',
        columnFilters: {
          'search.differenceQty': '-9007199254740993.0001..0',
          'search.goods': '毛坯',
          'colorName': '浅灰',
        },
      );
      expect(
        requests.last.queryParameters,
        containsPair('applicationId', 'parent-id'),
      );
      expect(
        requests.last.queryParameters,
        containsPair('search.differenceQty', '-9007199254740993.0001..0'),
      );
      expect(requests.last.queryParameters, containsPair('search.goods', '毛坯'));
      expect(requests.last.queryParameters, containsPair('f.colorName', '浅灰'));
      expect(
        requests.last.queryParameters,
        containsPair('sort', 'differenceQty'),
      );
    },
  );
}
