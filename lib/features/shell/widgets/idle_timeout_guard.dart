// IdleTimeoutGuard - 会话空闲超时守卫（滑动会话）。
//
// 包在已登录区根（main_shell）：全局监听用户活动 → 续期；超时 → 立即本地登出，
// 再尽力撤销服务端 refresh token。
// 阈值从 /api/settings/public 拉（session_idle_timeout_minutes，默认 30）。
//
// 阈值生效时机（修复"管理员改了当前会话不生效"）：
//   * 进入系统拉一次；
//   * 每 5 分钟定时轮询一次（超管在别处改了，本机最迟 5 分钟内生效）；
//   * 监听 idleThresholdVersionProvider——超管在本机「系统设置」保存后自增该信号，立即重拉。
//
// 安全：超时后先清 access + refresh 与内存会话，强制重新输密码，非静默续期。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/idle_timeout_controller.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/repositories/public_settings_repository.dart';

class IdleTimeoutGuard extends ConsumerStatefulWidget {
  const IdleTimeoutGuard({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<IdleTimeoutGuard> createState() => _IdleTimeoutGuardState();
}

class _IdleTimeoutGuardState extends ConsumerState<IdleTimeoutGuard> {
  Timer? _pollTimer;
  bool _handlingTimeout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadThreshold());
    // 定时轮询阈值（每 5 分钟）：超管在别处/别机改了阈值，本机最迟 5 分钟内拉到新值生效。
    _pollTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _loadThreshold(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadThreshold() async {
    try {
      final s = await ref.read(publicSettingsRepositoryProvider).fetch();
      if (mounted) {
        ref
            .read(idleTimeoutProvider.notifier)
            .setThreshold(s.idleTimeoutMinutes);
      }
    } catch (_) {
      /* 拉取失败保持当前阈值 */
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<IdleTimeoutState>(idleTimeoutProvider, (prev, next) {
      if (next.timedOut && !(prev?.timedOut ?? false)) {
        unawaited(_handleTimeout());
      }
    });
    // 超管在本机「系统设置」保存阈值后自增此信号 → 立即重拉（当前会话即时生效，不必重登）。
    ref.listen<int>(idleThresholdVersionProvider, (previous, next) {
      if (mounted) _loadThreshold();
    });
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, _) {
        _recordActivity();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _recordActivity(),
        onPointerMove: (_) => _recordActivity(),
        onPointerHover: (_) => _recordActivity(),
        onPointerSignal: (_) => _recordActivity(),
        child: widget.child,
      ),
    );
  }

  void _recordActivity() {
    ref.read(idleTimeoutProvider.notifier).recordActivity();
  }

  Future<void> _handleTimeout() async {
    if (_handlingTimeout) return;
    _handlingTimeout = true;
    final idle = ref.read(idleTimeoutProvider.notifier);
    try {
      await ref.read(sessionProvider.notifier).logout();
    } finally {
      // 下一次登录从新的活动时间开始，不能继承已超时状态。
      idle.reset();
    }
  }
}
