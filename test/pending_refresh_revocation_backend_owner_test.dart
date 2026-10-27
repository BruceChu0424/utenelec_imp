import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/features/auth/services/pending_refresh_revocation_drainer.dart';

const _a = 'https://revocation-a.invalid/api';
const _b = 'https://revocation-b.invalid/api';
final _backend = StateProvider<String>((ref) => _a);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test(
    'an offline A revocation cannot be drained to an independent B',
    () async {
      final storage = SecureStorage(const FlutterSecureStorage());
      final sent = <_Sent>[];
      var aOnline = false;
      final container = _container(storage, sent, () => aOnline);
      addTearDown(container.dispose);
      final original = container.read(authRepositoryProvider);
      await original.logout('a-private-refresh');
      final drainer = container.read(pendingRefreshRevocationDrainerProvider);
      await drainer.drain();
      expect(sent.where((r) => r.endpoint == _a), isNotEmpty);

      container.read(_backend.notifier).state = _b;
      await drainer.drain();
      expect(
        sent.where((r) => r.endpoint == _b && r.token == 'a-private-refresh'),
        isEmpty,
      );
      expect(
        await PendingRefreshRevocationStore(storage).pendingTokens(),
        contains('a-private-refresh'),
      );

      aOnline = true;
      container.read(_backend.notifier).state = _a;
      await drainer.drain();
      expect(
        await PendingRefreshRevocationStore(storage).pendingTokens(),
        isEmpty,
      );
    },
  );

  test(
    'a genuinely old queue without issuer never assumes the current debug endpoint',
    () async {
      final storage = SecureStorage(const FlutterSecureStorage());
      final now = DateTime.now();
      await storage.write(
        'auth.pending_refresh_revocations.v1',
        jsonEncode(<String, Object>{
          'version': 1,
          'entries': <Map<String, Object>>[
            <String, Object>{
              'refreshToken': 'legacy-private-refresh',
              'createdAt': now.millisecondsSinceEpoch,
              'expiresAt': now
                  .add(const Duration(days: 1))
                  .millisecondsSinceEpoch,
            },
          ],
        }),
      );
      final sent = <_Sent>[];
      final container = _container(storage, sent, () => true);
      addTearDown(container.dispose);
      container.read(_backend.notifier).state = _b;
      await container.read(pendingRefreshRevocationDrainerProvider).drain();
      expect(sent, isEmpty);
      expect(
        await PendingRefreshRevocationStore(storage).pendingTokens(),
        contains('legacy-private-refresh'),
      );
    },
  );
}

ProviderContainer _container(
  SecureStorage storage,
  List<_Sent> sent,
  bool Function() aOnline,
) => ProviderContainer(
  overrides: <Override>[
    secureStorageProvider.overrideWithValue(storage),
    apiBaseUrlProvider.overrideWith((ref) => ref.watch(_backend)),
    authNetworkRepositoryProvider.overrideWithValue(_UnusedNetwork()),
    connectionRecoveryProvider.overrideWith(
      (ref) => ConnectionRecoveryController(
        probe: () async => false,
        probeDelays: const <Duration>[Duration(hours: 1)],
      ),
    ),
    apiClientProvider.overrideWith((ref) {
      final endpoint = ref.watch(apiBaseUrlProvider);
      final dio = Dio(BaseOptions(baseUrl: endpoint));
      dio.httpClientAdapter = _Adapter((options) {
        final data = options.data;
        sent.add(
          _Sent(
            options.baseUrl,
            data is Map ? data['refreshToken'] as String? : null,
          ),
        );
        if (options.baseUrl == _a && !aOnline()) {
          throw DioException.connectionError(
            requestOptions: options,
            reason: 'fixture offline',
          );
        }
        return ResponseBody.fromString(
          '{}',
          200,
          headers: <String, List<String>>{
            'content-type': <String>['application/json'],
          },
        );
      });
      return ApiClient(dio);
    }),
  ],
);

class _Sent {
  const _Sent(this.endpoint, this.token);
  final String endpoint;
  final String? token;
}

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

class _UnusedNetwork implements AuthRepository {
  @override
  Future<void> logout(String? token) async {}
  @override
  Future<AuthResult> login(String account, String password) =>
      throw UnimplementedError();
  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();
  @override
  Future<AuthResult> refresh(String token) => throw UnimplementedError();
  @override
  Future<UserProfile> me() => throw UnimplementedError();
}
