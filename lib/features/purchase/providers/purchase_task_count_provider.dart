// 采购任务中心待办任务计数（工作台「采购管理」卡片徽标）。
//
// 口径 = 计划已下达且仍有未分解数量的申请明细（WAITING_ORDER）。
// 默认 60s 轮询；有任一采购查看权限才拉取，否则返回 0（不渲染徽章）。
// 范式同 lib/features/production/providers/production_pending_provider.dart（生产待排产徽章）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';

const Duration _kPurchaseTaskPollInterval = Duration(seconds: 60);

/// 采购任务中心待分解申请明细数（WAITING_ORDER 行数）。
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
