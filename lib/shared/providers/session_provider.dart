// 会话 Provider（真实后端鉴权）。
// 状态：unauthenticated / authenticated / mustChangePassword。
// 令牌存 SecureStorage；启动时凭 refresh 恢复；401 刷新失败时由 SessionEventBus 通知登出。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/session_event_bus.dart';
import '../../core/security/secure_storage.dart';
import '../../features/auth/models/auth_session.dart';
import '../../features/auth/repositories/auth_repository.dart';
import '../models/role.dart';
import '../models/user.dart';

enum AuthStatus { unauthenticated, authenticated, mustChangePassword }

class SessionState {
  const SessionState({
    this.status = AuthStatus.unauthenticated,
    this.user,
  });

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
    SessionEventBus.instance.onSessionExpired.listen((_) {
      state = const SessionState();
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
      state = SessionState(status: AuthStatus.authenticated, user: _toAppUser(p));
    } catch (_) {
      await _storage.clear();
    }
  }

  /// 登录（抛 ApiException 由调用方展示错误）。
  Future<void> login({
    required String account,
    required String password,
    bool rememberDevice = false,
  }) async {
    final res = await _auth.login(account, password);
    final user = _toAppUser(res.user);
    state = SessionState(
      status: res.mustChangePassword ? AuthStatus.mustChangePassword : AuthStatus.authenticated,
      user: user,
    );
  }

  /// 首登强制改密 / 设置中改密（后端返回新令牌，当前设备保持登录）。
  Future<void> changePassword({required String oldPassword, required String newPassword}) async {
    final res = await _auth.changePassword(oldPassword, newPassword);
    state = SessionState(status: AuthStatus.authenticated, user: _toAppUser(res.user));
  }

  Future<void> logout() async {
    final refresh = await _storage.getRefreshToken();
    try {
      await _auth.logout(refresh);
    } catch (_) {
      await _storage.clear();
    }
    state = const SessionState();
  }

  AppUser _toAppUser(UserProfile p) => AppUser(
        id: p.id,
        code: p.code ?? p.loginAccount,
        name: p.name ?? p.loginAccount,
        roles: p.roles.map(_toRole).toList(),
        department: p.department,
        position: p.position,
        permissions: p.permissions,
      );

  static Role _toRole(String code) =>
      Role.values.firstWhere((r) => r.name == code, orElse: () => Role.employee);
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);
