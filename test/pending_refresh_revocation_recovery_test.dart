import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/features/auth/services/pending_refresh_revocation_drainer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
    'offline logout survives app container rebuild and drains on recovery',
    () async {
      const rawStorage = FlutterSecureStorage();
      final storage = SecureStorage(rawStorage);
      final transport = _RecoveringLogoutTransport();

      final firstRecovery = ConnectionRecoveryController(
        probe: () async => false,
        probeDelays: const <Duration>[Duration(hours: 1)],
        probeDelayJitter: (delay) => delay,
      );
      final firstContainer = _container(
        storage: storage,
        transport: transport.call,
        recovery: firstRecovery,
      );
      final firstRepository = firstContainer.read(authRepositoryProvider);

      await firstRepository.logout('offline-refresh');
      await _waitUntil(() => transport.calls == 1);
      expect(
        await PendingRefreshRevocationStore(storage).pendingTokens(),
        <String>['offline-refresh'],
      );
      firstContainer.dispose();

      final secondRecovery = ConnectionRecoveryController(
        probe: () async => true,
        probeDelays: const <Duration>[Duration(hours: 1)],
        probeDelayJitter: (delay) => delay,
        restoredDisplayDuration: const Duration(hours: 1),
      );
      final secondContainer = _container(
        storage: storage,
        transport: transport.call,
        recovery: secondRecovery,
      );
      addTearDown(secondContainer.dispose);

      // The app root watches this provider even though no session token exists.
      secondContainer.read(pendingRefreshRevocationDrainerProvider);
      await _waitUntil(() => transport.calls == 2);
      expect(
        await PendingRefreshRevocationStore(storage).pendingTokens(),
        <String>['offline-refresh'],
      );

      transport.online = true;
      secondRecovery.markDisconnected();
      await secondRecovery.retryNow();
      await _waitUntil(
        () async => (await PendingRefreshRevocationStore(
          storage,
        ).pendingTokens()).isEmpty,
      );

      expect(transport.calls, 3);
      expect(transport.tokens, everyElement('offline-refresh'));
    },
  );

  test('queued logout network wait never blocks a following login', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    final transportStarted = Completer<void>();
    final releaseTransport = Completer<void>();
    final recovery = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const <Duration>[Duration(hours: 1)],
    );
    final container = ProviderContainer(
      overrides: <Override>[
        secureStorageProvider.overrideWithValue(storage),
        authNetworkRepositoryProvider.overrideWithValue(_FastAuthRepository()),
        pendingRefreshLogoutTransportProvider.overrideWithValue((token) async {
          transportStarted.complete();
          await releaseTransport.future;
        }),
        connectionRecoveryProvider.overrideWith((ref) => recovery),
      ],
    );
    addTearDown(container.dispose);
    final repository = container.read(authRepositoryProvider);

    await repository.logout('pending-refresh');
    await transportStarted.future;
    final login = await repository.login('new-user', 'secret');

    expect(login.accessToken, 'new-access');
    expect(login.user.loginAccount, 'new-user');
    expect(
      await PendingRefreshRevocationStore(storage).pendingTokens(),
      <String>['pending-refresh'],
    );

    releaseTransport.complete();
    await _waitUntil(
      () async => (await PendingRefreshRevocationStore(
        storage,
      ).pendingTokens()).isEmpty,
    );
  });
}

ProviderContainer _container({
  required SecureStorage storage,
  required RefreshTokenRevoker transport,
  required ConnectionRecoveryController recovery,
}) => ProviderContainer(
  overrides: <Override>[
    secureStorageProvider.overrideWithValue(storage),
    authNetworkRepositoryProvider.overrideWithValue(_FastAuthRepository()),
    pendingRefreshLogoutTransportProvider.overrideWithValue(transport),
    connectionRecoveryProvider.overrideWith((ref) => recovery),
  ],
);

Future<void> _waitUntil(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _RecoveringLogoutTransport {
  var online = false;
  var calls = 0;
  final tokens = <String>[];

  Future<void> call(String token) async {
    calls++;
    tokens.add(token);
    if (!online) throw StateError('offline');
  }
}

class _FastAuthRepository implements AuthRepository {
  @override
  Future<AuthResult> login(String loginAccount, String password) async =>
      AuthResult(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        expiresIn: 900,
        mustChangePassword: false,
        user: UserProfile(
          id: 'new-user-id',
          loginAccount: loginAccount,
          name: '新用户',
          roles: const <String>['admin'],
          permissions: const <String>['dashboard:view'],
          superAdmin: true,
        ),
      );

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<void> logout(String? refreshToken) async {}

  @override
  Future<UserProfile> me() => throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}
