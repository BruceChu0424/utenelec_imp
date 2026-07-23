// 会话失效事件总线（全局单例）。
// 鉴权层（AuthInterceptor 401 刷新失败）与 UI 层（sessionProvider）解耦：拦截器通知失效，
// sessionProvider 监听后置为未登录 + 跳登录页。避免 Riverpod 与 Dio 之间的循环依赖。
import 'dart:async';

class SessionEventBus {
  SessionEventBus._();
  static final SessionEventBus instance = SessionEventBus._();

  final _controller = StreamController<void>.broadcast();
  Stream<void> get onSessionExpired => _controller.stream;

  void expire() {
    if (!_controller.isClosed) _controller.add(null);
  }

  void dispose() => _controller.close();
}
