import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'support/fake_auth_logout_fence.dart';

const _fixtureBase = 'https://staff-restore.example.test/api';
final _fixtureIssuer = AuthBackendRealmPolicy().issuerFor(_fixtureBase);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动恢复遇到 5xx 等瞬态异常时保留 refresh token', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'valid-refresh',
      issuer: _fixtureIssuer,
    );
    final repository = _FailingAuthRepository(
      ApiException('INTERNAL', '服务器繁忙'),
    );
    final container = ProviderContainer(
      overrides: [
        apiBaseUrlProvider.overrideWithValue(_fixtureBase),
        secureStorageProvider.overrideWithValue(storage),
        authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
        authRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider);
    await pumpEventQueue();

    expect(repository.meCalls, 1);
    expect(await storage.getAccessToken(), 'old-access');
    expect(await storage.getRefreshToken(), 'valid-refresh');
  });

  test('启动恢复被明确判定为未授权时清理令牌', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'invalid-refresh',
      issuer: _fixtureIssuer,
    );
    final repository = _FailingAuthRepository(
      ApiException('UNAUTHORIZED', '会话已过期'),
    );
    final container = ProviderContainer(
      overrides: [
        apiBaseUrlProvider.overrideWithValue(_fixtureBase),
        secureStorageProvider.overrideWithValue(storage),
        authLogoutFenceProvider.overrideWithValue(FakeAuthLogoutFence()),
        authRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionProvider);
    await pumpEventQueue();

    expect(repository.meCalls, 1);
    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getRefreshToken(), isNull);
  });
}

class _FailingAuthRepository implements AuthRepository {
  _FailingAuthRepository(this.error);

  final Object error;
  int meCalls = 0;

  @override
  Future<UserProfile> me() {
    meCalls++;
    return Future<UserProfile>.error(error);
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
