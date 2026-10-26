import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/native_facet_routes.dart';

void main() {
  test(
    'candidate form freezes filters in the body and does not publish a business write',
    () async {
      final started = Completer<void>(), gate = Completer<void>();
      var writes = 0;
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'https://native.fixture/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            captured = request;
            started.complete();
            await gate.future;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{'items': <Object?>[], 'hasMore': false, 'page': 1, 'size': 100},
              ),
            );
          },
        ),
      );
      dio.interceptors.add(
        DataWriteRevisionInterceptor((_) {
          writes++;
        }),
      );
      final body = <String, dynamic>{
        'keyword': 'M3_%',
        '__facetField': 'billNo',
        '__facetPage': 1,
        '__facetSize': 100,
      };
      final result = ApiClient(dio).postForm(
        '/warehouse/document-history/purchase-receipts/facets',
        body: body,
      );
      await started.future;
      body['keyword'] = 'another query';
      gate.complete();
      expect((await result)['items'], isEmpty);
      expect(captured.queryParameters, isEmpty);
      expect((captured.data as Map<String, dynamic>)['keyword'], 'M3_%');
      expect(captured.contentType, Headers.formUrlEncodedContentType);
      expect(captured.followRedirects, isFalse);
      expect(writes, 0);
      dio.close(force: true);
    },
  );
  test(
    'only the generated exact candidate routes are treated as read-only',
    () async {
      expect(nativeFacetPaths, hasLength(21));
      for (final path in nativeFacetPaths) {
        expect(
          isBusinessWrite(RequestOptions(path: path, method: 'POST')),
          isFalse,
        );
        expect(
          isBusinessWrite(RequestOptions(path: '/api$path', method: 'POST')),
          isFalse,
        );
        expect(
          isBusinessWrite(RequestOptions(path: path, method: 'PUT')),
          isTrue,
        );
      }
      expect(
        isBusinessWrite(
          RequestOptions(
            path: '/warehouse/quality-results/facets-save',
            method: 'POST',
          ),
        ),
        isTrue,
      );
      final api = ApiClient(Dio());
      await expectLater(
        api.postForm('/warehouse/quality-results/decide', body: {}),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
