// HR 工作台共享数据：summary 一次加载，工作台主页与各子页面共用；
// 快捷操作（转正/认领/释放/接管）成功后调用 refresh() 重算，并同步工作台徽标。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hr_task_summary.dart';
import '../repositories/hr_task_repository.dart';
import 'hr_task_count_provider.dart';

final hrTaskSummaryProvider =
    AsyncNotifierProvider<HrTaskSummaryNotifier, HrTaskSummary>(
      HrTaskSummaryNotifier.new,
    );

class HrTaskSummaryNotifier extends AsyncNotifier<HrTaskSummary> {
  @override
  Future<HrTaskSummary> build() =>
      ref.watch(hrTaskRepositoryProvider).summary();

  /// 重新加载并同步工作台徽标计数。
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(hrTaskRepositoryProvider).summary(),
    );
    await ref.read(hrTaskCountProvider.notifier).refresh();
  }

  /// 静默重取（保操作后不打断页面结构）。
  Future<void> reloadSilently() async {
    final next = await AsyncValue.guard(
      () => ref.read(hrTaskRepositoryProvider).summary(),
    );
    if (next.hasValue) state = next;
    await ref.read(hrTaskCountProvider.notifier).refresh();
  }
}
