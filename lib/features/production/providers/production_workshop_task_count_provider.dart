import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../repositories/production_execution_workbench_repository.dart';

const _pollInterval = Duration(seconds: 60);

/// 车间任务分段计数（与顶部分类互斥口径一致）：总数 + 备料中 + 可报工 +
/// 已报工跟进。总徽章消费者读 `total`，页面分类徽章读分段值。
final productionWorkshopTaskCountProvider =
    StateNotifierProvider<
      ProductionWorkshopTaskCountNotifier,
      WorkshopTaskCountBreakdown
    >((ref) {
      // Counts belong to the effective account and actor, not the app process.
      ref.watch(
        sessionProvider.select(
          (session) => (
            session.status,
            session.user?.id,
            session.actor?.id,
            session.impersonationReadOnly,
          ),
        ),
      );
      ref.watch(
        currentPermissionsProvider.select(
          (permissions) => permissions.contains(Perm.productionExecutionView),
        ),
      );
      ref.watch(isSuperAdminProvider);
      ref.watch(productionExecutionWorkbenchRepositoryProvider);
      final notifier = ProductionWorkshopTaskCountNotifier(ref)..start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class ProductionWorkshopTaskCountNotifier
    extends StateNotifier<WorkshopTaskCountBreakdown> {
  ProductionWorkshopTaskCountNotifier(this.ref)
    : super(const WorkshopTaskCountBreakdown());

  final Ref ref;
  Timer? _timer;
  int _requestGeneration = 0;
  bool _stopped = false;

  void start() {
    if (_stopped || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(refresh()));
  }

  void stop() {
    _stopped = true;
    _requestGeneration++;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (_stopped || !mounted) return;
    final generation = ++_requestGeneration;
    final allowed =
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.productionExecutionView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      _publish(const WorkshopTaskCountBreakdown());
      return;
    }
    try {
      final breakdown = await ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .workshopTaskCount();
      if (_stopped || !mounted || generation != _requestGeneration) return;
      _publish(breakdown);
    } catch (_) {
      // Keep only this identity's last confirmed count on a transient failure.
      // A new identity/permission scope owns a new notifier initialized at zero.
    }
  }

  /// 2026-09-11 重建风暴收口：StateNotifier 默认 `updateShouldNotify` 用
  /// `!identical`，而 60s 轮询每次都 new 一个快照——计数一个都没变也会把
  /// 「我的车间任务」整页重建。这里按值比较，只有真变了才写 state。
  void _publish(WorkshopTaskCountBreakdown next) {
    if (next == state) return;
    state = next;
  }
}
