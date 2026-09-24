// HR 工作台共享数据：summary 一次加载，工作台主页与各子页面共用；
// 快捷操作（转正/认领/释放/接管）成功后调用 refresh() 重算，并同步工作台徽标。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hr_task_summary.dart';
import '../repositories/hr_task_repository.dart';
import '../../../core/network/data_write_revision.dart';
import '../../../shared/badges/badge_registry.dart';

final hrTaskSummaryProvider =
    AsyncNotifierProvider<HrTaskSummaryNotifier, HrTaskSummary>(
      HrTaskSummaryNotifier.new,
    );

class HrTaskSummaryNotifier extends AsyncNotifier<HrTaskSummary> {
  /// 员工档案页的转正/复聘/离职办结会改变 HR 任务口径（待转正少一条、生日/周年
  /// 队列换人）。employee 模块不 import 本模块（架构边界测试锁方向），统一走
  /// 网络层写路径通道：这三个端点成功写入后静默重算（与徽章汇总的写后补拉同款）。
  static final _employeeLifecycleWrites = RegExp(
    r'^/org/employees/[^/]+/(confirm|rehire|offboard|onboard)$',
  );

  @override
  Future<HrTaskSummary> build() {
    ref.listen<({int seq, String path})?>(lastDataWriteProvider, (
      previous,
      next,
    ) {
      if (next == null || next.seq == previous?.seq) return;
      if (!_employeeLifecycleWrites.hasMatch(next.path)) return;
      unawaited(reloadSilently());
    });
    return ref.watch(hrTaskRepositoryProvider).summary();
  }

  /// 重新加载并同步工作台徽标计数。
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(hrTaskRepositoryProvider).summary(),
    );
    await ref.read(badgeSummaryProvider.notifier).refresh();
  }

  /// 静默重取（保操作后不打断页面结构）。
  Future<void> reloadSilently() async {
    final next = await AsyncValue.guard(
      () => ref.read(hrTaskRepositoryProvider).summary(),
    );
    if (next.hasValue) state = next;
    await ref.read(badgeSummaryProvider.notifier).refresh();
  }
}
