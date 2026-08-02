// 鉴权仓库只负责网络交换；SessionNotifier 仅串行提交最新用户意图的令牌与状态。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/auth_session.dart';
import '../services/pending_refresh_revocation_drainer.dart';

abstract interface class AuthRepository {
  Future<AuthResult> login(String loginAccount, String password);
  Future<AuthResult> refresh(String refreshToken);
  Future<void> logout(String? refreshToken);
  Future<AuthResult> changePassword(String oldPassword, String newPassword);
  Future<UserProfile> me();
}

/// Direct network transport. Production callers use the durable decorator
/// below; the pending-revocation drainer calls this endpoint through its own
/// dedicated transport so queued logout never recurses through the decorator.
class DioAuthRepository implements AuthRepository {
  DioAuthRepository(this.api);

  final ApiClient api;

  @override
  Future<AuthResult> login(String loginAccount, String password) async {
    final json = await api.post(
      ApiEndpoints.authLogin,
      body: <String, String>{
        'loginAccount': loginAccount,
        'password': password,
      },
    );
    return AuthResult.fromJson(json);
  }

  @override
  Future<AuthResult> refresh(String refreshToken) async {
    final json = await api.post(
      ApiEndpoints.authRefresh,
      body: <String, String>{'refreshToken': refreshToken},
    );
    return AuthResult.fromJson(json);
  }

  @override
  Future<void> logout(String? refreshToken) async {
    await api.post(
      ApiEndpoints.authLogout,
      body: <String, String?>{'refreshToken': refreshToken},
    );
  }

  @override
  Future<AuthResult> changePassword(
    String oldPassword,
    String newPassword,
  ) async {
    final json = await api.post(
      ApiEndpoints.authChangePassword,
      body: <String, String>{
        'oldPassword': oldPassword,
        'newPassword': newPassword,
      },
    );
    return AuthResult.fromJson(json);
  }

  @override
  Future<UserProfile> me() async {
    final json = await api.get(ApiEndpoints.authMe);
    return UserProfile.fromJson(json);
  }
}

/// Adds durable, encrypted, eventually-consistent server revocation to every
/// local logout or stale-auth-result eviction without delaying the caller on
/// network availability.
class DurableLogoutAuthRepository implements AuthRepository {
  DurableLogoutAuthRepository(this._delegate, this._pendingRevocations);

  final AuthRepository _delegate;
  final PendingRefreshRevocationDrainer _pendingRevocations;

  @override
  Future<void> logout(String? refreshToken) async {
    await _pendingRevocations.enqueueAndDrain(refreshToken);
  }

  @override
  Future<AuthResult> login(String loginAccount, String password) =>
      _delegate.login(loginAccount, password);

  @override
  Future<AuthResult> refresh(String refreshToken) =>
      _delegate.refresh(refreshToken);

  @override
  Future<AuthResult> changePassword(String oldPassword, String newPassword) =>
      _delegate.changePassword(oldPassword, newPassword);

  @override
  Future<UserProfile> me() => _delegate.me();
}

final authNetworkRepositoryProvider = Provider<AuthRepository>(
  (ref) => DioAuthRepository(ref.watch(apiClientProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => DurableLogoutAuthRepository(
    ref.watch(authNetworkRepositoryProvider),
    ref.watch(pendingRefreshRevocationDrainerProvider),
  ),
);
