import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../basic_data/models/account_node.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/models/payment_style_node.dart';
import '../../basic_data/repositories/account_repository.dart';
import '../../basic_data/repositories/payment_style_repository.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../models/expense_payment.dart';
import '../repositories/expense_repository.dart';

enum ExpenseFilter { all, draft, processing, finished }

extension ExpenseFilterValue on ExpenseFilter {
  String get label => switch (this) {
    ExpenseFilter.all => '全部',
    ExpenseFilter.draft => '草稿',
    ExpenseFilter.processing => '处理中',
    ExpenseFilter.finished => '已完成',
  };

  Iterable<ExpenseClaimStatus>? get apiStatuses => switch (this) {
    ExpenseFilter.all => null,
    ExpenseFilter.draft => const [ExpenseClaimStatus.draft],
    ExpenseFilter.processing => const [
      ExpenseClaimStatus.submitted,
      ExpenseClaimStatus.reviewing,
      ExpenseClaimStatus.approved,
    ],
    ExpenseFilter.finished => const [
      ExpenseClaimStatus.paid,
      ExpenseClaimStatus.rejected,
    ],
  };
}

final expenseFilterProvider = StateProvider<ExpenseFilter>(
  (ref) => ExpenseFilter.all,
);

/// 我的报销「状态」列表头筛选（2026-09-10）：在当前分段状态集内再精确到单一状态，
/// 下推后端 status 参数（非页内裁剪）。换分段时页面负责清空。
final expenseStatusFilterProvider = StateProvider<ExpenseClaimStatus?>(
  (ref) => null,
);

/// 某状态所属的分段（表头筛选选中状态时同步切换顶部分段）。
ExpenseFilter expenseFilterOfStatus(ExpenseClaimStatus status) {
  for (final filter in ExpenseFilter.values) {
    if (filter == ExpenseFilter.all) continue;
    if (filter.apiStatuses?.contains(status) ?? false) return filter;
  }
  return ExpenseFilter.all;
}

final expenseListProvider =
    AsyncNotifierProvider.autoDispose<
      ExpenseListNotifier,
      PagedResult<ExpenseClaim>
    >(ExpenseListNotifier.new);

class ExpenseListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<ExpenseClaim>> {
  int _page = 1;
  ExpenseFilter? _lastFilter;
  ExpenseClaimStatus? _lastStatus;

  @override
  Future<PagedResult<ExpenseClaim>> build() async {
    ref.listen(masterDataSessionKeyProvider, (previous, next) {
      if (previous == next) return;
      _page = 1;
      state = const AsyncLoading();
      ref.invalidateSelf();
    });
    final filter = ref.watch(expenseFilterProvider);
    final status = ref.watch(expenseStatusFilterProvider);
    // 换分段 / 换表头状态筛选都回第 1 页。
    if (_lastFilter != filter || _lastStatus != status) _page = 1;
    _lastFilter = filter;
    _lastStatus = status;
    return ref
        .watch(expenseRepositoryProvider)
        .listMine(
          statuses: status != null ? [status] : filter.apiStatuses,
          page: _page,
        );
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

  /// 直接拉目标页（2026-09-09 我的报销列表表格化：表格内置翻页条含跳页输入）。
  Future<void> goToPage(int page) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (page < 1 || page == current.page || page > current.totalPages) return;
    await _goTo(page);
  }

  Future<void> _goTo(int page) async {
    if (state.isLoading) return;
    await _reloadPage(page);
  }

  Future<void> _reloadPage(int page) async {
    _page = page;
    state = const AsyncLoading();
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {
      // The current error is exposed in provider state, as before.
    }
  }
}

final expenseDetailProvider = FutureProvider.autoDispose
    .family<ExpenseClaim, String>((ref, id) {
      ref.watch(masterDataSessionKeyProvider);
      return ref.watch(expenseRepositoryProvider).getById(id);
    });

Future<void> submitExpense(WidgetRef ref, String id) async {
  await ref.read(expenseRepositoryProvider).submit(id);
  _invalidateExpense(ref, id);
}

Future<void> withdrawExpense(WidgetRef ref, String id) async {
  await ref.read(expenseRepositoryProvider).withdraw(id);
  _invalidateExpense(ref, id);
}

Future<void> deleteExpense(WidgetRef ref, String id) async {
  await ref.read(expenseRepositoryProvider).delete(id);
  ref.invalidate(expenseListProvider);
  ref.invalidate(expenseApprovalListProvider);
}

Future<ExpenseClaim> createExpense(
  WidgetRef ref, {
  required String title,
  required List<ExpenseItem> items,
  String? remark,
}) async {
  final claim = await ref
      .read(expenseRepositoryProvider)
      .create(
        ExpenseClaimCreateInput(title: title, items: items, remark: remark),
      );
  ref.invalidate(expenseListProvider);
  return claim;
}

enum ApprovalQueue { pending, payable }

extension ApprovalQueueValue on ApprovalQueue {
  String get label => switch (this) {
    ApprovalQueue.pending => '待审批',
    ApprovalQueue.payable => '待打款',
  };
}

final approvalQueueProvider = StateProvider.autoDispose<ApprovalQueue>((ref) {
  final permissions = ref.watch(currentPermissionsProvider);
  return permissions.contains(Perm.expenseApprove)
      ? ApprovalQueue.pending
      : ApprovalQueue.payable;
});

/// 审批列表表头筛选（2026-09-10）：部门 id + 年月（yyyy-MM），下推后端
/// departmentId / year / month 参数（非页内裁剪）。
class ExpenseApprovalFilters {
  const ExpenseApprovalFilters({this.departmentId, this.yearMonth});

  final String? departmentId;

  /// yyyy-MM（业务时区），拆成后端 year/month。
  final String? yearMonth;

  int? get year => _split()?.$1;
  int? get month => _split()?.$2;

  (int, int)? _split() {
    final raw = yearMonth;
    if (raw == null) return null;
    final parts = raw.split('-');
    if (parts.length != 2) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return null;
    return (y, m);
  }

  /// 表头筛选 map（列 key → 值），供 MasterDataTableView.filters。
  Map<String, String?> get asTableFilters => {
    if (departmentId != null) 'departmentName': departmentId,
    if (yearMonth != null) 'yearMonth': yearMonth,
  };

  ExpenseApprovalFilters withColumn(String key, String? value) {
    return switch (key) {
      'departmentName' => ExpenseApprovalFilters(
        departmentId: value,
        yearMonth: yearMonth,
      ),
      'yearMonth' => ExpenseApprovalFilters(
        departmentId: departmentId,
        yearMonth: value,
      ),
      _ => this,
    };
  }
}

/// 审批列表当前表头筛选；换分段（approvalQueueProvider）时自动重置为空。
final expenseApprovalFiltersProvider =
    StateProvider.autoDispose<ExpenseApprovalFilters>((ref) {
      ref.watch(approvalQueueProvider);
      return const ExpenseApprovalFilters();
    });

/// 审批列表表头筛选桶（部门 / 年月），按分段取后端聚合。
final expenseApprovalFacetsProvider = FutureProvider.autoDispose
    .family<Map<String, List<MasterFacetBucket>>, ApprovalQueue>((ref, queue) {
      ref.watch(masterDataSessionKeyProvider);
      return ref.watch(expenseRepositoryProvider).facets(switch (queue) {
        ApprovalQueue.pending => ApprovalFacetQueue.pending,
        ApprovalQueue.payable => ApprovalFacetQueue.payable,
      });
    });

final expenseApprovalListProvider =
    AsyncNotifierProvider.autoDispose<
      ExpenseApprovalListNotifier,
      PagedResult<ExpenseClaim>
    >(ExpenseApprovalListNotifier.new);

class ExpenseApprovalListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<ExpenseClaim>> {
  @override
  Future<PagedResult<ExpenseClaim>> build() {
    // 换分段 / 换表头筛选 → 重建即回第 1 页。
    ref.watch(approvalQueueProvider);
    ref.watch(expenseApprovalFiltersProvider);
    return _fetch(1);
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

  /// 直接拉目标页（2026-09-09 报销审批列表表格化：表格内置翻页条含跳页输入）。
  Future<void> goToPage(int page) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (page < 1 || page == current.page || page > current.totalPages) return;
    await _goTo(page);
  }

  Future<void> _goTo(int page) async {
    if (state.isLoading) return;
    state = const AsyncLoading<PagedResult<ExpenseClaim>>().copyWithPrevious(
      state,
    );
    state = await AsyncValue.guard(() => _fetch(page));
  }

  Future<PagedResult<ExpenseClaim>> _fetch(int page) {
    final queue = ref.read(approvalQueueProvider);
    final filters = ref.read(expenseApprovalFiltersProvider);
    final repository = ref.read(expenseRepositoryProvider);
    return switch (queue) {
      ApprovalQueue.pending => repository.listPending(
        page: page,
        year: filters.year,
        month: filters.month,
        departmentId: filters.departmentId,
      ),
      ApprovalQueue.payable => repository.listPayable(
        page: page,
        year: filters.year,
        month: filters.month,
        departmentId: filters.departmentId,
      ),
    };
  }
}

final expensePaymentOptionsProvider =
    FutureProvider.autoDispose<ExpensePaymentOptions>((ref) async {
      final accountFuture = ref.watch(accountRepositoryProvider).dict();
      final styleFuture = ref
          .watch(paymentStyleRepositoryProvider)
          .tree(category: 'EXPENSE');
      final accounts = await accountFuture;
      final styles = await styleFuture;
      return buildExpensePaymentOptions(accounts, styles);
    });

Future<void> approveExpense(WidgetRef ref, String id) async {
  await ref.read(expenseRepositoryProvider).approve(id);
  _invalidateExpense(ref, id);
}

Future<void> rejectExpense(WidgetRef ref, String id, String reason) async {
  await ref.read(expenseRepositoryProvider).reject(id, reason);
  _invalidateExpense(ref, id);
}

Future<void> payExpense(
  WidgetRef ref,
  String id,
  ExpensePaymentInput input,
) async {
  await ref.read(expenseRepositoryProvider).pay(id, input);
  _invalidateExpense(ref, id);
}

ExpensePaymentOptions buildExpensePaymentOptions(
  List<AccountListItem> accounts,
  List<PaymentStyleNode> styleTree,
) {
  final accountOptions = accounts
      .where((account) => _isSelectableMasterStatus(account.status))
      .map(
        (account) => ExpenseAccountOption(
          id: account.id,
          label: _accountLabel(account),
          balanceCurrent: account.balanceCurrent,
        ),
      )
      .toList(growable: false);

  final styleOptions = <ExpenseStyleOption>[];
  final seenStyleIds = <String>{};
  void visitStyles(List<PaymentStyleNode> nodes) {
    for (final node in nodes) {
      final isExpense =
          node.category == null ||
          node.category!.isEmpty ||
          node.category!.toUpperCase() == 'EXPENSE';
      if (isExpense &&
          _isSelectableMasterStatus(node.status) &&
          seenStyleIds.add(node.id)) {
        styleOptions.add(
          ExpenseStyleOption(
            id: node.id,
            label: [
              node.code.trim(),
              node.name.trim(),
            ].where((value) => value.isNotEmpty).join(' · '),
          ),
        );
      }
      visitStyles(node.children);
    }
  }

  visitStyles(styleTree);
  return ExpensePaymentOptions(
    accounts: accountOptions,
    styles: List.unmodifiable(styleOptions),
  );
}

String _accountLabel(AccountListItem account) {
  final values = <String>[
    if (account.code?.trim().isNotEmpty == true) account.code!.trim(),
    if (account.name?.trim().isNotEmpty == true) account.name!.trim(),
  ];
  return values.isEmpty ? account.id : values.join(' · ');
}

bool _isSelectableMasterStatus(String? status) {
  final normalized = status?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return true;
  return !const {
    '禁用',
    '停用',
    'disabled',
    'inactive',
    'deleted',
    '0',
  }.contains(normalized);
}

void _invalidateExpense(WidgetRef ref, String id) {
  ref.invalidate(expenseListProvider);
  ref.invalidate(expenseApprovalListProvider);
  ref.invalidate(expenseDetailProvider(id));
}
