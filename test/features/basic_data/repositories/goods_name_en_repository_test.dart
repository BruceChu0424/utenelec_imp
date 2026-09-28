// ADR-134 goods English name: name-only endpoint wire contract
// (SPEC v2 section 5.8, PUT /master/goods/{id}/name-en {nameEn, version}).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_name_en_repository.dart';

void main() {
  late List<RequestOptions> requests;

  DioGoodsNameEnRepository repository() {
    requests = <RequestOptions>[];
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
    return DioGoodsNameEnRepository(ApiClient(dio));
  }

  test(
    'saves the trimmed English name with the optimistic lock version',
    () async {
      final repo = repository();

      await repo.update(
        ' goods-1 ',
        nameEn: '  DOUBLE 3 PIN SOCKET WITH SWITCH ',
        version: 7,
      );

      expect(requests.single.method, 'PUT');
      expect(requests.single.path, '/master/goods/goods-1/name-en');
      expect(requests.single.data, {
        'nameEn': 'DOUBLE 3 PIN SOCKET WITH SWITCH',
        'version': 7,
      });
    },
  );

  test('blank input clears the English name (sent as null)', () async {
    final repo = repository();

    await repo.update('goods-1', nameEn: '   ', version: 3);

    expect(requests.single.data, {'nameEn': null, 'version': 3});
  });

  test('a missing version is omitted rather than sent as null', () async {
    final repo = repository();

    await repo.update('goods-1', nameEn: 'SOCKET', version: null);

    expect(requests.single.data, {'nameEn': 'SOCKET'});
  });

  test('refuses blank ids and over-long names before sending', () async {
    final repo = repository();

    await expectLater(
      repo.update(' ', nameEn: 'SOCKET', version: 1),
      throwsArgumentError,
    );
    await expectLater(
      repo.update(
        'goods-1',
        nameEn: 'A' * (kGoodsNameEnMaxLength + 1),
        version: 1,
      ),
      throwsArgumentError,
    );
    expect(requests, isEmpty);
  });

  test('normalizeGoodsNameEnInput trims and maps blank to null', () {
    expect(normalizeGoodsNameEnInput(null), isNull);
    expect(normalizeGoodsNameEnInput('  '), isNull);
    expect(normalizeGoodsNameEnInput(' Socket '), 'Socket');
  });
}
