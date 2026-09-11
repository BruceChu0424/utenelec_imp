import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/dashboard/providers/workbench_refresh.dart';
import '../providers/session_provider.dart';

/// 登录会话重建门（不渲染，app 根常驻）。
///
/// 背景（2026-09-09 用户反馈：清空业务数据后重新登录「要再刷新一次才彻底清空」）：
/// 全局角标（未读通知、各部门待办计数）是 ProviderScope 级常驻 StateNotifier，
/// 登出不重建、登录后要等 60s 轮询或手动刷新才校正；「返回即刷新」信号在同路径
/// 落点（/dashboard→/login→/dashboard）与页面重建时序下也可能错过。
///
/// 本门在 session 从未登录→已登录（含清空业务数据后的重新登录）时推进
/// `sessionEpochProvider`：接入它的全局角标 Notifier 从零重建并立即重拉，
/// 工作台概览/通知列表缓存失效——新会话永远看到新数据（见 [rehydrateGlobalState]）。
class SessionRehydrateGate extends ConsumerWidget {
  const SessionRehydrateGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(sessionProvider.select((s) => s.user?.id), (previous, next) {
      final wasLoggedOut = previous == null;
      final nowLoggedIn = next != null;
      if (wasLoggedOut && nowLoggedIn) {
        rehydrateGlobalState(ref);
      }
    });
    return const SizedBox.shrink();
  }
}
