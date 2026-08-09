import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/token_refresh_result.dart';
import 'package:uten_imp/core/network/interceptors/visitor_auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/network/visitor_session_event_bus.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('destructive refresh rejection requires a matching structured code', () {
    final request = RequestOptions(path: '/auth/refresh');
    for (final scenario in <(int, String)>[
      (401, 'UNAUTHORIZED'),
      (401, 'ACCOUNT_LOCKED'),
      (401, 'ACCOUNT_DISABLED'),
      (422, 'VALIDATION_FAILED'),
      (403, 'VISITOR_BLOCKED'),
      (403, 'REMOTE_ACCESS_DENIED'),
    ]) {
      expect(
        isDefinitiveRefreshRejection(
          Response<dynamic>(
            requestOptions: request,
            statusCode: scenario.$1,
            data: <String, String>{'code': scenario.$2},
          ),
        ),
        isTrue,
        reason: '${scenario.$1}/${scenario.$2}',
      );
    }

    for (final response in <Response<dynamic>>[
      Response<dynamic>(
        requestOptions: request,
        statusCode: 401,
        data: '<html>proxy failure</html>',
      ),
      Response<dynamic>(requestOptions: request, statusCode: 401),
      Response<dynamic>(
        requestOptions: request,
        statusCode: 401,
        data: <String, String>{'code': 'UNKNOWN'},
      ),
      Response<dynamic>(
        requestOptions: request,
        statusCode: 401,
        data: <String, String>{'code': 'VALIDATION_FAILED'},
      ),
      Response<dynamic>(
        requestOptions: request,
        statusCode: 500,
        data: <String, String>{'code': 'UNAUTHORIZED'},
      ),
    ]) {
      expect(isDefinitiveRefreshRejection(response), isFalse);
    }
  });

  test(
    'staff remote-access revocation clears the exact rejected session',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'revoked-remote-access',
        refreshToken: 'revoked-remote-refresh',
      );
      var expirations = 0;
      final subscription = SessionEventBus.instance.onSessionExpired.listen(
        (_) => expirations++,
      );
      addTearDown(subscription.cancel);
      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') {
          return _jsonResponse(request, 403, <String, String>{
            'code': 'REMOTE_ACCESS_DENIED',
          });
        }
        return _jsonResponse(request, 401, <String, String>{
          'code': 'UNAUTHORIZED',
        });
      });

      await expectLater(
        dio.get<dynamic>('/protected'),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();

      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(expirations, 1);
    },
  );

  for (final failure in _nonAuthoritativeFailures) {
    test('staff ${failure.name} refresh failure preserves session', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'staff-access',
        refreshToken: 'staff-refresh',
      );
      var expirations = 0;
      final subscription = SessionEventBus.instance.onSessionExpired.listen(
        (_) => expirations++,
      );
      addTearDown(subscription.cancel);
      final dio = _staffDio(storage, (request) {
        if (request.path == '/auth/refresh') {
          return failure.response(request);
        }
        return _jsonResponse(request, 401, <String, String>{
          'code': 'UNAUTHORIZED',
        });
      });

      await expectLater(
        dio.get<dynamic>('/protected'),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();

      expect(await storage.getAccessToken(), 'staff-access');
      expect(await storage.getRefreshToken(), 'staff-refresh');
      expect(expirations, 0);
    });

    test('visitor ${failure.name} refresh failure preserves session', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveVisitorTokens(
        accessToken: 'visitor-access',
        refreshToken: 'visitor-refresh',
      );
      var expirations = 0;
      final subscription = VisitorSessionEventBus.instance.onSessionExpired
          .listen((_) => expirations++);
      addTearDown(subscription.cancel);
      final dio = _visitorDio(storage, (request) {
        if (request.path == '/visitor/auth/refresh') {
          return failure.response(request);
        }
        return _jsonResponse(request, 401, <String, String>{
          'code': 'UNAUTHORIZED',
        });
      });

      await expectLater(
        dio.get<dynamic>('/visitor/applications/mine'),
        throwsA(isA<DioException>()),
      );
      await pumpEventQueue();

      expect(await storage.getVisitorAccessToken(), 'visitor-access');
      expect(await storage.getVisitorRefreshToken(), 'visitor-refresh');
      expect(expirations, 0);
    });
  }
}

const _nonAuthoritativeFailures = <_Failure>[
  _Failure('HTML 401', 401, '<html>upstream failed</html>', 'text/html'),
  _Failure('empty 401', 401, '', 'text/plain'),
  _Failure('unknown-code 401', 401, <String, String>{
    'code': 'UNKNOWN',
  }, Headers.jsonContentType),
  _Failure('status-mismatch 401', 401, <String, String>{
    'code': 'VALIDATION_FAILED',
  }, Headers.jsonContentType),
];

class _Failure {
  const _Failure(this.name, this.status, this.body, this.contentType);

  final String name;
  final int status;
  final Object body;
  final String contentType;

  ResponseBody response(RequestOptions request) => ResponseBody.fromString(
    body is String ? body as String : jsonEncode(body),
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[contentType],
    },
  );
}

typedef _Responder =
    FutureOr<ResponseBody> Function(RequestOptions requestOptions);

Dio _staffDio(SecureStorage storage, _Responder responder) {
  Dio factory() {
    final dio = Dio(buildApiBaseOptions('https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter(responder);
    return dio;
  }

  final dio = factory();
  dio.interceptors.add(
    AuthInterceptor(
      storage: storage,
      baseUrl: 'https://erp.example.test/api',
      dioFactory: factory,
    ),
  );
  return dio;
}

Dio _visitorDio(SecureStorage storage, _Responder responder) {
  Dio factory() {
    final dio = Dio(buildApiBaseOptions('https://erp.example.test/api'));
    dio.httpClientAdapter = _Adapter(responder);
    return dio;
  }

  final dio = factory();
  dio.interceptors.add(
    VisitorAuthInterceptor(
      storage: storage,
      baseUrl: 'https://erp.example.test/api',
      dioFactory: factory,
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
