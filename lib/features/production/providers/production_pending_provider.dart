// 生产部待排产数量 Provider（工作台「生产管理」卡片红色数字徽章用）。
//
// 口径 = 调度工作台待排产行数（已审订单行 qty − 预留 − 已排产 > 0），
// 后端 GET /production/schedule/pending-count 返回 {count, urgent}。
// 默认 60s 轮询一次；无 production_plan:view 权限时返回 0（不渲染徽章）。
// 范式同 lib/shared/auth/pending_review_provider.dart（HR 待办徽章）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/production_repository.dart';

const Duration _kPendingPollInterval = Duration(seconds: 60);

/// 生产待排产计数（count=待排产行数，urgent=其中 ≤3 天/已逾期行数）。
class ProductionPendingCount {
  const ProductionPendingCount(this.count, this.urgent);
  final int count;
  final int urgent;
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
      state = ProductionPendingCount(r['count'] ?? 0, r['urgent'] ?? 0);
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（排产 / 审核动作完成后调用）。
  Future<void> refresh() => _tick();
}
