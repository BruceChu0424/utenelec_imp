// 采购任务中心计数(工作台「采购管理」卡片角标): 红色待办 + 黄色进行中两个数。
//
// 口径 = 待本部门动手的采购任务单据数：申请待分解（WAITING_ORDER）+ 财务驳回
// （FINANCE_REJECTED）。「等待财务审核 / 财务已通过」下一步在别人手上，属监控数，
// 2026-09-11 起从红徽章合计中剔除（后端 FulfillmentWorkbenchQueryService.countPending）。
// 默认 60s 轮询；有任一采购查看权限才拉取，否则返回 0（不渲染徽章）。
// 范式同 lib/features/production/providers/production_pending_provider.dart（生产待排产徽章）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';

const Duration _kPurchaseTaskPollInterval = Duration(seconds: 60);

/// 采购任务中心待办单据数（申请待分解 + 财务驳回，按单据去重）。
///
/// 有任一采购查看权限时 60s 轮询；其它角色返回 0。count 为 0 时徽章不渲染。
final purchaseTaskCountProvider =
    StateNotifierProvider<PurchaseTaskCountNotifier, int>((ref) {
      // 新登录会话从零重建并立即重拉（见 shared/auth/session_epoch_provider.dart）。
      ref.watch(sessionEpochProvider);
      final notifier = PurchaseTaskCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class PurchaseTaskCountNotifier extends StateNotifier<int> {
  PurchaseTaskCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kPurchaseTaskPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.purchaseRequestView) ||
        perms.contains(Perm.purchaseOrderView) ||
        perms.contains(Perm.purchaseReceiptView) ||
        perms.contains(Perm.purchaseReturnView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final count = await ref
          .read(operationsWorkbenchRepositoryProvider)
          .purchaseTaskCount();
      if (mounted) state = count; // 会话重建后旧实例已释放，丢弃迟到结果
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（确认计划包 / 生成采购申请 / 到货后调用）。
  Future<void> refresh() => _tick();
}

/// 采购任务中心「进行中」任务行数(等待财务审核 + 财务已通过 + 财务驳回)。
///
/// ADR-100 的黄色那条链: 这批单已经在财务/供应商手上跑着、还没完, 但现在不用
/// 采购动手, 所以不进红徽章, 走 in_progress_badge_registry 单独上卷。与红色那个
/// notifier 同款自卫: 无采购查看权限返回 0 且不发请求、会话重建清零重拉、
/// 异常保留旧值(避免 60s 轮询把徽章打回 0 再弹回来)。
final purchaseTaskInProgressCountProvider =
    StateNotifierProvider<PurchaseTaskInProgressCountNotifier, int>((ref) {
      ref.watch(sessionEpochProvider);
      final notifier = PurchaseTaskInProgressCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class PurchaseTaskInProgressCountNotifier extends StateNotifier<int> {
  PurchaseTaskInProgressCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;
  bool _stopped = false;

  void start() {
    _tick();
    _timer = Timer.periodic(_kPurchaseTaskPollInterval, (_) => _tick());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_stopped) return;
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        perms.contains(Perm.purchaseRequestView) ||
        perms.contains(Perm.purchaseOrderView) ||
        perms.contains(Perm.purchaseReceiptView) ||
        perms.contains(Perm.purchaseReturnView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final counts = await ref
          .read(operationsWorkbenchRepositoryProvider)
          .purchaseTaskCounts();
      if (mounted && !_stopped) state = counts.inProgress;
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新(生成订货单 / 财务审批结果回来后调用)。
  Future<void> refresh() => _tick();
}
