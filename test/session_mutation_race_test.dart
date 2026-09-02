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

  test('two overlapping logins commit only the latest user intent', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final storage = SecureStorage(const FlutterSecureStorage());
    final repository = _QueuedLoginRepository(blockFirstLogin: true);
    final container = _container(storage, repository);
    addTearDown(container.dispose);

    final notifier = container.read(sessionProvider.notifier);
    await pumpEventQueue();
    final first = notifier.login(account: 'first', password: 'secret');
    await repository.firstLoginStarted.future;
    final second = notifier.login(account: 'second', password: 'secret');
    await repository.secondLoginStarted.future;

    // The latest request completes while the older network request is still
    // blocked. Only the short token/state commit is serialized.
    await second;
    expect(await storage.getAccessToken(), 'second-access');

    repository.releaseFirstLogin();
    await first;

    expect(repository.loginCalls, 2);
    expect(await storage.getAccessToken(), 'second-access');
    expect(await storage.getRefreshToken(), 'second-refresh');
    expect(container.read(sessionProvider).user?.name, '第二次登录');
  });

  test(
    'logout followed immediately by login never revokes new tokens',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      final repository = _QueuedLoginRepository();
      final container = _container(storage, repository);
      addTearDown(container.dispose);

      final notifier = container.read(sessionProvider.notifier);
      await pumpEventQueue();
      await notifier.login(account: 'first', password: 'secret');

      final logout = notifier.logout();
      final login = notifier.login(account: 'second', password: 'secret');
      await Future.wait(<Future<void>>[logout, login]);
      await pumpEventQueue();

      expect(repository.revokedAccessTokens, <String?>[null]);
      expect(repository.revokedRefreshTokens, <String?>['first-refresh']);
      expect(await storage.getAccessToken(), 'second-access');
      expect(await storage.getRefreshToken(), 'second-refresh');
      expect(container.read(sessionProvider).status, AuthStatus.authenticated);
      expect(container.read(sessionProvider).user?.name, '第二次登录');
    },
  );

  test(
    'blocked password change cannot delay explicit logout token clearing',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'current-access',
        refreshToken: 'current-refresh',
      );
      final repository = _BlockingChangePasswordRepository();
      final container = _container(storage, repository);
      addTearDown(container.dispose);

      final notifier = container.read(sessionProvider.notifier);
      await pumpEventQueue();
      final passwordChange = notifier.changePassword(
        oldPassword: 'old-secret',
        newPassword: 'new-secret',
      );
      await repository.changePasswordStarted.future;

      // Logout must clear persisted credentials without waiting for the
      // unrelated in-flight network response.
      await notifier.logout();
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );

      repository.releasePasswordChange();
      await passwordChange;
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
    },
  );

  test(
    'logout captures and clears tokens rotated immediately before atomic clear',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = _RotateBeforeAtomicClearStorage(
        const FlutterSecureStorage(),
      );
      await storage.saveTokens(
        accessToken: 'initial-access',
        refreshToken: 'initial-refresh',
      );
      final repository = _QueuedLoginRepository();
      final container = _container(storage, repository);
      addTearDown(container.dispose);

      final notifier = container.read(sessionProvider.notifier);
      await pumpEventQueue();
      await notifier.logout();
      await pumpEventQueue();

      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(repository.revokedAccessTokens, <String?>[null]);
      expect(repository.revokedRefreshTokens, <String?>['rotated-refresh']);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
    },
  );

  test(
    'late restore success cannot revive a cleared token generation',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'expired-access',
        refreshToken: 'rejected-refresh',
      );
      final repository = _ControlledRestoreRepository();
      final container = _container(storage, repository);
      addTearDown(container.dispose);

      container.read(sessionProvider);
      await repository.firstMeStarted.future;
      final rejected = await storage.getAuthTokenSnapshot();
      expect(await storage.clearTokensIfUnchanged(rejected), isTrue);
      SessionEventBus.instance.expire();
      repository.completeFirst(_profile('late', '迟到恢复'));
      await pumpEventQueue();

      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
    },
  );

  test(
    'recovery signal received during restore schedules a second restore',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'offline-access',
        refreshToken: 'valid-refresh',
      );
      final repository = _ControlledRestoreRepository(
        subsequentProfile: _profile('restored', '恢复成功'),
      );
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

      container.read(sessionProvider);
      await repository.firstMeStarted.future;
      recovery.markDisconnected();
      await recovery.retryNow();
      repository.failFirst(NetworkException('原恢复请求仍处于断网状态'));
      await pumpEventQueue();

      expect(repository.meCalls, 2);
      expect(container.read(sessionProvider).status, AuthStatus.authenticated);
      expect(container.read(sessionProvider).user?.name, '恢复成功');
    },
  );

  test(
    'external logout invalidates this tab and a later external login restores it',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      const rawStorage = FlutterSecureStorage();
      final localStorage = SecureStorage(rawStorage);
      final otherTabStorage = SecureStorage(rawStorage);
      await localStorage.saveTokens(
        accessToken: 'first-access',
        refreshToken: 'first-refresh',
      );
      final repository = _MutableProfileRepository(
        _profile('first', 'First user'),
      );
      final container = _container(localStorage, repository);
      addTearDown(container.dispose);

      container.read(sessionProvider);
      await pumpEventQueue();
      expect(container.read(sessionProvider).status, AuthStatus.authenticated);

      await otherTabStorage.clearForLogoutIntent();
      await pumpEventQueue();
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );

      repository.profile = _profile('second', 'Second user');
      final login = await otherTabStorage.beginSessionIntent(clearTokens: true);
      await otherTabStorage.commitSessionIntentTokens(
        intent: login.intent,
        accessToken: 'second-access',
        refreshToken: 'second-refresh',
      );
      await pumpEventQueue();

      expect(container.read(sessionProvider).status, AuthStatus.authenticated);
      expect(container.read(sessionProvider).user?.name, 'Second user');
    },
  );

  test(
    'final logout storage failure is surfaced and blocks automatic restore',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = _FailingLogoutStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      final repository = _MutableProfileRepository(_profile('old', 'Old user'));
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
      expect(repository.meCalls, 1);

      await expectLater(notifier.logout(), throwsA(isA<StateError>()));
      expect(storage.clearAttempts, 3);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
      expect(await storage.getAccessToken(), 'old-access');

      recovery.markDisconnected();
      await recovery.retryNow();
      await pumpEventQueue();
      expect(repository.meCalls, 1);
      expect(
        container.read(sessionProvider).status,
        AuthStatus.unauthenticated,
      );
    },
  );

  test('remember-account write cannot hold the token commit queue', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final storage = _BlockingLoginAccountStorage(const FlutterSecureStorage());
    final repository = _QueuedLoginRepository();
    final container = _container(storage, repository);
    addTearDown(container.dispose);

    final notifier = container.read(sessionProvider.notifier);
    await pumpEventQueue();
    await notifier.login(account: 'first', password: 'secret');
    await storage.accountWriteStarted.future;

    await notifier.logout();
    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getRefreshToken(), isNull);
    expect(container.read(sessionProvider).status, AuthStatus.unauthenticated);
    storage.releaseAccountWrite();
  });
}

ProviderContainer _container(SecureStorage storage, AuthRepository repository) {
  final recovery = ConnectionRecoveryController(
    probe: () async => true,
    probeDelays: const <Duration>[Duration(hours: 1)],
  );
  return ProviderContainer(
    overrides: <Override>[
      secureStorageProvider.overrideWithValue(storage),
      authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
      authRepositoryProvider.overrideWithValue(repository),
      connectionRecoveryProvider.overrideWith((ref) => recovery),
    ],
  );
}

UserProfile _profile(String id, String name) => UserProfile(
  id: id,
  loginAccount: id,
  name: name,
  roles: const <String>['admin'],
  permissions: const <String>['dashboard:view'],
  superAdmin: true,
);

AuthResult _result(int call) => AuthResult(
  accessToken: call == 1 ? 'first-access' : 'second-access',
  refreshToken: call == 1 ? 'first-refresh' : 'second-refresh',
  expiresIn: 900,
  mustChangePassword: false,
  user: call == 1 ? _profile('first', '第一次登录') : _profile('second', '第二次登录'),
);

class _QueuedLoginRepository implements AuthRepository {
  _QueuedLoginRepository({this.blockFirstLogin = false});

  final bool blockFirstLogin;
  final firstLoginStarted = Completer<void>();
  final secondLoginStarted = Completer<void>();
  final _releaseFirst = Completer<void>();
  final List<String?> revokedAccessTokens = <String?>[];
  final List<String?> revokedRefreshTokens = <String?>[];
  var loginCalls = 0;

  void releaseFirstLogin() {
    if (!_releaseFirst.isCompleted) _releaseFirst.complete();
  }

  @override
  Future<AuthResult> login(String loginAccount, String password) async {
    final call = ++loginCalls;
    if (call == 1) {
      if (!firstLoginStarted.isCompleted) firstLoginStarted.complete();
      if (blockFirstLogin) await _releaseFirst.future;
    } else if (call == 2 && !secondLoginStarted.isCompleted) {
      secondLoginStarted.complete();
    }
    return _result(call);
  }

  @override
  Future<void> logout(String? refreshToken) async {
    revokedAccessTokens.add(null);
    revokedRefreshTokens.add(refreshToken);
  }

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<UserProfile> me() => throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _BlockingChangePasswordRepository implements AuthRepository {
  final changePasswordStarted = Completer<void>();
  final _releasePasswordChange = Completer<void>();

  void releasePasswordChange() {
    if (!_releasePasswordChange.isCompleted) {
      _releasePasswordChange.complete();
    }
  }

  @override
  Future<AuthResult> changePassword(
    String oldPassword,
    String newPassword,
  ) async {
    if (!changePasswordStarted.isCompleted) {
      changePasswordStarted.complete();
    }
    await _releasePasswordChange.future;
    return _result(2);
  }

  @override
  Future<void> logout(String? refreshToken) async {}

  @override
  Future<AuthResult> login(String loginAccount, String password) =>
      throw UnimplementedError();

  @override
  Future<UserProfile> me() => throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _RotateBeforeAtomicClearStorage extends SecureStorage {
  _RotateBeforeAtomicClearStorage(super.storage);

  var _rotated = false;

  @override
  Future<AuthTokenClearResult> clearForLogoutIntent({
    Future<void> Function(AuthTokenSnapshot previous)? beforeClear,
  }) async {
    if (!_rotated) {
      _rotated = true;
      await saveTokens(
        accessToken: 'rotated-access',
        refreshToken: 'rotated-refresh',
      );
    }
    return super.clearForLogoutIntent(beforeClear: beforeClear);
  }
}

class _ControlledRestoreRepository implements AuthRepository {
  _ControlledRestoreRepository({this.subsequentProfile});

  final UserProfile? subsequentProfile;
  final firstMeStarted = Completer<void>();
  final _firstMe = Completer<UserProfile>();
  var meCalls = 0;

  void completeFirst(UserProfile profile) => _firstMe.complete(profile);
  void failFirst(Object error) => _firstMe.completeError(error);

  @override
  Future<UserProfile> me() {
    meCalls++;
    if (meCalls == 1) {
      firstMeStarted.complete();
      return _firstMe.future;
    }
    return Future<UserProfile>.value(
      subsequentProfile ?? _profile('fallback', '后续恢复'),
    );
  }

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

class _MutableProfileRepository implements AuthRepository {
  _MutableProfileRepository(this.profile);

  UserProfile profile;
  var meCalls = 0;

  @override
  Future<UserProfile> me() async {
    meCalls++;
    return profile;
  }

  @override
  Future<void> logout(String? refreshToken) async {}

  @override
  Future<AuthResult> login(String loginAccount, String password) =>
      throw UnimplementedError();

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}

class _FailingLogoutStorage extends SecureStorage {
  _FailingLogoutStorage(super.storage);

  var clearAttempts = 0;

  @override
  Future<AuthTokenClearResult> clearForLogoutIntent({
    Future<void> Function(AuthTokenSnapshot previous)? beforeClear,
  }) async {
    clearAttempts++;
    throw StateError('secure storage unavailable');
  }
}

class _BlockingLoginAccountStorage extends SecureStorage {
  _BlockingLoginAccountStorage(super.storage);

  final accountWriteStarted = Completer<void>();
  final _release = Completer<void>();

  void releaseAccountWrite() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> saveLoginAccount(String account) async {
    if (!accountWriteStarted.isCompleted) accountWriteStarted.complete();
    await _release.future;
  }
}
