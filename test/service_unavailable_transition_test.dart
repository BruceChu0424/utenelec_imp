import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';

void main() {
  test(
    'reachable structured 503 clears an earlier reconnecting tail',
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
        if (attempts == 1) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        }
        return ResponseBody.fromString(
          jsonEncode(<String, String>{'code': 'SERVICE_UNAVAILABLE'}),
          503,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>[Headers.jsonContentType],
          },
        );
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
