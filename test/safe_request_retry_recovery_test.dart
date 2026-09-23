import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';

void main() {
  test(
    'slow read (timeout) is attempted once and never marks disconnected',
    () async {
      // ADR-108 / perf-frontend-07: 慢查询超时不重试、不判断网(此前 15 秒被掐 + 重试 2 次,
      // 把服务端负载放大 3 倍, 最后判断网、整站重建)。Web 端建连超时也只是计时器。
      for (final (slow, web) in [
        (DioExceptionType.connectionTimeout, true),
        (DioExceptionType.receiveTimeout, true),
        (DioExceptionType.receiveTimeout, false),
      ]) {
        var attempts = 0;
        final recovery = ConnectionRecoveryController(probe: () async => false);
        addTearDown(recovery.dispose);
        final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
        dio.httpClientAdapter = _Adapter((options) {
          attempts++;
          throw DioException(requestOptions: options, type: slow);
        });
        dio.interceptors.add(
          SafeRequestRetryInterceptor(
            dio,
            recovery: recovery,
            delay: (_) async {},
            web: web,
          ),
        );

        await expectLater(
          dio.get<dynamic>('/production/execution-workbench'),
          throwsA(isA<DioException>()),
        );
        expect(attempts, 1, reason: '$slow web=$web');
        expect(
          recovery.state.phase,
          isNot(ConnectionRecoveryPhase.disconnected),
          reason: '$slow web=$web',
        );
      }
    },
  );

  test('原生端建连超时 = 服务器连不上: 读请求重试, 耗尽后进入断网恢复', () async {
    var attempts = 0;
    final recovery = ConnectionRecoveryController(
      probe: () async => false,
      probeDelays: const [Duration(hours: 1)],
    );
    addTearDown(recovery.dispose);
    final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter((options) {
      attempts++;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    });
    dio.interceptors.add(
      SafeRequestRetryInterceptor(
        dio,
        recovery: recovery,
        delay: (_) async {},
        web: false,
      ),
    );

    await expectLater(dio.get<dynamic>('/items'), throwsA(isA<DioException>()));
    expect(attempts, 3);
    expect(recovery.state.phase, ConnectionRecoveryPhase.disconnected);
  });

  test('safe read reconnects after two transient failures', () async {
    var attempts = 0;
    final recovery = ConnectionRecoveryController(probe: () async => false);
    addTearDown(recovery.dispose);
    final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter((options) {
      attempts++;
      if (attempts < 3) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return ResponseBody.fromString('{}', 200);
    });
    dio.interceptors.add(
      SafeRequestRetryInterceptor(dio, recovery: recovery, delay: (_) async {}),
    );

    await dio.get<dynamic>('/items');

    expect(attempts, 3);
    expect(recovery.state.phase, ConnectionRecoveryPhase.connected);
    expect(recovery.state.recoveryEpoch, 0);
  });

  test(
    'exhausted read starts background recovery without replaying writes',
    () async {
      var getAttempts = 0;
      final recovery = ConnectionRecoveryController(
        probe: () async => false,
        probeDelays: const [Duration(hours: 1)],
      );
      addTearDown(recovery.dispose);
      final getDio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      getDio.httpClientAdapter = _Adapter((options) {
        getAttempts++;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      getDio.interceptors.add(
        SafeRequestRetryInterceptor(
          getDio,
          recovery: recovery,
          delay: (_) async {},
        ),
      );

      await expectLater(
        getDio.get<dynamic>('/items'),
        throwsA(isA<DioException>()),
      );
      expect(getAttempts, 3);
      expect(recovery.state.phase, ConnectionRecoveryPhase.disconnected);

      var postAttempts = 0;
      final postDio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      postDio.httpClientAdapter = _Adapter((options) {
        postAttempts++;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      postDio.interceptors.add(
        SafeRequestRetryInterceptor(
          postDio,
          recovery: recovery,
          delay: (_) async {},
        ),
      );

      await expectLater(
        postDio.post<dynamic>('/orders'),
        throwsA(isA<DioException>()),
      );
      expect(postAttempts, 1);
    },
  );

  test(
    'authorization response is reachable and never labelled offline',
    () async {
      final recovery = ConnectionRecoveryController(probe: () async => false);
      addTearDown(recovery.dispose);
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.example.test/api'));
      dio.httpClientAdapter = _Adapter(
        (options) => ResponseBody.fromString('{}', 403),
      );
      dio.interceptors.add(
        SafeRequestRetryInterceptor(
          dio,
          recovery: recovery,
          delay: (_) async {},
        ),
      );

      await expectLater(
        dio.get<dynamic>('/admin-only'),
        throwsA(isA<DioException>()),
      );
      expect(recovery.state.phase, ConnectionRecoveryPhase.connected);
    },
  );
}

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
