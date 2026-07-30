import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/visitor_auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/network/visitor_session_event_bus.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthInterceptor', () {
    late SecureStorage storage;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      storage = SecureStorage(const FlutterSecureStorage());
    });

    test('refresh 401 明确失效时清理令牌并只发布一次失效事件', () async {
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'invalid-refresh',
      );
      var expirations = 0;
      final subscription = SessionEventBus.instance.onSessionExpired.listen(
        (_) => expirations++,
      );
      addTearDown(subscription.cancel);

      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') {
          return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
        }
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      await expectLater(
        dio.get<dynamic>('/protected'),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
      await pumpEventQueue();

      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(expirations, 1);
    });

    test('本地缺少 refresh token 时直接失效且不调用刷新接口', () async {
      await storage.saveTokens(accessToken: 'old-access');
      var refreshAttempts = 0;
      var expirations = 0;
      final subscription = SessionEventBus.instance.onSessionExpired.listen(
        (_) => expirations++,
      );
      addTearDown(subscription.cancel);

      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') refreshAttempts++;
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      await expectLater(
        dio.get<dynamic>('/protected'),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();

      expect(refreshAttempts, 0);
      expect(await storage.getAccessToken(), isNull);
      expect(expirations, 1);
    });

    for (final status in [403, 429, 500, 503]) {
      test('refresh $status 属于瞬态失败，不清理会话', () async {
        await storage.saveTokens(
          accessToken: 'old-access',
          refreshToken: 'valid-refresh',
        );
        var expirations = 0;
        final subscription = SessionEventBus.instance.onSessionExpired.listen(
          (_) => expirations++,
        );
        addTearDown(subscription.cancel);

        final dio = _staffDio(storage, (request) {
          if (request.path == '/auth/refresh') {
            return _jsonResponse(request, status, {'code': 'INTERNAL'});
          }
          return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
        });

        await expectLater(
          dio.get<dynamic>('/protected'),
          throwsA(
            isA<DioException>().having(
              (error) => error.response?.statusCode,
              'status',
              status,
            ),
          ),
        );
        await pumpEventQueue();

        expect(await storage.getAccessToken(), 'old-access');
        expect(await storage.getRefreshToken(), 'valid-refresh');
        expect(expirations, 0);
      });
    }

    test('refresh 超时不清理会话，并把真实网络错误交给调用方', () async {
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'valid-refresh',
      );
      var expirations = 0;
      final subscription = SessionEventBus.instance.onSessionExpired.listen(
        (_) => expirations++,
      );
      addTearDown(subscription.cancel);

      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      await expectLater(
        dio.get<dynamic>('/protected'),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.receiveTimeout,
          ),
        ),
      );
      await pumpEventQueue();

      expect(await storage.getAccessToken(), 'old-access');
      expect(await storage.getRefreshToken(), 'valid-refresh');
      expect(expirations, 0);
    });

    for (final retryStatus in [401, 403, 500]) {
      test('刷新成功后重放返回 $retryStatus 时保留新会话', () async {
        await storage.saveTokens(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
        );
        var protectedAttempts = 0;
        var expirations = 0;
        final subscription = SessionEventBus.instance.onSessionExpired.listen(
          (_) => expirations++,
        );
        addTearDown(subscription.cancel);

        final dio = _staffDio(storage, (request) {
          if (request.path == '/auth/refresh') {
            return _jsonResponse(request, 200, {
              'accessToken': 'new-access',
              'refreshToken': 'new-refresh',
            });
          }
          protectedAttempts++;
          if (protectedAttempts == 1) {
            return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
          }
          expect(request.headers['Authorization'], 'Bearer new-access');
          return _jsonResponse(request, retryStatus, {'code': 'INTERNAL'});
        });

        await expectLater(
          dio.get<dynamic>('/protected'),
          throwsA(
            isA<DioException>().having(
              (error) => error.response?.statusCode,
              'status',
              retryStatus,
            ),
          ),
        );
        await pumpEventQueue();

        expect(protectedAttempts, 2);
        expect(await storage.getAccessToken(), 'new-access');
        expect(await storage.getRefreshToken(), 'new-refresh');
        expect(expirations, 0);
      });
    }

    test('刷新成功后使用新令牌重放并返回业务响应', () async {
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      var protectedAttempts = 0;
      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') {
          return _jsonResponse(request, 200, {
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
          });
        }
        protectedAttempts++;
        if (protectedAttempts == 1) {
          return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
        }
        expect(request.headers['Authorization'], 'Bearer new-access');
        return _jsonResponse(request, 200, {'ok': true});
      });

      final response = await dio.get<dynamic>('/protected');

      expect(response.data, {'ok': true});
      expect(protectedAttempts, 2);
      expect(await storage.getAccessToken(), 'new-access');
      expect(await storage.getRefreshToken(), 'new-refresh');
    });

    test('并发 401 共用一次 refresh 请求', () async {
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      var refreshAttempts = 0;
      final dio = _staffDio(storage, (request) async {
        if (request.path == '/auth/refresh') {
          refreshAttempts++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _jsonResponse(request, 200, {
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
          });
        }
        if (request.headers['Authorization'] == 'Bearer new-access') {
          return _jsonResponse(request, 200, {'path': request.path});
        }
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      final responses = await Future.wait([
        dio.get<dynamic>('/protected-a'),
        dio.get<dynamic>('/protected-b'),
      ]);

      expect(refreshAttempts, 1);
      expect(responses.map((response) => response.statusCode), [200, 200]);
    });

    test('refresh 200 但响应结构损坏时保留原会话', () async {
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'valid-refresh',
      );
      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') {
          return _jsonResponse(request, 200, {'unexpected': true});
        }
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      await expectLater(
        dio.get<dynamic>('/protected'),
        throwsA(
          isA<DioException>().having(
            (error) => error.message,
            'message',
            contains('accessToken'),
          ),
        ),
      );

      expect(await storage.getAccessToken(), 'old-access');
      expect(await storage.getRefreshToken(), 'valid-refresh');
    });

    test('已标记为鉴权重放的 401 不重复刷新，也不直接销毁会话', () async {
      await storage.saveTokens(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      var refreshAttempts = 0;
      var expirations = 0;
      final subscription = SessionEventBus.instance.onSessionExpired.listen(
        (_) => expirations++,
      );
      addTearDown(subscription.cancel);

      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') refreshAttempts++;
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      await expectLater(
        dio.get<dynamic>(
          '/protected',
          options: Options(extra: {'retried': true}),
        ),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();

      expect(refreshAttempts, 0);
      expect(await storage.getAccessToken(), 'new-access');
      expect(await storage.getRefreshToken(), 'new-refresh');
      expect(expirations, 0);
    });
  });

  group('VisitorAuthInterceptor', () {
    late SecureStorage storage;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      storage = SecureStorage(const FlutterSecureStorage());
    });

    test('访客 refresh 503 时保留令牌且不发布失效事件', () async {
      await storage.saveVisitorTokens(
        accessToken: 'old-access',
        refreshToken: 'valid-refresh',
      );
      var expirations = 0;
      final subscription = VisitorSessionEventBus.instance.onSessionExpired
          .listen((_) => expirations++);
      addTearDown(subscription.cancel);

      final dio = _visitorDio(storage, (request) {
        if (request.path == '/visitor/auth/refresh') {
          return _jsonResponse(request, 503, {'code': 'INTERNAL'});
        }
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      await expectLater(
        dio.get<dynamic>('/visitor/applications/mine'),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status',
            503,
          ),
        ),
      );
      await pumpEventQueue();

      expect(await storage.getVisitorAccessToken(), 'old-access');
      expect(await storage.getVisitorRefreshToken(), 'valid-refresh');
      expect(expirations, 0);
    });

    test('访客 refresh 401 时清理令牌并发布失效事件', () async {
      await storage.saveVisitorTokens(
        accessToken: 'old-access',
        refreshToken: 'invalid-refresh',
      );
      var expirations = 0;
      final subscription = VisitorSessionEventBus.instance.onSessionExpired
          .listen((_) => expirations++);
      addTearDown(subscription.cancel);

      final dio = _visitorDio(storage, (request) {
        if (request.path == '/visitor/auth/refresh') {
          return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
        }
        return _jsonResponse(request, 401, {'code': 'UNAUTHORIZED'});
      });

      await expectLater(
        dio.get<dynamic>('/visitor/applications/mine'),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();

      expect(await storage.getVisitorAccessToken(), isNull);
      expect(await storage.getVisitorRefreshToken(), isNull);
      expect(expirations, 1);
    });
  });
}

typedef _Responder =
    FutureOr<ResponseBody> Function(RequestOptions requestOptions);

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

Dio _visitorDio(SecureStorage storage, _Responder responder) {
  Dio clientFactory() {
    final dio = Dio(buildApiBaseOptions('https://erp.example.cn/api'));
    dio.httpClientAdapter = _Adapter(responder);
    return dio;
  }

  final dio = clientFactory();
  dio.interceptors.add(
    VisitorAuthInterceptor(
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
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
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
