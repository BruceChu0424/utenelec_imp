import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthInterceptor generation races', () {
    late SecureStorage storage;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      storage = SecureStorage(const FlutterSecureStorage());
    });

    test('错峰到达的旧 401 复用新 access 且不再次刷新', () async {
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      var oldProtectedRequests = 0;
      var refreshAttempts = 0;
      final bothOldRequestsStarted = Completer<void>();
      final releaseLateResponse = Completer<void>();

      final dio = _staffDio(storage, (request) async {
        if (request.path == '/auth/refresh') {
          refreshAttempts++;
          return _jsonResponse(request, 200, <String, Object>{
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
          });
        }
        if (request.headers['Authorization'] == 'Bearer new-access') {
          return _jsonResponse(request, 200, <String, Object>{
            'path': request.path,
          });
        }

        oldProtectedRequests++;
        if (oldProtectedRequests == 2) bothOldRequestsStarted.complete();
        await bothOldRequestsStarted.future;
        if (request.path == '/protected-late') {
          await releaseLateResponse.future;
        }
        return _jsonResponse(request, 401, <String, Object>{
          'code': 'UNAUTHORIZED',
        });
      });

      final first = dio.get<dynamic>('/protected-first');
      final late = dio.get<dynamic>('/protected-late');
      final firstResponse = await first;
      releaseLateResponse.complete();
      final lateResponse = await late;

      expect(firstResponse.statusCode, 200);
      expect(lateResponse.statusCode, 200);
      expect(oldProtectedRequests, 2);
      expect(refreshAttempts, 1);
      expect(await storage.getAccessToken(), 'new-access');
      expect(await storage.getRefreshToken(), 'new-refresh');
    });

    test('两个拦截器共享存储时只允许一次 refresh', () async {
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      var oldProtectedRequests = 0;
      var refreshAttempts = 0;
      final bothOldRequestsStarted = Completer<void>();

      FutureOr<ResponseBody> responder(RequestOptions request) async {
        if (request.path == '/auth/refresh') {
          refreshAttempts++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _jsonResponse(request, 200, <String, Object>{
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
          });
        }
        if (request.headers['Authorization'] == 'Bearer new-access') {
          return _jsonResponse(request, 200, <String, Object>{
            'path': request.path,
          });
        }
        oldProtectedRequests++;
        if (oldProtectedRequests == 2) bothOldRequestsStarted.complete();
        await bothOldRequestsStarted.future;
        return _jsonResponse(request, 401, <String, Object>{
          'code': 'UNAUTHORIZED',
        });
      }

      final firstDio = _staffDio(storage, responder);
      final secondDio = _staffDio(storage, responder);
      final responses = await Future.wait(<Future<Response<dynamic>>>[
        firstDio.get<dynamic>('/protected-a'),
        secondDio.get<dynamic>('/protected-b'),
      ]);

      expect(responses.map((response) => response.statusCode), <int?>[
        200,
        200,
      ]);
      expect(oldProtectedRequests, 2);
      expect(refreshAttempts, 1);
    });

    test(
      'old request is never replayed across a replacement lineage',
      () async {
        await storage.saveTokens(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
        );
        var expirations = 0;
        final subscription = SessionEventBus.instance.onSessionExpired.listen(
          (_) => expirations++,
        );
        addTearDown(subscription.cancel);
        final refreshStarted = Completer<void>();
        final releaseRefreshFailure = Completer<void>();

        final dio = _staffDio(storage, (request) async {
          if (request.path == '/auth/refresh') {
            refreshStarted.complete();
            await releaseRefreshFailure.future;
            return _jsonResponse(request, 401, <String, Object>{
              'code': 'REFRESH_REUSE',
            });
          }
          if (request.headers['Authorization'] == 'Bearer new-access') {
            return _jsonResponse(request, 200, <String, Object>{'ok': true});
          }
          return _jsonResponse(request, 401, <String, Object>{
            'code': 'UNAUTHORIZED',
          });
        });

        final responseFuture = dio.get<dynamic>('/protected');
        await refreshStarted.future;
        await storage.saveTokens(
          accessToken: 'new-access',
          refreshToken: 'new-refresh',
        );
        releaseRefreshFailure.complete();
        await expectLater(
          responseFuture,
          throwsA(
            isA<DioException>().having(
              (error) => error.response?.statusCode,
              'status',
              401,
            ),
          ),
        );
        await pumpEventQueue();
        expect(await storage.getAccessToken(), 'new-access');
        expect(await storage.getRefreshToken(), 'new-refresh');
        expect(expirations, 0);
      },
    );
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
