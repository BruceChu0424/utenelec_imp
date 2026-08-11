import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/features/auth/services/pending_refresh_revocation_drainer.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'explicit offline logout clears local session and queues refresh',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'current-access',
        refreshToken: 'current-refresh',
      );
      final transport = _OfflineTransport();
      final container = _container(
        preferences: preferences,
        storage: storage,
        networkRepository: _ProfileAuthRepository(),
        transport: transport.call,
      );
      addTearDown(container.dispose);

      container.read(sessionProvider);
      await _waitUntil(
        () =>
            container.read(sessionProvider).status == AuthStatus.authenticated,
      );
      await container.read(sessionProvider.notifier).logout();
      await _waitUntil(() => transport.calls == 1);

      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(
        await PendingRefreshRevocationStore(storage).pendingTokens(),
        <String>['current-refresh'],
      );
    },
  );

  test(
    'late superseded login result is durably queued for revocation',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final storage = SecureStorage(const FlutterSecureStorage());
      final transport = _OfflineTransport();
      final networkRepository = _OverlappingLoginAuthRepository();
      final container = _container(
        preferences: preferences,
        storage: storage,
        networkRepository: networkRepository,
        transport: transport.call,
      );
      addTearDown(container.dispose);
      final notifier = container.read(sessionProvider.notifier);
      await pumpEventQueue();

      final first = notifier.login(account: 'first', password: 'secret');
      await networkRepository.firstStarted.future;
      final second = notifier.login(account: 'second', password: 'secret');
      await second;
      networkRepository.releaseFirst();
      await first;
      await _waitUntil(() => transport.calls == 1);

      expect(await storage.getAccessToken(), 'second-access');
      expect(await storage.getRefreshToken(), 'second-refresh');
      expect(container.read(sessionProvider).user?.code, 'second');
      expect(
        await PendingRefreshRevocationStore(storage).pendingTokens(),
        <String>['first-refresh'],
      );
    },
  );
}

ProviderContainer _container({
  required SharedPreferences preferences,
  required SecureStorage storage,
  required AuthRepository networkRepository,
  required RefreshTokenRevoker transport,
}) {
  final recovery = ConnectionRecoveryController(
    probe: () async => false,
    probeDelays: const <Duration>[Duration(hours: 1)],
    probeDelayJitter: (delay) => delay,
  );
  return ProviderContainer(
    overrides: <Override>[
      sharedPreferencesProvider.overrideWithValue(preferences),
      secureStorageProvider.overrideWithValue(storage),
      authNetworkRepositoryProvider.overrideWithValue(networkRepository),
      pendingRefreshLogoutTransportProvider.overrideWithValue(transport),
      connectionRecoveryProvider.overrideWith((ref) => recovery),
    ],
  );
}

Future<void> _waitUntil(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _profile = UserProfile(
  id: 'user-id',
  loginAccount: 'admin',
  name: '管理员',
  roles: <String>['admin'],
  permissions: <String>['dashboard:view'],
  superAdmin: true,
);

class _OfflineTransport {
  var calls = 0;

  Future<void> call(String token) async {
    calls++;
    throw StateError('offline');
  }
}

class _ProfileAuthRepository implements AuthRepository {
  @override
  Future<UserProfile> me() async => _profile;

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<AuthResult> login(String loginAccount, String password) =>
      throw UnimplementedError();

  @override
  Future<void> logout(String? refreshToken) async {}

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _OverlappingLoginAuthRepository implements AuthRepository {
  final firstStarted = Completer<void>();
  final _releaseFirst = Completer<void>();
  var loginCalls = 0;

  void releaseFirst() => _releaseFirst.complete();

  @override
  Future<AuthResult> login(String loginAccount, String password) async {
    final call = ++loginCalls;
    if (call == 1) {
      firstStarted.complete();
      await _releaseFirst.future;
    }
    return AuthResult(
      accessToken: call == 1 ? 'first-access' : 'second-access',
      refreshToken: call == 1 ? 'first-refresh' : 'second-refresh',
      expiresIn: 900,
      mustChangePassword: false,
      user: UserProfile(
        id: call == 1 ? 'first-id' : 'second-id',
        loginAccount: loginAccount,
        name: call == 1 ? '第一用户' : '第二用户',
        roles: const <String>['admin'],
        permissions: const <String>['dashboard:view'],
        superAdmin: true,
      ),
    );
  }

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<void> logout(String? refreshToken) async {}

  @override
  Future<UserProfile> me() => throw StateError('no active startup session');

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}
