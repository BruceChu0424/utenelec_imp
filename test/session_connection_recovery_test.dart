import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'support/fake_auth_logout_fence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'startup session restores automatically after connectivity returns',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'offline-access',
        refreshToken: 'valid-refresh',
      );
      final repository = _RecoveringAuthRepository();
      final recovery = ConnectionRecoveryController(
        probe: () async => true,
        probeDelays: const <Duration>[Duration(hours: 1)],
        restoredDisplayDuration: const Duration(hours: 1),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          secureStorageProvider.overrideWithValue(storage),
          authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
          authRepositoryProvider.overrideWithValue(repository),
          connectionRecoveryProvider.overrideWith((ref) => recovery),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      await pumpEventQueue();

      expect(repository.meCalls, 1);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      expect(await storage.getRefreshToken(), 'valid-refresh');

      recovery.markDisconnected();
      await recovery.retryNow();
      await pumpEventQueue();

      expect(repository.meCalls, 2);
      expect(container.read(sessionProvider).status, AuthStatus.authenticated);
      expect(container.read(sessionProvider).user?.name, '恢复用户');
    },
  );

  test('delayed expiration event cannot sign out a newer login', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final storage = _DelayedSnapshotStorage();
    final repository = _LoginAuthRepository();
    final recovery = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const <Duration>[Duration(hours: 1)],
    );
    final container = ProviderContainer(
      overrides: <Override>[
        secureStorageProvider.overrideWithValue(storage),
        authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
        authRepositoryProvider.overrideWithValue(repository),
        connectionRecoveryProvider.overrideWith((ref) => recovery),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(sessionProvider.notifier);
    await pumpEventQueue();

    storage.delayNextSnapshot();
    SessionEventBus.instance.expire();
    await storage.delayedReadStarted.future;

    await notifier.login(account: 'admin', password: 'secret');
    storage.releaseDelayedRead();
    await pumpEventQueue();

    expect(container.read(sessionProvider).status, AuthStatus.authenticated);
    expect(container.read(sessionProvider).user?.name, '新登录用户');
    expect(await storage.getAccessToken(), 'new-access');
    expect(await storage.getRefreshToken(), 'new-refresh');
  });

  test(
    'startup restores a forced-password session to the change-password flow',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'forced-access',
        refreshToken: 'forced-refresh',
      );
      final container = ProviderContainer(
        overrides: <Override>[
          secureStorageProvider.overrideWithValue(storage),
          authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
          authRepositoryProvider.overrideWithValue(
            const _FixedProfileAuthRepository(_forcedPasswordProfile),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Riverpod providers are lazy; the first read starts the asynchronous restore.
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      await pumpEventQueue();

      expect(
        container.read(sessionProvider).status,
        AuthStatus.mustChangePassword,
      );
      expect(container.read(sessionProvider).user?.name, '待改密用户');
    },
  );
}

const _restoredProfile = UserProfile(
  id: 'user-1',
  loginAccount: 'admin',
  name: '恢复用户',
  roles: <String>['admin'],
  permissions: <String>['dashboard:view'],
  superAdmin: true,
);

const _loginProfile = UserProfile(
  id: 'user-2',
  loginAccount: 'admin',
  name: '新登录用户',
  roles: <String>['admin'],
  permissions: <String>['dashboard:view'],
  superAdmin: true,
);

const _forcedPasswordProfile = UserProfile(
  id: 'user-3',
  loginAccount: '13800000000',
  name: '待改密用户',
  roles: <String>['employee'],
  permissions: <String>['CHANGE_PASSWORD'],
  superAdmin: false,
  mustChangePassword: true,
);

class _FixedProfileAuthRepository implements AuthRepository {
  const _FixedProfileAuthRepository(this.profile);

  final UserProfile profile;

  @override
  Future<UserProfile> me() async => profile;

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<AuthResult> login(String loginAccount, String password) =>
      throw UnimplementedError();

  @override
  Future<void> logout(String? refreshToken) => throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _RecoveringAuthRepository implements AuthRepository {
  var meCalls = 0;

  @override
  Future<UserProfile> me() async {
    meCalls++;
    if (meCalls == 1) throw NetworkException('模拟启动断网');
    return _restoredProfile;
  }

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<AuthResult> login(String loginAccount, String password) =>
      throw UnimplementedError();

  @override
  Future<void> logout(String? refreshToken) => throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _LoginAuthRepository implements AuthRepository {
  @override
  Future<AuthResult> login(String loginAccount, String password) async {
    const result = AuthResult(
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      expiresIn: 900,
      mustChangePassword: false,
      user: _loginProfile,
    );
    return result;
  }

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<UserProfile> me() => throw UnimplementedError();

  @override
  Future<void> logout(String? refreshToken) async {}

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _DelayedSnapshotStorage extends SecureStorage {
  _DelayedSnapshotStorage() : super(const FlutterSecureStorage());

  Completer<void> delayedReadStarted = Completer<void>();
  Completer<void> _release = Completer<void>();
  var _delayNext = false;

  void delayNextSnapshot() {
    delayedReadStarted = Completer<void>();
    _release = Completer<void>();
    _delayNext = true;
  }

  void releaseDelayedRead() => _release.complete();

  @override
  Future<AuthTokenSnapshot> getAuthTokenSnapshot() async {
    if (!_delayNext) return super.getAuthTokenSnapshot();
    _delayNext = false;
    delayedReadStarted.complete();
    await _release.future;
    return const AuthTokenSnapshot.empty();
  }
}
