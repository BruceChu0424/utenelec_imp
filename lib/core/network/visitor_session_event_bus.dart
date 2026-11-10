// 访客会话失效事件总线（与员工 SessionEventBus 隔离，解耦 Dio 与 Riverpod）。
import 'dart:async';

class VisitorSessionExpiryNotice {
  const VisitorSessionExpiryNotice({
    required this.sessionLineage,
    required this.intentGeneration,
  });
  final String sessionLineage;
  final int intentGeneration;
}

class VisitorSessionEventBus {
  VisitorSessionEventBus._();
  static final VisitorSessionEventBus instance = VisitorSessionEventBus._();

  final _controller = StreamController<VisitorSessionExpiryNotice>.broadcast();

  Stream<VisitorSessionExpiryNotice> get onSessionExpired => _controller.stream;

  void expire({required String sessionLineage, required int intentGeneration}) {
    if (!_controller.isClosed) {
      _controller.add(
        VisitorSessionExpiryNotice(
          sessionLineage: sessionLineage,
          intentGeneration: intentGeneration,
        ),
      );
    }
  }
}
