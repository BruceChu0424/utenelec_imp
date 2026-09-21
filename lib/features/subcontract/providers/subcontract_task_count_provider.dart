// 委外任务中心计数(工作台「委外管理」卡片角标): 红色待办(+ 任务中心「待处理」段)
// 与黄色「进行中」两个数, 各自 60s 轮询、各自权限自卫。
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

/// 委外任务中心「进行中」任务行数(等待财务审核 + 财务已通过 + 财务驳回),
/// 与任务中心页内「进行中」段同数。
///
/// ADR-100 的黄色那条链: 已发料在外加工、等财务、等回厂的单都在跑着还没完, 但
/// 现在不用委外动手。自卫与降级同红色那个 notifier: 无权限 0 且不发请求、
/// 会话重建清零重拉、异常保留旧值。
final subcontractTaskInProgressCountProvider =
    StateNotifierProvider<SubcontractTaskInProgressCountNotifier, int>((ref) {
      ref.watch(sessionEpochProvider);
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(currentPermissionsProvider);
      ref.watch(isSuperAdminProvider);
      final notifier = SubcontractTaskInProgressCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class SubcontractTaskInProgressCountNotifier extends StateNotifier<int> {
  SubcontractTaskInProgressCountNotifier(this.ref) : super(0);

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
      final counts = await ref
          .read(operationsWorkbenchRepositoryProvider)
          .subcontractTaskCounts();
      if (!_stopped) state = counts.inProgress;
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    } finally {
      _loading = false;
    }
  }

  /// 立即刷新(下单 / 财务审批结果 / 回厂登记后调用)。
  Future<void> refresh() => _tick();
}
