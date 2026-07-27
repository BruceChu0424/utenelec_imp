// 会话空闲超时控制器（滑动会话）。
//
// 用户活动（点击/输入/滚动）→ recordActivity 续期；空闲超过阈值分钟 → timedOut=true
// （由 UI 层弹窗提示后 logout）。阈值从 /api/settings/public 拉
// （session_idle_timeout_minutes，默认 30，管理员可在系统设置页调整）。
//
// 仅记录「最后一次活动时间 + 定时检查」，不直接登出——登出由 UI 层（IdleTimeoutGuard 弹窗）触发，
// 保持与 sessionProvider 解耦。Timer 30s 粒度检查（平衡及时性与开销）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class IdleTimeoutState {
  const IdleTimeoutState({
    this.lastActivity,
    this.thresholdMinutes = 30,
    this.timedOut = false,
  });
  final DateTime? lastActivity;
  final int thresholdMinutes;
  final bool timedOut;

  IdleTimeoutState copyWith({
    DateTime? lastActivity,
    int? thresholdMinutes,
    bool? timedOut,
  }) =>
      IdleTimeoutState(
        lastActivity: lastActivity ?? this.lastActivity,
        thresholdMinutes: thresholdMinutes ?? this.thresholdMinutes,
        timedOut: timedOut ?? this.timedOut,
      );
}

class IdleTimeoutNotifier extends Notifier<IdleTimeoutState> {
  Timer? _timer;

  @override
  IdleTimeoutState build() {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    ref.onDispose(() => _timer?.cancel());
    return IdleTimeoutState(lastActivity: DateTime.now());
  }

  /// 用户活动（点击/输入/滚动）→ 续期。已超时则不续期（等用户重新登录后 reset）。
  void recordActivity() {
    if (state.timedOut) return;
    state = state.copyWith(lastActivity: DateTime.now());
  }

  /// 从 /api/settings/public 设置阈值（管理员改了，下次拉取生效）。
  void setThreshold(int minutes) {
    if (minutes < 1) return;
    state = state.copyWith(thresholdMinutes: minutes);
  }

  void _check() {
    final last = state.lastActivity;
    if (last == null || state.timedOut) return;
    final idle = DateTime.now().difference(last);
    if (idle.inMinutes >= state.thresholdMinutes) {
      state = state.copyWith(timedOut: true);
    }
  }

  /// 重新登录后重置（恢复计时）。
  void reset() {
    state = IdleTimeoutState(
      lastActivity: DateTime.now(),
      thresholdMinutes: state.thresholdMinutes,
    );
  }
}

final idleTimeoutProvider =
    NotifierProvider<IdleTimeoutNotifier, IdleTimeoutState>(IdleTimeoutNotifier.new);
