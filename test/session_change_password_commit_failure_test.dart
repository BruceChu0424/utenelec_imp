// 改密收尾失败契约：服务端已接受改密（密码已生效）后，本机会话提交链抛出
// 意外异常（响应解析 / 安全存储落盘）时：
// 1. 对外抛 PasswordChangeCommittedError（而非吞掉让页面显示模糊兜底文案）；
// 2. 本地令牌保持改密前原样（新令牌从未落盘）；
// 3. 服务端新签发的刷新令牌被尽力吊销，不遗留可用凭证。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/security/auth_logout_fence.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'support/fake_auth_logout_fence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'server-accepted change whose local commit fails surfaces '
    'PasswordChangeCommittedError and revokes the new refresh token',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final storage = _CommitFailingStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'current-access',
        refreshToken: 'current-refresh',
      );
      final repository = _AcceptedChangePasswordRepository();
      final container = _container(storage, repository);
      addTearDown(container.dispose);

      final notifier = container.read(sessionProvider.notifier);
      await pumpEventQueue();

      await expectLater(
        notifier.changePassword(
          oldPassword: 'old-secret',
          newPassword: 'new-secret',
        ),
        throwsA(isA<PasswordChangeCommittedError>()),
      );
      await pumpEventQueue();

      // 本地令牌保持改密前的原样：新令牌从未落盘。
      expect(await storage.getAccessToken(), 'current-access');
      expect(await storage.getRefreshToken(), 'current-refresh');
      // 服务端新签发的刷新令牌被尽力吊销，不遗留可用凭证。
      expect(repository.revokedRefreshTokens, <String?>['new-refresh']);
    },
  );
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

/// commitSessionIntentTokens 落盘即失败：模拟 Windows 凭据管理器 /
/// Web sessionStorage 写入意外抛错。其余行为继承真实实现。
class _CommitFailingStorage extends SecureStorage {
  _CommitFailingStorage(super.storage);

  @override
  Future<AuthTokenSnapshot?> commitSessionIntentTokens({
    required AuthSessionIntent intent,
    required String accessToken,
    required String refreshToken,
  }) async {
    throw StateError('secure storage write failed');
  }
}

/// 改密接口直接成功返回新令牌（服务端已接受），logout 仅记录便于断言吊销。
class _AcceptedChangePasswordRepository implements AuthRepository {
  final revokedRefreshTokens = <String?>[];

  @override
  Future<AuthResult> changePassword(
    String oldPassword,
    String newPassword,
  ) async {
    return const AuthResult(
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      expiresIn: 900,
      mustChangePassword: false,
      user: UserProfile(
        id: 'u1',
        loginAccount: 'u1',
        permissions: <String>[],
        superAdmin: false,
      ),
    );
  }

  @override
  Future<void> logout(String? refreshToken) async {
    revokedRefreshTokens.add(refreshToken);
  }

  @override
  Future<AuthResult> login(String loginAccount, String password) =>
      throw UnimplementedError();

  @override
  Future<UserProfile> me() => throw UnimplementedError();

  @override
  Future<AuthResult> refresh(String refreshToken) => throw UnimplementedError();
}
