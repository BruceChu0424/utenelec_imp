// 会话 Provider（真实后端鉴权）。
// 状态：unauthenticated / authenticated / mustChangePassword。
// 令牌存 SecureStorage；启动时凭 refresh 恢复；401 刷新失败时由 SessionEventBus 通知登出。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/session_event_bus.dart';
import '../../core/security/secure_storage.dart';
import '../../features/auth/models/auth_session.dart';
import '../../features/auth/repositories/auth_repository.dart';
import '../models/role.dart';
import '../models/user.dart';

enum AuthStatus { unauthenticated, authenticated, mustChangePassword }

class SessionState {
  const SessionState({this.status = AuthStatus.unauthenticated, this.user});

  final AuthStatus status;
  final AppUser? user;

  bool get isLoggedIn => status == AuthStatus.authenticated;
  bool get mustChangePassword => status == AuthStatus.mustChangePassword;
  AppUser? get u => user;
}

class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() {
    // 启动恢复：若有 refresh 令牌，尝试 /auth/me 恢复登录态
    Future.microtask(_restore);
    // 监听会话失效（AuthInterceptor 401 刷新失败）
    final expirationSubscription = SessionEventBus.instance.onSessionExpired
        .listen((_) {
          state = const SessionState();
        });
    // 监听 access 刷新成功（AuthInterceptor）：用最新 profile 更新权限快照，
    // 使权限变更随刷新即时生效（不再只在登录时拉一次、重登才反映）。
    final profileSubscription = SessionEventBus.instance.onProfileRefreshed
        .listen((userJson) {
          if (state.status == AuthStatus.authenticated) {
            state = SessionState(
              status: AuthStatus.authenticated,
              user: _toAppUser(UserProfile.fromJson(userJson)),
            );
          }
        });
    ref.onDispose(() {
      unawaited(expirationSubscription.cancel());
      unawaited(profileSubscription.cancel());
    });
    return const SessionState();
  }

  AuthRepository get _auth => ref.read(authRepositoryProvider);
  SecureStorage get _storage => ref.read(secureStorageProvider);

  Future<void> _restore() async {
    final refresh = await _storage.getRefreshToken();
    if (refresh == null || refresh.isEmpty) return;
    try {
      final p = await _auth.me();
      state = SessionState(
        status: AuthStatus.authenticated,
        user: _toAppUser(p),
      );
    } on ApiException catch (error) {
      // 只有服务端明确判定凭据失效时才删除令牌。断网、超时、5xx、限流或
      // 部署窗口中的异常都应保留 refresh token，让下一次恢复能够重试。
      if (const {
        'UNAUTHORIZED',
        'ACCOUNT_LOCKED',
        'ACCOUNT_DISABLED',
      }.contains(error.code)) {
        await _storage.clear();
      }
    } catch (_) {
      // 异常响应或本地解析故障不等于会话失效，保留令牌供后续恢复。
    }
  }

  /// 登录（抛 ApiException 由调用方展示错误）。
  Future<void> login({
    required String account,
    required String password,
  }) async {
    final res = await _auth.login(account, password);
    final user = _toAppUser(res.user);
    state = SessionState(
      status: res.mustChangePassword
          ? AuthStatus.mustChangePassword
          : AuthStatus.authenticated,
      user: user,
    );
  }

  /// 首登强制改密 / 设置中改密（后端返回新令牌，当前设备保持登录）。
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final res = await _auth.changePassword(oldPassword, newPassword);
    state = SessionState(
      status: AuthStatus.authenticated,
      user: _toAppUser(res.user),
    );
  }

  Future<void> logout() async {
    // 先抓取撤销请求所需凭据；之后本地状态和令牌必须先于网络请求失效。
    final access = await _storage.getAccessToken();
    final refresh = await _storage.getRefreshToken();
    try {
      await _storage.clear();
    } catch (_) {
      // 平台安全存储异常也不能阻止内存会话立即失效。
    }
    state = const SessionState();

    // 远端撤销是尽力而为，不能阻塞本地退出，也不能在请求结束后再次 clear，
    // 否则用户快速重新登录时，迟到的旧 logout 会删掉新令牌。
    unawaited(_revokeRemote(access: access, refresh: refresh));
  }

  Future<void> _revokeRemote({
    required String? access,
    required String? refresh,
  }) async {
    try {
      await _auth.logout(refresh, accessToken: access, clearLocal: false);
    } catch (_) {
      // 本地会话已经失效；网络恢复后 refresh token 仍会按服务端 TTL 到期。
    }
  }

  AppUser _toAppUser(UserProfile p) => AppUser(
    id: p.id,
    code: p.code ?? p.loginAccount,
    name: p.name ?? p.loginAccount,
    roles: p.roles.map(_toRole).toList(),
    department: p.department,
    position: p.position,
    permissions: p.permissions,
    superAdmin: p.superAdmin,
    employeeId: p.employeeId,
  );

  static Role _toRole(String code) => Role.values.firstWhere(
    (r) => r.name == code,
    orElse: () => Role.employee,
  );
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);
