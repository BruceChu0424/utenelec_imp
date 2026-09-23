// 委外任务中心红色待办与黄色进行中共用一次 count 响应、一个 60s 轮询。
// 两枚徽章是同一服务端快照的不同字段，不能各自轮询同一个端点。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../operations_workbench/repositories/operations_workbench_repository.dart';

const Duration _kSubcontractTaskPollInterval = Duration(seconds: 60);
typedef SubcontractTaskCounts = ({int pending, int inProgress});

/// 两个计数的唯一加载源；新会话/权限变化从零重建，旧请求不得回写新会话。
final subcontractTaskCountsProvider =
    StateNotifierProvider<SubcontractTaskCountsNotifier, SubcontractTaskCounts>(
      (ref) {
        ref.watch(sessionEpochProvider);
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(currentPermissionsProvider);
        ref.watch(isSuperAdminProvider);
        final notifier = SubcontractTaskCountsNotifier(ref);
        notifier.start();
        ref.onDispose(notifier.stop);
        return notifier;
      },
    );

/// 待办数只取服务端 pending，不按当前分页行数推算。
final subcontractTaskCountProvider = Provider<int>(
  (ref) =>
      ref.watch(subcontractTaskCountsProvider.select((value) => value.pending)),
);

/// 黄色在办数与红色待办数同时更新；双方仍按各自注册表独立累加。
final subcontractTaskInProgressCountProvider = Provider<int>(
  (ref) => ref.watch(
    subcontractTaskCountsProvider.select((value) => value.inProgress),
  ),
);

class SubcontractTaskCountsNotifier
    extends StateNotifier<SubcontractTaskCounts> {
  SubcontractTaskCountsNotifier(this.ref) : super((pending: 0, inProgress: 0));

  final Ref ref;
  Timer? _timer;
  bool _stopped = false;
  Future<void>? _inFlight;

  void start() {
    refresh();
    _timer = Timer.periodic(_kSubcontractTaskPollInterval, (_) => refresh());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// 返回页面、通知或业务操作共用刷新入口；并发刷新等待同一次请求。
  Future<void> refresh() {
    if (_stopped) return Future.value();
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    final permissions = ref.read(currentPermissionsProvider);
    final allowed =
        permissions.contains(Perm.subcontractApplicationView) ||
        permissions.contains(Perm.subcontractOrderView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = (pending: 0, inProgress: 0);
      return;
    }
    try {
      final counts = await ref
          .read(operationsWorkbenchRepositoryProvider)
          .subcontractTaskCounts();
      if (!_stopped) state = counts;
    } catch (_) {
      // 网络/服务异常时保留完整旧快照，避免两枚徽章先后闪烁或来自不同时点。
    }
  }
}
