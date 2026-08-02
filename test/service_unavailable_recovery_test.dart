import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';

void main() {
  test(
    'structured SERVICE_UNAVAILABLE retries safe read without health loop',
    () async {
      var probes = 0;
      final recovery = ConnectionRecoveryController(
        probe: () async {
          probes++;
          return true;
        },
        probeDelays: const <Duration>[Duration.zero],
      );
      addTearDown(recovery.dispose);
      var attempts = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      dio.httpClientAdapter = _Adapter((options) {
        attempts++;
        return _jsonResponse(<String, String>{
          'code': 'SERVICE_UNAVAILABLE',
        }, 503);
      });
      dio.interceptors.add(
        SafeRequestRetryInterceptor(
          dio,
          recovery: recovery,
          delay: (_) async {},
        ),
      );

      await expectLater(
        dio.get<dynamic>('/permissions'),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();

      expect(attempts, 3);
      expect(probes, 0);
      expect(recovery.state.phase, ConnectionRecoveryPhase.connected);
      expect(recovery.state.recoveryEpoch, 0);
    },
  );

  test('structured SERVICE_UNAVAILABLE never replays a write', () async {
    final recovery = ConnectionRecoveryController(probe: () async => true);
    addTearDown(recovery.dispose);
    var attempts = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter((options) {
      attempts++;
      return _jsonResponse(<String, String>{
        'code': 'SERVICE_UNAVAILABLE',
      }, 503);
    });
    dio.interceptors.add(
      SafeRequestRetryInterceptor(dio, recovery: recovery, delay: (_) async {}),
    );

    await expectLater(
      dio.post<dynamic>('/orders'),
      throwsA(isA<DioException>()),
    );

    expect(attempts, 1);
    expect(recovery.state.phase, ConnectionRecoveryPhase.connected);
  });

  test('unstructured 503 still enters connectivity recovery', () async {
    final recovery = ConnectionRecoveryController(
      probe: () async => false,
      probeDelays: const <Duration>[Duration(hours: 1)],
      probeDelayJitter: (delay) => delay,
    );
    addTearDown(recovery.dispose);
    final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter(
      (options) => _jsonResponse(<String, String>{'code': 'INTERNAL'}, 503),
    );
    dio.interceptors.add(
      SafeRequestRetryInterceptor(dio, recovery: recovery, delay: (_) async {}),
    );

    await expectLater(dio.get<dynamic>('/items'), throwsA(isA<DioException>()));

    expect(recovery.state.phase, ConnectionRecoveryPhase.disconnected);
  });
}

ResponseBody _jsonResponse(Object body, int status) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: <String, List<String>>{
    Headers.contentTypeHeader: <String>[Headers.jsonContentType],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.responder);

  final ResponseBody Function(RequestOptions options) responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => responder(options);

  @override
  void close({bool force = false}) {}
}
