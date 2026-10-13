// HR 工作台共享数据：summary 一次加载，工作台主页与各子页面共用；
// 快捷操作（转正/认领/释放/接管）成功后调用 refresh() 重算，并同步工作台徽标。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hr_task_summary.dart';
import '../repositories/hr_task_repository.dart';
import '../../../core/network/data_write_revision.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;

final hrTaskSummaryProvider =
    AsyncNotifierProvider<HrTaskSummaryNotifier, HrTaskSummary>(
      HrTaskSummaryNotifier.new,
    );

class HrTaskSummaryNotifier extends AsyncNotifier<HrTaskSummary> {
  int _requestGeneration = 0;
  Future<HrTaskSummary>? _latestRead;
  bool _latestReadSilent = false;

  /// 员工档案页的转正/复聘/离职办结会改变 HR 任务口径（待转正少一条、生日/周年
  /// 队列换人)；修改证件信息会让证件核对少一条。employee 模块不 import 本模块
  /// (架构边界测试锁方向)，统一走网络层写路径通道：这些端点成功写入后静默重算
  /// (与徽章汇总的写后补拉同款)。
  static final _employeeLifecycleWrites = RegExp(
    r'^/org/employees/[^/]+/(confirm|rehire|offboard|onboard|change-identity)$',
  );

  /// 核对更正页(ADR-160)提交核对计划：apply 会改员工证件/档案数据，证件核对
  /// 队列随之变化，同样静默重算。
  static final _employeeReconcileApplyWrites = RegExp(
    r'^/org/employee-reconcile/plans/[^/]+/apply$',
  );

  @override
  Future<HrTaskSummary> build() {
    final generation = ++_requestGeneration;
    var active = true;
    void clearIdentity() {
      _requestGeneration++;
      state = const AsyncLoading();
      ref.invalidateSelf();
    }

    // API client/repository remain stable across login and impersonation. HR
    // rows include identity-dependent claims and permission-scoped PII tasks.
    ref.listen(masterDataSessionKeyProvider, (previous, next) {
      if (previous != next) clearIdentity();
    });
    ref.listen(authenticatedScopeProvider, (previous, next) {
      if (previous != next) clearIdentity();
    });
    ref.onDispose(() {
      active = false;
      _requestGeneration++;
    });
    ref.listen<({int seq, String path})?>(lastDataWriteProvider, (
      previous,
      next,
    ) {
      if (next == null || next.seq == previous?.seq) return;
      final businessWrite =
          _employeeLifecycleWrites.hasMatch(next.path) ||
          _employeeReconcileApplyWrites.hasMatch(next.path);
      if (!businessWrite) return;
      unawaited(reloadSilently());
    });
    final pending = _startRead(ref.watch(hrTaskRepositoryProvider));
    // Riverpod commits build's Future automatically. If an explicit refresh
    // supersedes startup, build must resolve the latest read too.
    return _readUntilCurrent(generation, pending, () => active);
  }

  Future<HrTaskSummary> _startRead(
    HrTaskRepository repository, {
    bool silent = false,
  }) {
    _latestReadSilent = silent;
    return _latestRead = repository.summary();
  }

  Future<HrTaskSummary> _readUntilCurrent(
    int generation,
    Future<HrTaskSummary> pending,
    bool Function() active,
  ) async {
    var silent = false;
    while (true) {
      try {
        final value = await pending;
        if (!active() || generation == _requestGeneration) return value;
      } catch (error, stack) {
        if (!active() || generation == _requestGeneration) {
          if (active() && silent) {
            final accepted = state;
            if (!accepted.isLoading &&
                accepted.hasValue &&
                !accepted.hasError) {
              return accepted.requireValue;
            }
            if (accepted.hasError) {
              Error.throwWithStackTrace(
                accepted.error!,
                accepted.stackTrace ?? stack,
              );
            }
          }
          Error.throwWithStackTrace(error, stack);
        }
      }
      generation = _requestGeneration;
      pending = _latestRead!;
      silent = _latestReadSilent;
    }
  }

  /// 重新加载并同步工作台徽标计数。
  Future<void> refresh() async {
    final generation = ++_requestGeneration;
    final repository = ref.read(hrTaskRepositoryProvider);
    state = const AsyncLoading();
    final next = await AsyncValue.guard(() => _startRead(repository));
    if (generation != _requestGeneration) return;
    state = next;
    await ref.read(badgeSummaryProvider.notifier).refresh();
  }

  /// 静默重取（保操作后不打断页面结构）。
  Future<void> reloadSilently() async {
    final generation = ++_requestGeneration;
    final repository = ref.read(hrTaskRepositoryProvider);
    final next = await AsyncValue.guard(
      () => _startRead(repository, silent: true),
    );
    if (generation != _requestGeneration) return;
    if (next.hasValue) state = next;
    await ref.read(badgeSummaryProvider.notifier).refresh();
  }
}
