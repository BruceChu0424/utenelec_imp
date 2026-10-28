import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_cost_repository.dart';
import 'package:uten_imp/shared/search/table_column_query.dart';

void main() {
  test(
    'cost versions preserve full-scope criteria and frozen currency/unit display without using the latest-only bootstrap list',
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
                  'items': [
                    {
                      'id': 'older-cost',
                      'name': '历史成本_%',
                      'version': 9007199254740992,
                      'versionExact': '9007199254740993',
                      'knownTotal': '90071992547409.0001',
                      'currencyId': 'frozen-currency',
                      'currencyName': '原币',
                      'unitId': 'frozen-unit',
                      'unitName': '原单位',
                    },
                  ],
                  'page': 2,
                  'size': 50,
                  'total': 501,
                  'totalPages': 11,
                  'readScopeVersion': 'cost-proof',
                  'facets': {
                    'currencyName': [
                      {'value': 'frozen-currency', 'label': '原币', 'count': 501},
                    ],
                  },
                },
              ),
            );
          },
        ),
      );
      final result = await DioGoodsCostRepository(ApiClient(dio)).versions(
        'goods-scope',
        page: 2,
        columnQuery: const TableColumnQuery(
          searches: {
            'search.name': '历史成本_%',
            'search.knownTotal': '>=90071992547409.0001',
            'search.updatedAt': '2026-01',
            'status': 'CONFIRMED',
            'currencyName': 'frozen-currency',
          },
          sort: 'updatedAt',
          ascending: false,
        ),
      );
      expect(requests.single.path, '/master/goods/cost-sheets/versions');
      expect(
        requests.single.queryParameters,
        containsPair('goodsId', 'goods-scope'),
      );
      expect(requests.single.queryParameters, containsPair('page', 2));
      expect(
        requests.single.queryParameters,
        containsPair('status', 'CONFIRMED'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('currencyId', 'frozen-currency'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.knownTotal', '>=90071992547409.0001'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.name', '历史成本_%'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.updatedAt', '2026-01'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('sort', 'updatedAt'),
      );
      expect(requests.single.queryParameters, containsPair('order', 'desc'));
      expect(result.items.single['knownTotal'], '90071992547409.0001');
      expect(result.items.single['versionExact'], '9007199254740993');
      expect(result.items.single['unitName'], '原单位');
      expect(result.facets['currencyName']!.single.value, 'frozen-currency');
      expect(result.readScopeVersion, 'cost-proof');
      expect(result.total, 501);
    },
  );
}
