// 委外任务中心待办任务计数（工作台「委外管理」卡片徽标 + 任务中心「待处理」段）。
//
// 口径由工作台count接口统一返回：真实申请/订单待办 + 尚未全量通知的前置生产任务。
// 已全通知或取消的前置任务由服务端排除，不通过某一页的items.length推算。
// 默认 60s 轮询；有委外申请/订单查看权限才拉取，否则返回 0。
// 范式同 lib/features/purchase/providers/purchase_task_count_provider.dart。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;

const Duration _kSubcontractTaskPollInterval = Duration(seconds: 60);

/// 委外任务中心待办数（待处理〔含前置生产〕+ 待采购完成 + 财务驳回）。
///
/// 有委外申请/订单查看权限时 60s 轮询；其它角色返回 0。count 为 0 时徽章不渲染。
final subcontractTaskCountProvider =
    StateNotifierProvider<SubcontractTaskCountNotifier, int>((ref) {
      // 新登录会话从零重建并立即重拉（见 shared/auth/session_epoch_provider.dart）。
      ref.watch(sessionEpochProvider);
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(currentPermissionsProvider);
      ref.watch(isSuperAdminProvider);
      final notifier = SubcontractTaskCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class SubcontractTaskCountNotifier extends StateNotifier<int> {
  SubcontractTaskCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;
  bool _stopped = false;
  bool _loading = false;

  void start() {
    _tick();
    _timer = Timer.periodic(_kSubcontractTaskPollInterval, (_) => _tick());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_stopped || _loading) return;
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.subcontractApplicationView) ||
        perms.contains(Perm.subcontractOrderView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    _loading = true;
    try {
      final total = await ref
          .read(operationsWorkbenchRepositoryProvider)
          .subcontractTaskCount();
      if (!_stopped) state = total;
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    } finally {
      _loading = false;
    }
  }

  /// 立即刷新（返回工作台 / 新通知到达 / 任务状态变化后调用）。
  Future<void> refresh() => _tick();
}
