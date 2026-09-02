import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/features/auth/services/pending_refresh_revocation_drainer.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'support/fake_auth_logout_fence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('durable fence survives recreation and recovery never restores uncleared tokens', () async {
    const rawStorage = FlutterSecureStorage();
    final normal = SecureStorage(rawStorage);
    await normal.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    );
    final failing = _FailingLogoutStorage(rawStorage);
    final repository = _RecordingAuthRepository();
    final durableFence = FakeAuthLogoutFence();
    final firstRecovery = _recovery();
    final first = _container(
      storage: failing,
      repository: repository,
      fence: durableFence,
      recovery: firstRecovery,
    );

    final notifier = first.read(sessionProvider.notifier);
    await pumpEventQueue();
    expect(repository.meCalls, 1);
    await expectLater(notifier.logout(), throwsA(isA<StateError>()));
    expect(failing.clearAttempts, 3);
    expect(durableFence.active, isTrue);
    expect(await normal.getAccessToken(), 'old-access');
    first.dispose();
    await pumpEventQueue();

    final recreatedFence = FakeAuthLogoutFence(active: durableFence.active);
    final secondRecovery = _recovery();
    final second = _container(
      storage: normal,
      repository: repository,
      fence: recreatedFence,
      recovery: secondRecovery,
    );
    addTearDown(second.dispose);

    expect(second.read(sessionProvider).status, AuthStatus.unauthenticated);
    await pumpEventQueue();
    expect(repository.meCalls, 1);
    secondRecovery.markDisconnected();
    await secondRecovery.retryNow();
    await pumpEventQueue();

    expect(repository.meCalls, 1);
    expect(second.read(sessionProvider).status, AuthStatus.unauthenticated);
    expect(await normal.getRefreshToken(), 'old-refresh');
  });

  test('failed revocation handoff preserves tokens behind the active fence for retry', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    );
    final repository = _FailingLogoutAuthRepository();
    final fence = FakeAuthLogoutFence();
    final container = _container(
      storage: storage,
      repository: repository,
      fence: fence,
      recovery: _recovery(),
    );
    addTearDown(container.dispose);
    final notifier = container.read(sessionProvider.notifier);
    await pumpEventQueue();

    await expectLater(notifier.logout(), throwsA(isA<StateError>()));

    expect(repository.logoutCalls, 3);
    expect(fence.active, isTrue);
    expect(await storage.getAccessToken(), 'old-access');
    expect(await storage.getRefreshToken(), 'old-refresh');
    expect(container.read(sessionProvider).status, AuthStatus.unauthenticated);
  });

  test('session logout returns only after durable queueing but never waits for the network', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    );
    final queue = PendingRefreshRevocationStore(storage);
    final networkStarted = Completer<void>();
    final releaseNetwork = Completer<void>();
    final drainer = PendingRefreshRevocationDrainer(
      store: queue,
      revoke: (token) async {
        if (!networkStarted.isCompleted) networkStarted.complete();
        await releaseNetwork.future;
      },
      retryDelays: const <Duration>[Duration(hours: 1)],
    );
    addTearDown(drainer.dispose);
    final repository = DurableLogoutAuthRepository(
      _RecordingAuthRepository(),
      drainer,
    );
    final container = _container(
      storage: storage,
      repository: repository,
      fence: FakeAuthLogoutFence(),
      recovery: _recovery(),
    );
    addTearDown(container.dispose);
    final notifier = container.read(sessionProvider.notifier);
    await pumpEventQueue();

    await notifier.logout().timeout(const Duration(seconds: 1));
    await networkStarted.future;

    expect(await queue.pendingTokens(), <String>['old-refresh']);
    expect(await storage.getRefreshToken(), isNull);
    expect(container.read(sessionProvider).status, AuthStatus.unauthenticated);

    releaseNetwork.complete();
    await pumpEventQueue();
    expect(await queue.pendingTokens(), isEmpty);
  });

  test(
    'fence activation failure is tolerated when secure token clearing succeeds',
    () async {
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      final fence = FakeAuthLogoutFence(
        activateError: StateError('preferences unavailable'),
      );
      final repository = _RecordingAuthRepository();
      final container = _container(
        storage: storage,
        repository: repository,
        fence: fence,
        recovery: _recovery(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(sessionProvider.notifier);
      await pumpEventQueue();

      await notifier.logout();
      await pumpEventQueue();

      expect(fence.activateCalls, 1);
      expect(fence.clearCalls, 1);
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      expect(repository.revokedRefreshTokens, <String?>['old-refresh']);
    },
  );

  test(
    'fence clear failure is surfaced after tokens are safely deleted',
    () async {
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      final fence = FakeAuthLogoutFence(
        clearError: StateError('preferences clear failed'),
      );
      final container = _container(
        storage: storage,
        repository: _RecordingAuthRepository(),
        fence: fence,
        recovery: _recovery(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(sessionProvider.notifier);
      await pumpEventQueue();

      await expectLater(notifier.logout(), throwsA(isA<StateError>()));

      expect(fence.active, isTrue);
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
    },
  );

  test('explicit login safely supersedes an active logout fence', () async {
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
    );
    final fence = FakeAuthLogoutFence(active: true);
    final repository = _RecordingAuthRepository();
    final container = _container(
      storage: storage,
      repository: repository,
      fence: fence,
      recovery: _recovery(),
    );
    addTearDown(container.dispose);
    final notifier = container.read(sessionProvider.notifier);
    await pumpEventQueue();
    expect(repository.meCalls, 0);

    await notifier.login(account: 'admin', password: 'secret');

    expect(fence.active, isFalse);
    expect(await storage.getAccessToken(), 'new-access');
    expect(await storage.getRefreshToken(), 'new-refresh');
    expect(container.read(sessionProvider).status, AuthStatus.authenticated);
  });

  test('shared-preferences fence treats malformed data as active and clears idempotently', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SharedPreferencesAuthLogoutFence.storageKey: 'malformed',
    });
    final preferences = await SharedPreferences.getInstance();
    final fence = SharedPreferencesAuthLogoutFence(preferences);

    expect(await fence.isActive(), isTrue);
    await fence.clear();
    expect(await fence.isActive(), isFalse);
    await fence.clear();
    await fence.activate();
    expect(await fence.isActive(), isTrue);
  });
}

ConnectionRecoveryController _recovery() => ConnectionRecoveryController(
  probe: () async => true,
  probeDelays: const <Duration>[Duration(hours: 1)],
);

ProviderContainer _container({
  required SecureStorage storage,
  required AuthRepository repository,
  required AuthLogoutFence fence,
  required ConnectionRecoveryController recovery,
}) => ProviderContainer(
  overrides: <Override>[
    secureStorageProvider.overrideWithValue(storage),
    authRepositoryProvider.overrideWithValue(repository),
    authLogoutFenceProvider.overrideWithValue(fence),
    connectionRecoveryProvider.overrideWith((ref) => recovery),
  ],
);

const _profile = UserProfile(
  id: 'user-1',
  loginAccount: 'admin',
  name: '管理员',
  roles: <String>['admin'],
  permissions: <String>['dashboard:view'],
  superAdmin: true,
);

class _RecordingAuthRepository implements AuthRepository {
  int meCalls = 0;
  final List<String?> revokedRefreshTokens = <String?>[];

  @override
  Future<UserProfile> me() async {
    meCalls++;
    return _profile;
  }

  @override
  Future<AuthResult> login(String loginAccount, String password) async =>
      const AuthResult(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        expiresIn: 900,
        mustChangePassword: false,
        user: _profile,
      );

  @override
  Future<void> logout(String? refreshToken) async {
    revokedRefreshTokens.add(refreshToken);
  }

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _FailingLogoutAuthRepository extends _RecordingAuthRepository {
  int logoutCalls = 0;

  @override
  Future<void> logout(String? refreshToken) async {
    logoutCalls++;
    throw StateError('revocation queue unavailable');
  }
}

class _FailingLogoutStorage extends SecureStorage {
  _FailingLogoutStorage(super.storage);

  int clearAttempts = 0;

  @override
  Future<AuthTokenClearResult> clearForLogoutIntent({
    Future<void> Function(AuthTokenSnapshot previous)? beforeClear,
  }) async {
    clearAttempts++;
    throw StateError('secure token clear failed');
  }
}
