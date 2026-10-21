import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_cost_repository.dart';

void main() {
  test(
    'bootstrap POST retains its query and waits for fresh scan evidence without a business write',
    () async {
      final adapter = _Adapter(gate: Completer<void>());
      final writes = <String>[];
      final dio =
          Dio(
              BaseOptions(
                baseUrl: 'https://scan.example/api',
                receiveTimeout: const Duration(seconds: 120),
              ),
            )
            ..httpClientAdapter = adapter
            ..interceptors.add(
              DataWriteRevisionInterceptor(
                (request) => writes.add(request.uri.path),
              ),
            );
      addTearDown(dio.close);
      final api = ApiClient(dio);
      final repository = DioGoodsCostRepository(api);
      var completed = false;
      final response = repository
          .bootstrap('goods-1', clientId: 'client-2')
          .then((value) {
            completed = true;
            return value;
          });
      await adapter.entered.future;
      expect(completed, isFalse);
      expect(adapter.sent.single.method, 'POST');
      expect(
        adapter.sent.single.uri.path,
        '/api/master/goods/cost-sheets/bootstrap',
      );
      expect(adapter.sent.single.queryParameters, {
        'goodsId': 'goods-1',
        'clientId': 'client-2',
      });
      expect(adapter.sent.single.data, isNull);
      expect(adapter.sent.single.receiveTimeout, const Duration(seconds: 120));
      adapter.gate!.complete();
      expect((await response).totals['amountLocal'], '7.50');
      expect(writes, isEmpty);
      await api.post(
        '/master/goods/cost-sheets',
        body: {'input': <String, dynamic>{}},
      );
      expect(writes, ['/api/master/goods/cost-sheets']);
    },
  );

  test(
    'bootstrap without a client preserves the optional query contract',
    () async {
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://scan.example/api'))
        ..httpClientAdapter = adapter;
      addTearDown(dio.close);
      await DioGoodsCostRepository(ApiClient(dio)).bootstrap('goods-1');
      expect(adapter.sent.single.queryParameters, {'goodsId': 'goods-1'});
      expect(adapter.sent.single.method, 'POST');
    },
  );

  for (final path in [
    '/master/goods/cost-sheets/bootstrap',
    '/sales/quotes/11111111-2222-3333-4444-555555555555/input-originals/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/download',
    '/sales/orders/11111111-2222-3333-4444-555555555555/approve',
  ]) {
    test('a lost transport never replays POST $path', () async {
      final adapter = _Adapter(offline: true);
      final dio = Dio(BaseOptions(baseUrl: 'https://scan.example/api'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        SafeRequestRetryInterceptor(dio, delay: (_) async {}),
      );
      addTearDown(dio.close);
      await expectLater(
        ApiClient(dio).post(path),
        throwsA(isA<ApiException>()),
      );
      expect(adapter.sent, hasLength(1));
    });
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter({this.gate, this.offline = false});

  final Completer<void>? gate;
  final bool offline;
  final entered = Completer<void>();
  final sent = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add(options);
    if (!entered.isCompleted) entered.complete();
    if (gate != null) await gate!.future;
    if (offline) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    return ResponseBody.fromString(
      '{"totals":{"amountLocal":"7.50"},"issues":[]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
