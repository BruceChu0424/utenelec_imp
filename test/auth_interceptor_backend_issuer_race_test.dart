import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_base_url.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'support/fake_auth_logout_fence.dart';

const _compiledLan = String.fromEnvironment('API_BASE_URL');
const _compiledCloud = String.fromEnvironment('CLOUD_API_BASE_URL');
const _independent = 'https://independent-debug.example/api';
const _refreshA = 'issuer-A-private-refresh';
final _endpoint = StateProvider<String>((ref) => apiBaseUrl);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a new independent backend never receives the old access token',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.login();
      expect(
        await fixture.container.read(apiClientProvider).get('/protected'),
        {'ok': true},
      );
      expect(fixture.sent.last.authorization, 'Bearer ${fixture.access}');

      fixture.switchTo(_independent);
      await fixture.tryProtected();
      final independent = fixture.sent.where((r) => r.baseUrl == _independent);
      expect(
        independent.where(
          (r) => r.authorization?.contains(fixture.access) == true,
        ),
        isEmpty,
      );
      expect(independent.where((r) => r.refresh == _refreshA), isEmpty);
    },
  );

  test(
    'proactive refresh cannot send an old issuer refresh token to a clone',
    () async {
      final fixture = _Fixture(shortAccess: true);
      addTearDown(fixture.dispose);
      await fixture.login();
      expect(await fixture.storage.getRefreshToken(), _refreshA);

      fixture.switchTo(_independent);
      await fixture.tryProtected();
      expect(
        fixture.sent.where(
          (r) => r.baseUrl == _independent && r.refresh == _refreshA,
        ),
        isEmpty,
        reason:
            'Same user and dataset identifiers cannot make an independent endpoint the issuer',
      );
    },
  );

  test(
    'the explicitly compiled company LAN and cloud relay keep one valid session',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      expect(apiBaseUrl, _compiledLan);
      await fixture.login();
      fixture.switchTo(_compiledCloud);
      expect(
        await fixture.container.read(apiClientProvider).get('/protected'),
        {'ok': true},
      );
      final relay = fixture.sent.where((r) => r.baseUrl == _compiledCloud);
      expect(relay.single.authorization, 'Bearer ${fixture.access}');
      expect(fixture.sent.where((r) => r.path == '/auth/login'), hasLength(1));
    },
    skip: _compiledLan.isEmpty || _compiledCloud.isEmpty
        ? 'Run this file with API_BASE_URL and CLOUD_API_BASE_URL defines to verify the trusted relay pair'
        : false,
  );
}

class _Fixture {
  _Fixture({bool shortAccess = false}) : access = _jwt(shortAccess ? 30 : 900) {
    FlutterSecureStorage.setMockInitialValues({});
    storage = SecureStorage(const FlutterSecureStorage());
    final recovery = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const [Duration(hours: 1)],
    );
    container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
        connectionRecoveryProvider.overrideWith((ref) => recovery),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_endpoint)),
        apiClientProvider.overrideWith((ref) {
          final baseUrl = ref.watch(apiBaseUrlProvider);
          Dio transport() {
            final dio = Dio(buildApiBaseOptions(baseUrl));
            dio.httpClientAdapter = _Adapter(_respond);
            return dio;
          }

          final dio = transport();
          dio.interceptors.add(
            AuthInterceptor(
              storage: storage,
              baseUrl: baseUrl,
              dioFactory: transport,
            ),
          );
          ref.onDispose(() => dio.close(force: true));
          return ApiClient(dio);
        }),
        // Use the real network exchange and SessionNotifier commit path. Durable
        // logout retries have their own issuer tests; they are not mocked here.
        authRepositoryProvider.overrideWith(
          (ref) => DioAuthRepository(ref.watch(apiClientProvider), storage),
        ),
      ],
    );
  }

  final String access;
  late final SecureStorage storage;
  late final ProviderContainer container;
  final sent =
      <
        ({String baseUrl, String path, String? authorization, Object? refresh})
      >[];

  Future<void> login() async {
    final session = container.read(sessionProvider.notifier);
    await pumpEventQueue();
    await session.login(account: 'same-user', password: 'test-only-password');
    expect(container.read(sessionProvider).isLoggedIn, isTrue);
    expect(await storage.getAccessToken(), access);
  }

  void switchTo(String baseUrl) {
    container.read(_endpoint.notifier).state = baseUrl;
  }

  Future<void> tryProtected() async {
    try {
      await container.read(apiClientProvider).get('/protected');
    } on Object {
      // Rejecting before transport is an acceptable fail-closed outcome. The
      // assertion concerns credentials reaching the other actual Dio adapter.
    }
    await pumpEventQueue();
  }

  ResponseBody _respond(RequestOptions request) {
    final data = request.data;
    sent.add((
      baseUrl: request.baseUrl,
      path: request.path,
      authorization: request.headers['Authorization'] as String?,
      refresh: data is Map ? data['refreshToken'] : null,
    ));
    final Object body;
    if (request.path == '/auth/login') {
      body = {
        'accessToken': access,
        'refreshToken': _refreshA,
        'expiresIn': 900,
        'mustChangePassword': false,
        'user': {
          'id': 'same-user',
          'employeeId': 'same-employee',
          'loginAccount': 'same-user',
          'permissions': ['dashboard:view'],
          'superAdmin': false,
          'businessDatasetId': '33333333-3333-4333-8333-333333333333',
          'businessResetGeneration': 7,
        },
      };
    } else if (request.path == '/auth/refresh') {
      return _json(401, {'code': 'UNAUTHORIZED'});
    } else {
      body = {'ok': true};
    }
    return _json(200, body);
  }

  void dispose() => container.dispose();
}

String _jwt(int lifetime) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'sub': 'same-user', 'iat': 1000, 'exp': 1000 + lifetime})}.test-signature';
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) {}
}
