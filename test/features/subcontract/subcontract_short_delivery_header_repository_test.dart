import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_short_delivery_repository.dart';

void main() {
  test(
    'short delivery header queries stay server scoped and keep numeric expressions exact',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'items': <Map<String, dynamic>>[],
                  'page': 1,
                  'size': 50,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );
      final repository = SubcontractShortDeliveryRepository(ApiClient(dio));
      await repository.list(
        orderId: 'order-scope',
        orderBillNo: 'WW-1',
        sort: 'shortfallQty',
        order: 'desc',
        columnFilters: {
          'search.shortfallQty': '>=9007199254740993.0001',
          'search.goodsName': '毛坯',
          'severity': 'SEVERE',
        },
      );
      expect(
        requests.single.queryParameters,
        containsPair('orderId', 'order-scope'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('orderBillNo', 'WW-1'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.shortfallQty', '>=9007199254740993.0001'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.goodsName', '毛坯'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('f.severity', 'SEVERE'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('sort', 'shortfallQty'),
      );
    },
  );
}
