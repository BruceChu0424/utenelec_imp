// 访客会话失效事件总线（与员工 SessionEventBus 隔离，解耦 Dio 与 Riverpod）。
import 'dart:async';

class VisitorSessionEventBus {
  VisitorSessionEventBus._();
  static final VisitorSessionEventBus instance = VisitorSessionEventBus._();

  final StreamController<void> _controller = StreamController<void>.broadcast();

  Stream<void> get onSessionExpired => _controller.stream;

  void expire() {
    if (!_controller.isClosed) _controller.add(null);
  }
}
