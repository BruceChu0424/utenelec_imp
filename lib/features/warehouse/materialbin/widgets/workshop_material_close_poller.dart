// 自动结算进度轮询 (ADR-131 §5.8): 提交盘点 / 立即重试后, 结算在服务端后台执行,
// 页面每 2 秒问一次结算状态, 最多 60 秒; 状态不再是"排队结算中"就停。
// (避开 Flutter Web 写请求的 15 秒上限: 写请求只负责排队, 进度靠这里的读请求。)
import 'dart:async';

import '../models/workshop_material_models.dart';

class WmClosePoller {
  WmClosePoller({
    required this.load,
    required this.onStatus,
    this.interval = const Duration(seconds: 2),
    this.maxTicks = 30,
  });

  /// 读一次结算状态。
  final Future<WmCloseStatus> Function() load;

  /// 每次读到状态的回调 (页面在这里 setState)。
  final void Function(WmCloseStatus status) onStatus;
  final Duration interval;

  /// 最多问几次 (2 秒 × 30 = 60 秒)。
  final int maxTicks;

  Timer? _timer;
  int _ticks = 0;
  bool _inFlight = false;

  bool get active => _timer != null;

  void start() {
    stop();
    _ticks = 0;
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_inFlight) return;
    _ticks++;
    if (_ticks > maxTicks) {
      stop();
      return;
    }
    _inFlight = true;
    try {
      final status = await load();
      if (_timer == null) return;
      onStatus(status);
      if (!status.settling) stop();
    } catch (_) {
      // 读失败不打断: 下一次再问; 到上限自然停止。
    } finally {
      _inFlight = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
