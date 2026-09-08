import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
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
  int _page = 1;
  PayrollFilter? _lastFilter;

  @override
  Future<PagedResult<PayrollSlip>> build() async {
    ref.listen(masterDataSessionKeyProvider, (previous, next) {
      if (previous == next) return;
      _page = 1;
      state = const AsyncLoading();
      ref.invalidateSelf();
    });
    final filter = ref.watch(payrollFilterProvider);
    if (_lastFilter != filter) _page = 1;
    _lastFilter = filter;
    return ref
        .watch(payrollRepositoryProvider)
        .listSlips(status: filter.apiStatus, page: _page);
  }

  Future<void> refresh() => _reloadPage(1);

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
    await _reloadPage(page);
  }

  Future<void> _reloadPage(int page) async {
    _page = page;
    state = const AsyncLoading();
    // Keep every request inside build: Riverpod discards replaced build futures.
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {
      // The current error is exposed in provider state, as before.
    }
  }
}

final payrollDetailProvider = FutureProvider.autoDispose
    .family<PayrollSlip, String>((ref, id) {
      ref.watch(masterDataSessionKeyProvider);
      return ref.watch(payrollRepositoryProvider).getSlip(id);
    });

Future<void> markPayrollViewed(WidgetRef ref, String id) async {
  await ref.read(payrollRepositoryProvider).markViewed(id);
  // The detail GET already returned the page the user is reading. Reloading it
  // here would create a second synthetic view and duplicate the audit event.
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
