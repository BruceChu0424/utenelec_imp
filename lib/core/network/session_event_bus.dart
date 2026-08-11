// 会话失效事件总线（全局单例）。
// 鉴权层（AuthInterceptor 401 刷新失败）与 UI 层（sessionProvider）解耦：拦截器通知失效，
// sessionProvider 监听后置为未登录 + 跳登录页。避免 Riverpod 与 Dio 之间的循环依赖。
import 'dart:async';

class SessionEventBus {
  SessionEventBus._();
  static final SessionEventBus instance = SessionEventBus._();

  final _controller = StreamController<void>.broadcast();
  Stream<void> get onSessionExpired => _controller.stream;

  // 模拟身份（admin 切换人）到期 / 失效事件：模拟 token 401 时由 AuthInterceptor 触发，
  // sessionProvider 监听后退出模拟、恢复 admin（不登出 admin 主会话）。
  final _impersonationExpiredController = StreamController<void>.broadcast();
  Stream<void> get onImpersonationExpired =>
      _impersonationExpiredController.stream;

  // access token 静默刷新成功事件：携带 /auth/refresh 响应里的 user JSON（含最新权限）。
  // sessionProvider 监听后用它更新权限快照，使权限随刷新滑动更新（不再只在登录时拉一次）。
  // 用 Map 而非 UserProfile 类型，避免 core 层反向依赖 features/auth/model。
  final _profileController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onProfileRefreshed =>
      _profileController.stream;

  void expire() {
    if (!_controller.isClosed) _controller.add(null);
  }

  /// 模拟身份到期（模拟 token 401）：退出模拟，恢复 admin。不影响 admin 主会话。
  void impersonationExpired() {
    if (!_impersonationExpiredController.isClosed) {
      _impersonationExpiredController.add(null);
    }
  }

  /// [userJson] 为 /auth/refresh 响应里的 user 对象（TokenResponse 的 profile JSON）。
  void publishProfile(Map<String, dynamic> userJson) {
    if (!_profileController.isClosed) _profileController.add(userJson);
  }

  void dispose() {
    _controller.close();
    _impersonationExpiredController.close();
    _profileController.close();
  }
}
