import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_import_repository.dart';

void main() {
  test(
    'corrected partial detection and commit retain exact file, cells and exclusions',
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
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final repository = DioGoodsImportRepository(ApiClient(dio));
      final bytes = Uint8List.fromList([1, 2, 3]);
      const cells = {
        3: {'code': '', 'price': '12.50'},
      };
      await repository.detect(
        bytes,
        cellCorrections: cells,
        excludedRowNums: {2},
      );
      await repository.commit(
        bytes,
        planId: 'plan-1',
        cellCorrections: cells,
        excludedRowNums: {2},
      );
      for (final request in requests) {
        expect(request.queryParameters, isEmpty);
        expect(request.contentType, 'application/json');
        final body = request.data as Map;
        expect(body['file'], base64Encode(bytes));
        expect(body['cellCorrections'], {
          '3': {'code': '', 'price': '12.50'},
        });
        expect(body['excludedRowNums'], [2]);
      }
    },
  );

  test(
    'commit binds the detection, exact file and selected conflicts in the body',
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
        replaceRowKeys: {'goods:2', 'goods:7'},
      );

      expect(captured.path, '/master/goods/import/commit');
      expect(captured.queryParameters, isEmpty);
      expect(captured.data, {
        'file': base64Encode(bytes),
        'planId': '6d81ea14-947b-4f1b-a4fc-8130ca6546ab',
        'filename': 'goods.xlsx',
        'replaceRowKeys': ['goods:2', 'goods:7'],
      });
      expect(captured.contentType, 'application/json');
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

  // 2026-10-28 导入模式：原始字节流检测把模式放 query，JSON 提交放 body；
  // 不传模式时两侧都不携带（服务端按混合处理）。
  test('import mode rides the raw detect query and the commit body', () async {
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
              data: <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final repository = DioGoodsImportRepository(ApiClient(dio));
    final bytes = Uint8List.fromList([1, 2, 3]);

    await repository.detect(bytes, mode: GoodsImportMode.createOnly);
    await repository.commit(
      bytes,
      planId: 'plan-1',
      mode: GoodsImportMode.updateOnly,
    );

    expect(requests.first.queryParameters, {'mode': 'CREATE_ONLY'});
    final body = requests.last.data as Map;
    expect(body['mode'], 'UPDATE_ONLY');
    expect(requests.last.queryParameters, isEmpty);
  });

  test('omitting the mode sends no mode key on either path', () async {
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
              data: <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final repository = DioGoodsImportRepository(ApiClient(dio));
    final bytes = Uint8List.fromList([1, 2, 3]);

    await repository.detect(bytes);
    await repository.commit(bytes, planId: 'plan-1');

    expect(requests.first.queryParameters, isEmpty);
    expect((requests.last.data as Map).containsKey('mode'), isFalse);
  });
}
