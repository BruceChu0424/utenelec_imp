import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  for (final method in <String>['GET', 'POST']) {
    test(
      'delayed $method response from an old account is rejected after login replacement',
      () async {
        final storage = SecureStorage(const FlutterSecureStorage());
        await storage.saveTokens(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
        );
        final requestStarted = Completer<void>();
        final releaseResponse = Completer<void>();
        var networkCalls = 0;
        final dio = _staffDio(storage, (request) async {
          networkCalls++;
          if (!requestStarted.isCompleted) requestStarted.complete();
          await releaseResponse.future;
          return _jsonResponse(request, 200, <String, Object?>{'ok': true});
        });

        final future = method == 'GET'
            ? dio.get<dynamic>('/business/item')
            : dio.post<dynamic>(
                '/business/item',
                data: <String, Object?>{'name': 'old account write'},
              );
        await requestStarted.future;

        final replacement = await storage.beginSessionIntent(clearTokens: true);
        await storage.commitSessionIntentTokens(
          intent: replacement.intent,
          accessToken: 'new-access',
          refreshToken: 'new-refresh',
        );
        releaseResponse.complete();

        await expectLater(
          future,
          throwsA(
            isA<DioException>()
                .having((error) => error.response?.statusCode, 'status', 409)
                .having(
                  (error) => (error.response?.data as Map?)?['code'],
                  'code',
                  'SESSION_CHANGED',
                ),
          ),
        );
        expect(networkCalls, 1, reason: 'business writes are never replayed');
      },
    );
  }

  test('same-lineage refresh does not discard an in-flight response', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'refresh',
    );
    final submitted = await storage.getAuthTokenSnapshot();
    final requestStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    final dio = _staffDio(storage, (request) async {
      if (!requestStarted.isCompleted) requestStarted.complete();
      await releaseResponse.future;
      return _jsonResponse(request, 200, <String, Object?>{'ok': true});
    });

    final future = dio.get<dynamic>('/business/item');
    await requestStarted.future;
    expect(
      await storage.saveTokensIfUnchanged(
        expected: submitted,
        accessToken: 'rotated-access',
        refreshToken: 'rotated-refresh',
      ),
      isTrue,
    );
    releaseResponse.complete();

    final response = await future;
    expect(response.statusCode, 200);
    expect(response.data, <String, Object?>{'ok': true});
  });
}

typedef _Responder = FutureOr<ResponseBody> Function(
  RequestOptions requestOptions,
);

Dio _staffDio(SecureStorage storage, _Responder responder) {
  Dio clientFactory() {
    final dio = Dio(buildApiBaseOptions('https://erp.example.cn/api'));
    dio.httpClientAdapter = _Adapter(responder);
    return dio;
  }

  final dio = clientFactory();
  dio.interceptors.add(
    AuthInterceptor(
      storage: storage,
      baseUrl: 'https://erp.example.cn/api',
      dioFactory: clientFactory,
    ),
  );
  return dio;
}

ResponseBody _jsonResponse(RequestOptions request, int status, Object body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

class _Adapter implements HttpClientAdapter {
  _Adapter(this.responder);

  final _Responder responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => responder(options);

  @override
  void close({bool force = false}) {}
}
