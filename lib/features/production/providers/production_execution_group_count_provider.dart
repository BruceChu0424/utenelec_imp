import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../repositories/production_execution_workbench_repository.dart';

const _pollInterval = Duration(seconds: 60);

/// 生产调度与进度页「进行中」大类行的批次计数(N = 进行中的最外层分析/根计划
/// 批次数，与进行中列表同源)。
///
/// 无 `production_execution:overview` 权限(含从 /production/schedule 深链进入的
/// 纯调度账号)时不发请求、返回 null——未知不伪装成 0，徽章同样不渲染。
/// 进行中列表每次加载完成后由面板 invalidate 本 provider 保持数字新鲜。
final productionExecutionGroupCountProvider = FutureProvider.autoDispose<int?>((
  ref,
) async {
  if (!ref
      .watch(currentPermissionsProvider)
      .contains(Perm.productionExecutionOverview)) {
    return null;
  }
  return ref.watch(productionExecutionWorkbenchRepositoryProvider).groupCount();
});

/// 「生产管理」卡与工作台的在办批次数(黄色进行中徽章的累加入口，ADR-100)。
///
/// 与上面那支页面自用的 provider 同一个数、同一个端点，区别只在生命周期：
/// 页面那支 autoDispose，离开页面即销毁；本支**常驻**并自带 60s 轮询，因为
/// 卡片角标要「点进去就有」而不是等一次加载(准则 §四之三)。
/// 读不到(无权限/请求失败)时保留本身份上一次确认过的数，不清零。
final productionExecutionInProgressCountProvider =
    StateNotifierProvider<ProductionExecutionInProgressCountNotifier, int>((
      ref,
    ) {
      // 计数属于当前生效的账号与操作者，不属于 app 进程：切账号 / 代操作后
      // 释放旧实例(连同它的定时器与迟到响应)，新身份从 0 起重建。
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
          (permissions) =>
              permissions.contains(Perm.productionExecutionOverview),
        ),
      );
      ref.watch(isSuperAdminProvider);
      ref.watch(productionExecutionWorkbenchRepositoryProvider);
      final notifier = ProductionExecutionInProgressCountNotifier(ref)..start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class ProductionExecutionInProgressCountNotifier extends StateNotifier<int> {
  ProductionExecutionInProgressCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;
  bool _stopped = false;

  void start() {
    if (_stopped || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(refresh()));
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (_stopped || !mounted) return;
    final allowed =
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.productionExecutionOverview) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      final count = await ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .groupCount();
      if (_stopped || !mounted) return;
      state = count;
    } catch (_) {
      // 网络/服务异常保留本身份上一次确认过的数，避免徽章闪一下再回来。
      // 新身份/新权限范围由 provider 重建，拿到的是从零开始的新实例。
    }
  }
}
