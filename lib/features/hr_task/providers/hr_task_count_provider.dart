// HR 任务中心徽标计数（工作台「行政与人力资源部 · 任务中心」卡片角标）。
// 有 employee:view 权限时 60s 轮询；其它角色返回 0（不渲染徽章）。
// 范式同 rd_task_count_provider.dart。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/hr_task_repository.dart';

const Duration _kHrTaskPollInterval = Duration(seconds: 60);

final hrTaskCountProvider = StateNotifierProvider<HrTaskCountNotifier, int>((
  ref,
) {
  final notifier = HrTaskCountNotifier(ref);
  notifier.start();
  ref.onDispose(notifier.stop);
  return notifier;
});

class HrTaskCountNotifier extends StateNotifier<int> {
  HrTaskCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kHrTaskPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.employeeView) || ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      state = await ref.read(hrTaskRepositoryProvider).count();
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（页面手动刷新后调用）。
  Future<void> refresh() => _tick();
}
