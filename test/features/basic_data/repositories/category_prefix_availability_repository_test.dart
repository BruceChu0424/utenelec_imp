import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_category_repository.dart';

typedef _CheckPrefix =
    Future<CategoryPrefixAvailability> Function(
      String prefix, {
      String? categoryId,
    });

void main() {
  final factories = <String, _CheckPrefix Function(ApiClient)>{
    'material': (api) => DioProductCategoryRepository(api).prefixAvailability,
    'mould': (api) => DioMouldCategoryRepository(api).prefixAvailability,
    'client': (api) => DioClientCategoryRepository(api).prefixAvailability,
    'supplier': (api) => DioSupplierCategoryRepository(api).prefixAvailability,
  };

  for (final entry in factories.entries) {
    group('${entry.key} category prefix availability', () {
      late List<RequestOptions> requests;
      late Map<String, dynamic> response;
      late _CheckPrefix check;

      setUp(() {
        requests = [];
        response = {
          'normalizedPrefix': 'UG',
          'available': true,
          'message': null,
        };
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: response,
                ),
              );
            },
          ),
        );
        check = entry.value(ApiClient(dio));
      });

      test('creation checks globally without an editing category id', () async {
        final result = await check('ug');

        final request = requests.single;
        expect(request.method, 'GET');
        expect(
          request.path,
          '/master/${entry.key}-categories/prefix-availability',
        );
        expect(request.queryParameters, {'prefix': 'ug'});
        expect(result.normalizedPrefix, 'UG');
        expect(result.available, isTrue);
        expect(result.message, isNull);
      });

      test(
        'editing includes category id and preserves occupied result',
        () async {
          response = {
            'normalizedPrefix': 'UG',
            'available': false,
            'message': '该编号前缀已被占用，请更换',
          };

          final result = await check('UG', categoryId: 'category-1');

          expect(requests.single.queryParameters, {
            'prefix': 'UG',
            'categoryId': 'category-1',
          });
          expect(result.available, isFalse);
          expect(result.message, '该编号前缀已被占用，请更换');
        },
      );
    });
  }

  test('missing or malformed availability never grants permission to save', () {
    for (final raw in [null, false, 'true', 1]) {
      final result = CategoryPrefixAvailability.fromJson({
        'normalizedPrefix': 'UG',
        'available': ?raw,
      });
      expect(result.available, isFalse);
    }
  });
}
