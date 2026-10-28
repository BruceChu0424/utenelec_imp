import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/legacy.dart';

import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../models/payroll_batch.dart';
import '../models/payroll_slip.dart';
import '../repositories/payroll_repository.dart';

// Riverpod 3 将 copyWithPrevious 标记为 @internal；跨 family 实例手动保页/保旧值是既有架构，等上游公开等价 API 后再迁移。
// ignore_for_file: invalid_use_of_internal_member

enum PayrollFilter { published, viewed, viewedOnly, downloaded }

extension PayrollFilterValue on PayrollFilter {
  String get label => switch (this) {
    PayrollFilter.published => '未查看',
    PayrollFilter.viewed => '已查看',
    PayrollFilter.viewedOnly => '已查看未下载',
    PayrollFilter.downloaded => '已下载',
  };

  String get apiStatus => switch (this) {
    PayrollFilter.published => 'UNVIEWED',
    PayrollFilter.viewed => 'VIEWED',
    PayrollFilter.viewedOnly => 'VIEWED_ONLY',
    PayrollFilter.downloaded => 'DOWNLOADED',
  };

  /// 下载也是已查看；表头细筛不增加一个独立的顶部分类。
  PayrollFilter get category => this == PayrollFilter.published
      ? PayrollFilter.published
      : PayrollFilter.viewed;
}

final payrollFilterProvider = StateProvider<PayrollFilter>(
  (ref) => PayrollFilter.published,
);

class PayrollHeaderQuery {
  PayrollHeaderQuery({
    Map<String, String> searches = const {},
    this.sort,
    this.ascending = true,
  }) : searches = Map.unmodifiable(searches);
  final Map<String, String> searches;
  final String? sort;
  final bool ascending;
  PayrollHeaderQuery withSearch(String key, String? value) {
    final next = Map<String, String>.of(searches);
    if (value == null || value.trim().isEmpty) {
      next.remove(key);
    } else {
      next[key] = value.trim();
    }
    return PayrollHeaderQuery(searches: next, sort: sort, ascending: ascending);
  }

  PayrollHeaderQuery sorted(String? column, bool ascending) =>
      PayrollHeaderQuery(
        searches: searches,
        sort: column,
        ascending: ascending,
      );
  @override
  bool operator ==(Object other) =>
      other is PayrollHeaderQuery &&
      other.sort == sort &&
      other.ascending == ascending &&
      mapEquals(other.searches, searches);
  @override
  int get hashCode => Object.hash(
    sort,
    ascending,
    Object.hashAll(
      (searches.keys.toList()..sort()).map(
        (key) => Object.hash(key, searches[key]),
      ),
    ),
  );
}

final payrollHeaderQueryProvider =
    StateProvider.autoDispose<PayrollHeaderQuery>(
      (ref) => PayrollHeaderQuery(),
    );

final payrollListProvider =
    AsyncNotifierProvider.autoDispose<
      PayrollListNotifier,
      PagedResult<PayrollSlip>
    >(
      PayrollListNotifier.new,
      retry: pagedReadProviderRetry,
      dependencies: [
        _payrollReads,
        payrollRepositoryProvider,
        payrollFilterProvider,
        payrollHeaderQueryProvider,
        masterDataSessionKeyProvider,
      ],
    );

final _payrollReads = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<PayrollSlip>, Object>((ref, query) {
      ref.watch(payrollRepositoryProvider);
      return ScopedPagedReadProviderLease(ref, query: query);
    }, dependencies: [exportContextEpochProvider, payrollRepositoryProvider]);

class PayrollListNotifier extends AsyncNotifier<PagedResult<PayrollSlip>> {
  int _page = 1;
  int? _requestedPage;
  int? Function()? _visiblePage;
  Object? _lastQuery;

  Object get _readQuery =>
      (ref.read(payrollFilterProvider), ref.read(payrollHeaderQueryProvider));
  ScopedPagedReadProviderLease<PayrollSlip> get _reader =>
      ref.read(_payrollReads(_readQuery));
  void bindReadView(BuildContext context, {int? Function()? visiblePage}) {
    _visiblePage = visiblePage;
    _reader.bindView(context, currentQuery: () => _readQuery);
  }

  @override
  Future<PagedResult<PayrollSlip>> build() async {
    ref.listen(masterDataSessionKeyProvider, (previous, next) {
      if (previous == next) return;
      _page = 1;
      _requestedPage = 1;
      state = const AsyncLoading();
      ref.invalidateSelf();
    });
    final filter = ref.watch(payrollFilterProvider);
    final headers = ref.watch(payrollHeaderQueryProvider);
    final query = (filter, headers);
    final requestedPage = _requestedPage;
    _requestedPage = null;
    _page = _lastQuery != query
        ? 1
        : (requestedPage ?? _visiblePage?.call() ?? _page);
    _lastQuery = query;
    final repository = ref.watch(payrollRepositoryProvider);
    final reader = ref.watch(_payrollReads(_readQuery));
    return reader.read(
      _page,
      fetchPage: (page) => repository.listSlips(
        status: filter.apiStatus,
        page: page,
        columnSearch: headers.searches,
        sort: headers.sort,
        order: headers.ascending ? 'asc' : 'desc',
      ),
    );
  }

  Future<void> refresh() {
    _reader.invalidate();
    return _reloadPage(_visiblePage?.call() ?? _page);
  }

  Future<void> retry() {
    _reader.invalidate();
    return _reloadPage(_page);
  }

  Future<void> previousPage() async {
    final current = state.value;
    final page = _visiblePage?.call() ?? current?.page ?? 1;
    if (current == null || page <= 1) return;
    await _goTo(page - 1);
  }

  Future<void> nextPage() async {
    final current = state.value;
    final page = _visiblePage?.call() ?? current?.page ?? 1;
    if (current == null || page >= current.totalPages) return;
    await _goTo(page + 1);
  }

  /// 直接拉目标页（2026-09-09 工资条列表表格化：表格内置翻页条含跳页输入）。
  Future<void> goToPage(int page) async {
    final current = state.value;
    if (current == null) return;
    if (page < 1 ||
        page == (_visiblePage?.call() ?? current.page) ||
        page > current.totalPages) {
      return;
    }
    await _goTo(page);
  }

  Future<void> _goTo(int page) async {
    if (state.isLoading) return;
    await _reader.paginate(page, () => _reloadPage(page));
  }

  Future<void> _reloadPage(int page) async {
    _page = page;
    _requestedPage = page;
    state = const AsyncLoading<PagedResult<PayrollSlip>>().copyWithPrevious(
      state,
    );
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

enum PayrollBatchScope { active, history }

final payrollBatchScopeProvider = StateProvider.autoDispose<PayrollBatchScope>(
  (ref) => PayrollBatchScope.active,
);

final payrollBatchListProvider =
    AsyncNotifierProvider.autoDispose<
      PayrollBatchListNotifier,
      PagedResult<PayrollBatch>
    >(PayrollBatchListNotifier.new);

class PayrollBatchListNotifier
    extends AsyncNotifier<PagedResult<PayrollBatch>> {
  int _page = 1;
  PayrollBatchScope? _lastScope;

  @override
  Future<PagedResult<PayrollBatch>> build() {
    ref.listen(masterDataSessionKeyProvider, (previous, next) {
      if (previous == next) return;
      _page = 1;
      state = const AsyncLoading();
      ref.invalidateSelf();
    });
    final scope = ref.watch(payrollBatchScopeProvider);
    if (_lastScope != scope) _page = 1;
    _lastScope = scope;
    return ref
        .watch(payrollRepositoryProvider)
        .listBatches(
          status: scope == PayrollBatchScope.history ? 'HISTORY' : 'ACTIVE',
          page: _page,
        );
  }

  Future<void> refresh() => _reloadPage(1);

  Future<void> previousPage() async {
    final current = state.value;
    if (current == null || current.page <= 1) return;
    await _goTo(current.page - 1);
  }

  Future<void> nextPage() async {
    final current = state.value;
    if (current == null || current.page >= current.totalPages) return;
    await _goTo(current.page + 1);
  }

  Future<void> goToPage(int page) async {
    final current = state.value;
    if (current == null ||
        page < 1 ||
        page > current.totalPages ||
        page == current.page) {
      return;
    }
    await _goTo(page);
  }

  Future<void> _goTo(int page) async {
    if (state.isLoading) return;
    await _reloadPage(page);
  }

  Future<void> _reloadPage(int page) async {
    _page = page;
    state = const AsyncLoading<PagedResult<PayrollBatch>>().copyWithPrevious(
      state,
    );
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {
      /* Error remains visible in provider state. */
    }
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
