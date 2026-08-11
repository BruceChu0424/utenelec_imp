// 委外任务中心待办任务计数（工作台「委外管理」卡片徽标）。
//
// 口径 = 委外任务台 open_qty>0 行（待分解 + 待采购完成 + 财务驳回），与采购任务计数
// 范式一致，设计对齐采购。默认 60s 轮询；有委外申请/订单查看权限才拉取，否则返回 0。
// 范式同 lib/features/purchase/providers/purchase_task_count_provider.dart。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';

const Duration _kSubcontractTaskPollInterval = Duration(seconds: 60);

/// 委外任务中心待办数（待分解 + 待采购完成 + 财务驳回）。
///
/// 有委外申请/订单查看权限时 60s 轮询；其它角色返回 0。count 为 0 时徽章不渲染。
final subcontractTaskCountProvider =
    StateNotifierProvider<SubcontractTaskCountNotifier, int>((ref) {
      final notifier = SubcontractTaskCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class SubcontractTaskCountNotifier extends StateNotifier<int> {
  SubcontractTaskCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kSubcontractTaskPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.subcontractApplicationView) ||
        perms.contains(Perm.subcontractOrderView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      state = await ref
          .read(operationsWorkbenchRepositoryProvider)
          .subcontractTaskCount();
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（返回工作台 / 新通知到达 / 任务状态变化后调用）。
  Future<void> refresh() => _tick();
}
