// 工程研发部任务中心待完成任务计数（工作台「工程研发部」卡片徽标）。
// 有 rd_task:view 权限时 60s 轮询；其它角色返回 0（不渲染徽章）。
// 范式同 purchase_task_count_provider.dart。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../repositories/rd_task_repository.dart';

const Duration _kRdTaskPollInterval = Duration(seconds: 60);

/// 跨 Tab 刷新信号：在「待完成」完成任务后自增，让「已完成」Tab 重拉（同 B 类 listRefreshTick 思路）。
final rdTaskRefreshTickProvider = StateProvider<int>((ref) => 0);

final rdTaskCountProvider = StateNotifierProvider<RdTaskCountNotifier, int>((
  ref,
) {
  // 新登录会话从零重建并立即重拉（见 shared/auth/session_epoch_provider.dart）。
  ref.watch(sessionEpochProvider);
  final notifier = RdTaskCountNotifier(ref);
  notifier.start();
  ref.onDispose(notifier.stop);
  return notifier;
});

class RdTaskCountNotifier extends StateNotifier<int> {
  RdTaskCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kRdTaskPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.rdTaskView) || ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final count = await ref.read(rdTaskRepositoryProvider).count();
      if (mounted) state = count; // 会话重建后旧实例已释放，丢弃迟到结果
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（完成任务 / 转发后调用）。
  Future<void> refresh() => _tick();
}
