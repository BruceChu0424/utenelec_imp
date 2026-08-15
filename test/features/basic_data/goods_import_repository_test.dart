import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_import_repository.dart';

void main() {
  test(
    'commit sends the detect plan id with the exact workbook bytes',
    () async {
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
                data: {
                  'batchId': 'batch-1',
                  'importedCount': 1,
                  'createdCategories': 0,
                  'createdColors': 0,
                  'createdUnits': 0,
                  'createdCategoryPaths': <Object?>[],
                },
              ),
            );
          },
        ),
      );
      final repository = DioGoodsImportRepository(ApiClient(dio));
      final bytes = Uint8List.fromList([1, 2, 3]);

      await repository.commit(
        bytes,
        planId: ' 6d81ea14-947b-4f1b-a4fc-8130ca6546ab ',
        filename: 'goods.xlsx',
      );

      expect(captured.path, '/master/goods/import/commit');
      expect(captured.queryParameters, {
        'planId': '6d81ea14-947b-4f1b-a4fc-8130ca6546ab',
        'filename': 'goods.xlsx',
      });
      expect(captured.data, same(bytes));
    },
  );

  test('commit refuses an empty detect plan before sending', () async {
    final repository = DioGoodsImportRepository(
      ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))),
    );

    expect(
      () => repository.commit(Uint8List(0), planId: '   '),
      throwsArgumentError,
    );
  });
}
