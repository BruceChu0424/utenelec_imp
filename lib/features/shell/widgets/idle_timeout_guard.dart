// IdleTimeoutGuard - 会话空闲超时守卫（滑动会话）。
//
// 包在已登录区根（main_shell）：全局 Listener 监听用户活动 → 续期；超时 → 弹窗提示后登出。
// 阈值从 /api/settings/public 拉（session_idle_timeout_minutes，默认 30）。
//
// 阈值生效时机（修复"管理员改了当前会话不生效"）：
//   * 进入系统拉一次；
//   * 每 5 分钟定时轮询一次（超管在别处改了，本机最迟 5 分钟内生效）；
//   * 监听 idleThresholdVersionProvider——超管在本机「系统设置」保存后自增该信号，立即重拉。
//
// 安全：超时后 logout（清 access + refresh，强制重新输密码，非静默续期）；
// 弹窗不可关闭（barrierDismissible:false），只能点「重新登录」。
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadThreshold());
    // 定时轮询阈值（每 5 分钟）：超管在别处/别机改了阈值，本机最迟 5 分钟内拉到新值生效。
    _pollTimer = Timer.periodic(const Duration(minutes: 5), (_) => _loadThreshold());
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
        ref.read(idleTimeoutProvider.notifier).setThreshold(s.idleTimeoutMinutes);
      }
    } catch (_) {
      /* 拉取失败保持当前阈值 */
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<IdleTimeoutState>(idleTimeoutProvider, (prev, next) {
      if (next.timedOut && !(prev?.timedOut ?? false)) {
        _showTimeoutDialog(next.thresholdMinutes);
      }
    });
    // 超管在本机「系统设置」保存阈值后自增此信号 → 立即重拉（当前会话即时生效，不必重登）。
    ref.listen<int>(idleThresholdVersionProvider, (previous, next) {
      if (mounted) _loadThreshold();
    });
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => ref.read(idleTimeoutProvider.notifier).recordActivity(),
      onPointerMove: (_) => ref.read(idleTimeoutProvider.notifier).recordActivity(),
      child: widget.child,
    );
  }

  void _showTimeoutDialog(int minutes) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      routeSettings: const RouteSettings(name: 'idle-timeout'),
      builder: (_) => _IdleTimeoutDialog(minutes: minutes),
    );
  }
}

class _IdleTimeoutDialog extends ConsumerWidget {
  const _IdleTimeoutDialog({required this.minutes});
  final int minutes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopScope(
      canPop: false, // 物理返回键也不关，强制走「重新登录」
      child: AlertDialog(
        icon: const Icon(Icons.lock_clock_outlined, size: 40),
        title: const Text('会话已超时'),
        content: Text(
          '您已 $minutes 分钟没有使用系统，根据优腾系统安全法，将自动退出系统。您需要重新登录。',
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(sessionProvider.notifier).logout();
              ref.read(idleTimeoutProvider.notifier).reset();
              // logout → sessionProvider unauthenticated → 路由 redirect 跳登录页
            },
            child: const Text('重新登录'),
          ),
        ],
      ),
    );
  }
}
