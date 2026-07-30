// 会话空闲超时控制器（滑动会话）。
//
// 用户活动（点击/输入/滚动）→ recordActivity 续期；空闲超过阈值分钟 → timedOut=true
// （由 UI 层弹窗提示后 logout）。阈值从 /api/settings/public 拉
// （session_idle_timeout_minutes，默认 30，管理员可在系统设置页调整）。
//
// 仅记录「最后一次活动时间 + 定时检查」，不直接登出——登出由 UI 层（IdleTimeoutGuard 弹窗）触发，
// 保持与 sessionProvider 解耦。Timer 30s 粒度检查（_check 用秒级判定，小阈值更精确）。
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
    // 秒级判定（而非 inMinutes 向下取整）：让 1 分钟等小阈值在到达后下一次 30s tick 即触发，
    // 而非整数分钟取整导致最多 ~阈值+1 分钟才弹。
    if (idle.inSeconds >= state.thresholdMinutes * 60) {
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

/// 阈值刷新信号：超管在「系统设置」保存 session_idle_timeout_minutes 后自增，
/// IdleTimeoutGuard 监听到变化立即重拉阈值（当前会话即时生效，不必下次登录）。
/// 配合 IdleTimeoutGuard 的 5 分钟定时轮询，覆盖「本机即时」+「他机/别处最终一致」两种场景。
final idleThresholdVersionProvider = StateProvider<int>((ref) => 0);
