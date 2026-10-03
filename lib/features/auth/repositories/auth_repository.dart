// 鉴权仓库只负责网络交换；SessionNotifier 仅串行提交最新用户意图的令牌与状态。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/security/secure_storage.dart';
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
  DioAuthRepository(this.api, [this.storage]);

  final ApiClient api;
  final SecureStorage? storage;

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
    final submitted = await storage?.getAuthTokenSnapshot();
    final json = await api.get(ApiEndpoints.authMe);
    final profile = UserProfile.fromJson(json);
    final session = json['session'];
    if (session is Map<String, dynamic> && submitted?.sessionLineage != null) {
      final current = await storage!.getAuthTokenSnapshot();
      if (submitted!.isSameSession(current)) {
        RecentMeSnapshot.remember(profile.id, session, api, submitted);
      }
    }
    return profile;
  }
}

/// 最近一次 /auth/me 随资料带回的会话快照原文(ADR-108)。
///
/// 会话恢复刚调过 /auth/me, 会话快照 provider 紧接着取用这一份, 不再为快照重复请求;
/// 只存内存、只认同一用户、10 秒内有效、取用一次即清。
abstract final class RecentMeSnapshot {
  static bool get hasCandidate => _last != null;
  static const _ttl = Duration(seconds: 10);
  static ({
    String userId,
    Map<String, dynamic> session,
    DateTime at,
    ApiClient client,
    int generation,
    int intentGeneration,
    String lineage,
  })?
  _last;

  static void remember(
    String userId,
    Map<String, dynamic> session,
    ApiClient client,
    AuthTokenSnapshot tokens,
  ) {
    final lineage = tokens.sessionLineage;
    if (lineage == null || lineage.isEmpty) return;
    _last = (
      userId: userId,
      session: session,
      at: DateTime.now(),
      client: client,
      generation: tokens.generation,
      intentGeneration: tokens.intentGeneration,
      lineage: lineage,
    );
  }

  /// 取走 [userId] 的最近快照; 过期、换人或已取过返回 null。
  static Map<String, dynamic>? take(
    String userId,
    ApiClient client,
    AuthTokenSnapshot tokens,
  ) {
    final last = _last;
    _last = null;
    if (last == null ||
        last.userId != userId ||
        !identical(last.client, client) ||
        last.generation != tokens.generation ||
        last.intentGeneration != tokens.intentGeneration ||
        last.lineage != tokens.sessionLineage ||
        DateTime.now().difference(last.at) > _ttl) {
      return null;
    }
    return last.session;
  }

  static void clear() => _last = null;
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
  (ref) => DioAuthRepository(
    ref.watch(apiClientProvider),
    ref.read(secureStorageProvider),
  ),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => DurableLogoutAuthRepository(
    ref.watch(authNetworkRepositoryProvider),
    ref.watch(pendingRefreshRevocationDrainerProvider),
  ),
);
