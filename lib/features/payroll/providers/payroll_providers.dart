import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../models/payroll_batch.dart';
import '../models/payroll_slip.dart';
import '../repositories/payroll_repository.dart';

enum PayrollFilter { all, published, viewed, downloaded }

extension PayrollFilterValue on PayrollFilter {
  String get label => switch (this) {
    PayrollFilter.all => '全部',
    PayrollFilter.published => '未查看',
    PayrollFilter.viewed => '已查看',
    PayrollFilter.downloaded => '已下载',
  };

  String get apiStatus => switch (this) {
    PayrollFilter.all => 'PUBLISHED',
    PayrollFilter.published => 'UNVIEWED',
    PayrollFilter.viewed => 'VIEWED',
    PayrollFilter.downloaded => 'DOWNLOADED',
  };
}

final payrollFilterProvider = StateProvider<PayrollFilter>(
  (ref) => PayrollFilter.all,
);

final payrollListProvider =
    AsyncNotifierProvider.autoDispose<
      PayrollListNotifier,
      PagedResult<PayrollSlip>
    >(PayrollListNotifier.new);

class PayrollListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<PayrollSlip>> {
  @override
  Future<PagedResult<PayrollSlip>> build() async {
    final filter = ref.watch(payrollFilterProvider);
    return ref
        .watch(payrollRepositoryProvider)
        .listSlips(status: filter.apiStatus);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _fetch(1));
  }

  Future<void> previousPage() async {
    final current = state.valueOrNull;
    if (current == null || current.page <= 1) return;
    await _goTo(current.page - 1);
  }

  Future<void> nextPage() async {
    final current = state.valueOrNull;
    if (current == null || current.page >= current.totalPages) return;
    await _goTo(current.page + 1);
  }

  Future<void> _goTo(int page) async {
    if (state.isLoading) return;
    state = const AsyncLoading<PagedResult<PayrollSlip>>().copyWithPrevious(
      state,
    );
    state = await AsyncValue.guard(() => _fetch(page));
  }

  Future<PagedResult<PayrollSlip>> _fetch(int page) {
    final filter = ref.read(payrollFilterProvider);
    return ref
        .read(payrollRepositoryProvider)
        .listSlips(status: filter.apiStatus, page: page);
  }
}

final payrollDetailProvider = FutureProvider.autoDispose
    .family<PayrollSlip, String>((ref, id) {
      return ref.watch(payrollRepositoryProvider).getSlip(id);
    });

Future<void> markPayrollViewed(WidgetRef ref, String id) async {
  await ref.read(payrollRepositoryProvider).markViewed(id);
  ref.invalidate(payrollDetailProvider(id));
  ref.invalidate(payrollListProvider);
}

Future<Uint8List> downloadPayrollSlip(WidgetRef ref, String id) async {
  final bytes = await ref.read(payrollRepositoryProvider).downloadSlip(id);
  ref.invalidate(payrollDetailProvider(id));
  ref.invalidate(payrollListProvider);
  return bytes;
}

final payrollDepartmentOptionsProvider =
    FutureProvider.autoDispose<List<PayrollDepartmentOption>>((ref) {
      return ref.watch(payrollRepositoryProvider).listDepartmentOptions();
    });

final payrollBatchListProvider =
    AsyncNotifierProvider.autoDispose<
      PayrollBatchListNotifier,
      PagedResult<PayrollBatch>
    >(PayrollBatchListNotifier.new);

class PayrollBatchListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<PayrollBatch>> {
  @override
  Future<PagedResult<PayrollBatch>> build() =>
      ref.watch(payrollRepositoryProvider).listBatches();

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(payrollRepositoryProvider).listBatches(),
    );
  }

  Future<void> previousPage() async {
    final current = state.valueOrNull;
    if (current == null || current.page <= 1) return;
    await _goTo(current.page - 1);
  }

  Future<void> nextPage() async {
    final current = state.valueOrNull;
    if (current == null || current.page >= current.totalPages) return;
    await _goTo(current.page + 1);
  }

  Future<void> _goTo(int page) async {
    if (state.isLoading) return;
    state = const AsyncLoading<PagedResult<PayrollBatch>>().copyWithPrevious(
      state,
    );
    state = await AsyncValue.guard(
      () => ref.read(payrollRepositoryProvider).listBatches(page: page),
    );
  }
}

final payrollBatchDetailProvider = FutureProvider.autoDispose
    .family<PayrollBatch, String>((ref, id) {
      return ref.watch(payrollRepositoryProvider).getBatch(id);
    });

Future<PayrollBatch> createPayrollBatch(
  WidgetRef ref,
  PayrollBatchCreateInput input,
) async {
  final batch = await ref.read(payrollRepositoryProvider).createBatch(input);
  ref.invalidate(payrollBatchListProvider);
  return batch;
}

Future<void> submitPayrollBatch(WidgetRef ref, String id) async {
  await ref.read(payrollRepositoryProvider).submitBatch(id);
  _invalidateBatch(ref, id);
}

Future<void> approvePayrollBatch(WidgetRef ref, String id) async {
  await ref.read(payrollRepositoryProvider).approveBatch(id);
  _invalidateBatch(ref, id);
}

Future<void> rejectPayrollBatch(WidgetRef ref, String id, String reason) async {
  await ref.read(payrollRepositoryProvider).rejectBatch(id, reason);
  _invalidateBatch(ref, id);
}

Future<void> publishPayrollBatch(WidgetRef ref, String id) async {
  await ref.read(payrollRepositoryProvider).publishBatch(id);
  _invalidateBatch(ref, id);
  ref.invalidate(payrollListProvider);
}

void _invalidateBatch(WidgetRef ref, String id) {
  ref.invalidate(payrollBatchListProvider);
  ref.invalidate(payrollBatchDetailProvider(id));
}
