@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final independentHost in [false, true]) {
    test(
      'authenticated redirect cannot escape the API ${independentHost ? 'host' : 'prefix'}',
      () => _withNetwork(() async {
        var recipientRequests = 0;
        var originalRequests = 0;
        final recipient = await _server((request) async {
          recipientRequests++;
          await _json(request, {'ok': true});
        });
        late HttpServer original;
        original = await _server((request) async {
          if (request.uri.path == '/api/protected') {
            originalRequests++;
            await _redirect(
              request,
              independentHost
                  ? 'http://localhost:${recipient.port}/independent/protected'
                  : '/independent/protected',
            );
          } else {
            recipientRequests++;
            await _json(request, {'ok': true});
          }
        });
        final fixture = await _fixture(original);

        await expectLater(
          fixture.dio.get<dynamic>(
            '/protected',
            options: Options(followRedirects: true),
          ),
          throwsA(_status(302)),
        );

        expect(originalRequests, 1);
        expect(recipientRequests, 0);
        expect(await fixture.storage.getAccessToken(), 'owned-access');
      }),
    );
  }

  for (final path in [
    '/auth/login',
    '/auth/change-password',
    '/auth/refresh',
    '/auth/logout',
  ]) {
    test(
      '$path refuses a credential-exchange redirect',
      () => _withNetwork(() async {
        var initialRequests = 0;
        var outsideRequests = 0;
        final server = await _server((request) async {
          if (request.uri.path == '/api$path') {
            initialRequests++;
            await request.drain<void>();
            await _redirect(request, '/independent/collect', status: 303);
          } else {
            outsideRequests++;
            await _json(request, {'ok': true});
          }
        });
        final fixture = await _fixture(server);

        await expectLater(
          fixture.dio.post<dynamic>(
            path,
            data: {
              'password': 'synthetic-password',
              'refreshToken': 'owned-refresh',
            },
            options: Options(
              followRedirects: true,
              headers: {'Authorization': 'Bearer owned-access'},
            ),
          ),
          throwsA(_status(303)),
        );

        expect(initialRequests, 1);
        expect(outsideRequests, 0);
        expect(await fixture.storage.getRefreshToken(), 'owned-refresh');
      }),
    );
  }

  test(
    '401 refresh transport refuses a redirect and keeps its original record',
    () => _withNetwork(() async {
      var refreshRequests = 0;
      var outsideRequests = 0;
      final server = await _server((request) async {
        if (request.uri.path == '/api/auth/refresh') {
          refreshRequests++;
          await request.drain<void>();
          await _redirect(request, '/independent/collect', status: 303);
        } else if (request.uri.path == '/api/protected') {
          await _json(request, {'code': 'UNAUTHORIZED'}, status: 401);
        } else {
          outsideRequests++;
          await _json(request, {'accessToken': 'unowned-access'});
        }
      });
      final fixture = await _fixture(server);
      final submitted = await fixture.storage.getAuthTokenSnapshot();

      await expectLater(
        fixture.dio.get<dynamic>('/protected'),
        throwsA(_status(303)),
      );

      expect(refreshRequests, 1);
      expect(outsideRequests, 0);
      expect(
        (await fixture.storage.getAuthTokenSnapshot()).isSameSession(submitted),
        isTrue,
      );
    }),
  );

  test(
    '401 replay cannot redirect its newly rotated bearer outside the API',
    () => _withNetwork(() async {
      var protectedRequests = 0;
      var refreshRequests = 0;
      var outsideRequests = 0;
      final server = await _server((request) async {
        if (request.uri.path == '/api/auth/refresh') {
          refreshRequests++;
          await request.drain<void>();
          await _json(request, {
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
          });
        } else if (request.uri.path == '/api/protected') {
          protectedRequests++;
          if (request.headers.value(HttpHeaders.authorizationHeader) ==
              'Bearer new-access') {
            await _redirect(request, '/independent/collect');
          } else {
            await _json(request, {'code': 'UNAUTHORIZED'}, status: 401);
          }
        } else {
          outsideRequests++;
          await _json(request, {'ok': true});
        }
      });
      final fixture = await _fixture(server);

      await expectLater(
        fixture.dio.get<dynamic>('/protected'),
        throwsA(_status(302)),
      );

      expect(protectedRequests, 2);
      expect(refreshRequests, 1);
      expect(outsideRequests, 0);
      expect(await fixture.storage.getAccessToken(), 'new-access');
      expect(await fixture.storage.getRefreshToken(), 'new-refresh');
    }),
  );

  test(
    'absolute HTTP target cannot bypass the configured endpoint with an explicit bearer',
    () => _withNetwork(() async {
      var requests = 0;
      final server = await _server((request) async {
        requests++;
        await _json(request, {'ok': true});
      });
      final fixture = await _fixture(server);

      await expectLater(
        fixture.dio.get<dynamic>(
          'http://localhost:${server.port}/api/protected',
          options: Options(headers: {'Authorization': 'Bearer owned-access'}),
        ),
        throwsA(_status(409)),
      );

      expect(requests, 0);
      expect(await fixture.storage.getAccessToken(), 'owned-access');
    }),
  );

  test(
    'an explicit bearer from a different session never reaches the transport',
    () => _withNetwork(() async {
      var requests = 0;
      final server = await _server((request) async {
        requests++;
        await _json(request, {'ok': true});
      });
      final fixture = await _fixture(server);

      await expectLater(
        fixture.dio.get<dynamic>(
          '/protected',
          options: Options(headers: {'Authorization': 'Bearer stale-access'}),
        ),
        throwsA(_status(409)),
      );
      expect(requests, 0);

      final response = await fixture.dio.get<dynamic>(
        '/protected',
        options: Options(headers: {'Authorization': 'Bearer owned-access'}),
      );
      expect(response.statusCode, 200);
      expect(requests, 1);
    }),
  );

  test(
    'repository refresh checks the actual ApiClient URL before dispatch',
    () => _withNetwork(() async {
      var requests = 0;
      final server = await _server((request) async {
        requests++;
        await _json(request, {'ok': true});
      });
      final fixture = await _fixture(server);
      final actual = Dio(buildApiBaseOptions('${fixture.baseUrl}-independent'));
      addTearDown(() => actual.close(force: true));
      final repo = DioAuthRepository(ApiClient(actual), fixture.storage);

      await expectLater(
        repo.refresh('owned-refresh'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );

      expect(requests, 0);
      expect(await fixture.storage.getRefreshToken(), 'owned-refresh');
    }),
  );

  test(
    '401 refresh factory cannot dispatch to a different actual API',
    () => _withNetwork(() async {
      var protectedRequests = 0;
      var unownedRefreshRequests = 0;
      final server = await _server((request) async {
        if (request.uri.path == '/api/protected') {
          protectedRequests++;
          await _json(request, {'code': 'UNAUTHORIZED'}, status: 401);
        } else {
          unownedRefreshRequests++;
          await _json(request, {'accessToken': 'unowned-access'});
        }
      });
      final fixture = await _fixture(server, differentRefreshTarget: true);

      await expectLater(
        fixture.dio.get<dynamic>('/protected'),
        throwsA(isA<DioException>()),
      );

      expect(protectedRequests, 1);
      expect(unownedRefreshRequests, 0);
      expect(await fixture.storage.getAccessToken(), 'owned-access');
      expect(await fixture.storage.getRefreshToken(), 'owned-refresh');
    }),
  );
}

Matcher _status(int expected) => isA<DioException>().having(
  (error) => error.response?.statusCode,
  'statusCode',
  expected,
);

Future<T> _withNetwork<T>(Future<T> Function() action) =>
    HttpOverrides.runWithHttpOverrides(action, _RealNetwork());

// Widget bindings otherwise replace HttpClient with a synthetic 400 client.
// These tests deliberately cross the actual Dio/HttpClient/HttpServer boundary.
class _RealNetwork extends HttpOverrides {}

Future<HttpServer> _server(Future<void> Function(HttpRequest) respond) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen(respond);
  return server;
}

Future<void> _json(HttpRequest request, Object body, {int status = 200}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<void> _redirect(
  HttpRequest request,
  String location, {
  int status = 302,
}) async {
  request.response.statusCode = status;
  request.response.headers.set(HttpHeaders.locationHeader, location);
  await request.response.close();
}

Future<({Dio dio, SecureStorage storage, String baseUrl})> _fixture(
  HttpServer server, {
  bool differentRefreshTarget = false,
}) async {
  final baseUrl = 'http://127.0.0.1:${server.port}/api';
  final storage = SecureStorage(const FlutterSecureStorage());
  await storage.saveTokens(
    accessToken: 'owned-access',
    refreshToken: 'owned-refresh',
    issuer: AuthBackendRealmPolicy().issuerFor(baseUrl),
  );
  final dio = Dio(buildApiBaseOptions(baseUrl));
  dio.interceptors.add(
    AuthInterceptor(
      storage: storage,
      baseUrl: baseUrl,
      dioFactory: () => Dio(
        buildApiBaseOptions(
          differentRefreshTarget ? '$baseUrl-independent' : baseUrl,
        ),
      ),
    ),
  );
  addTearDown(() => dio.close(force: true));
  return (dio: dio, storage: storage, baseUrl: baseUrl);
}
