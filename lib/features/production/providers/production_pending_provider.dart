// 生产部待排产数量 Provider（工作台「生产管理」卡片红色数字徽章用）。
//
// 口径 = 调度工作台待排产行数（已审订单行 qty − 预留 − 已排产 > 0），
// 后端 GET /production/schedule/pending-count 返回 {count, urgent, overdue}。
// 默认 60s 轮询一次；无 production_plan:view 权限时返回 0（不渲染徽章）。
// 范式同 lib/shared/auth/pending_review_provider.dart（HR 待办徽章）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/production_repository.dart';

const Duration _kPendingPollInterval = Duration(seconds: 60);

/// 生产待排产计数（count=待排产行数，urgent=其中 ≤3 天/含逾期行数，overdue=已逾期行数）。
class ProductionPendingCount {
  const ProductionPendingCount(this.count, this.urgent, [this.overdue = 0]);
  final int count;
  final int urgent;
  final int overdue;
}

/// 有 production_plan:view 权限时 60s 轮询待排产数；其它角色返回 0。
/// count 为 0 时徽章不渲染。
final productionPendingCountProvider =
    StateNotifierProvider<ProductionPendingCountNotifier, ProductionPendingCount>(
  (ref) {
    final notifier = ProductionPendingCountNotifier(ref);
    notifier.start();
    ref.onDispose(notifier.stop);
    return notifier;
  },
);

class ProductionPendingCountNotifier
    extends StateNotifier<ProductionPendingCount> {
  ProductionPendingCountNotifier(this.ref)
      : super(const ProductionPendingCount(0, 0));

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kPendingPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    // 仅在有生产计划查看权限时拉取；普通用户静默返回 0。
    final allowed =
        ref.read(currentPermissionsProvider).contains(Perm.productionPlanView) ||
            ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = const ProductionPendingCount(0, 0);
      return;
    }
    try {
      final r =
          await ref.read(productionPlanRepositoryProvider).schedulePendingCount();
      state = ProductionPendingCount(
          r['count'] ?? 0, r['urgent'] ?? 0, r['overdue'] ?? 0);
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（排产 / 审核动作完成后调用）。
  Future<void> refresh() => _tick();
}

/// PMC 缺料待备料计数（采购管理卡片徽标）：计划已审但 BOM 净需求不足的订单行数。
/// 有 生产计划查看 或 采购申请查看 权限时 60s 轮询；其它角色返回 0。
final pmcShortageCountProvider =
    StateNotifierProvider<PmcShortageCountNotifier, int>(
  (ref) {
    final notifier = PmcShortageCountNotifier(ref);
    notifier.start();
    ref.onDispose(notifier.stop);
    return notifier;
  },
);

class PmcShortageCountNotifier extends StateNotifier<int> {
  PmcShortageCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kPendingPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final perms = ref.read(currentPermissionsProvider);
    final allowed = perms.contains(Perm.productionPlanView) ||
        perms.contains(Perm.purchaseRequestView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final r = await ref
          .read(productionPlanRepositoryProvider)
          .scheduleShortageCount();
      state = r['count'] ?? 0;
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（生成采购申请 / 到货后调用）。
  Future<void> refresh() => _tick();
}
