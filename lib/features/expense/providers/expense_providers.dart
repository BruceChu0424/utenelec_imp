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
import '../models/expense_invoice.dart';
import '../models/expense_item.dart';
import '../models/expense_payment.dart';
import '../repositories/expense_repository.dart';
import '../../../shared/badges/badge_registry.dart';

enum ExpenseFilter { all, draft, rejected, processing, finished }

extension ExpenseFilterValue on ExpenseFilter {
  String get label => switch (this) {
    ExpenseFilter.all => '全部',
    ExpenseFilter.draft => '草稿',
    ExpenseFilter.rejected => '待修订',
    ExpenseFilter.processing => '处理中',
    ExpenseFilter.finished => '已完成',
  };

  Iterable<ExpenseClaimStatus>? get apiStatuses => switch (this) {
    ExpenseFilter.all => null,
    ExpenseFilter.draft => const [ExpenseClaimStatus.draft],
    ExpenseFilter.rejected => const [ExpenseClaimStatus.rejected],
    ExpenseFilter.processing => const [
      ExpenseClaimStatus.submitted,
      ExpenseClaimStatus.reviewing,
      ExpenseClaimStatus.approved,
    ],
    ExpenseFilter.finished => const [ExpenseClaimStatus.paid],
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

/// 我的报销「类别」列表头筛选（2026-09-16）：明细项级别类别码（TRANSPORT/...），
/// 下推后端 category 参数（类别挂在明细项上，命中任一明细即返回该单）。
final expenseCategoryFilterProvider = StateProvider<String?>((ref) => null);

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
  String? _lastCategory;

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
    final category = ref.watch(expenseCategoryFilterProvider);
    // 换分段 / 换表头状态或类别筛选都回第 1 页。
    if (_lastFilter != filter ||
        _lastStatus != status ||
        _lastCategory != category) {
      _page = 1;
    }
    _lastFilter = filter;
    _lastStatus = status;
    _lastCategory = category;
    return ref
        .watch(expenseRepositoryProvider)
        .listMine(
          statuses: status != null ? [status] : filter.apiStatuses,
          category: category,
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

/// 队列汇总（审批页统计卡：待审批/待打款/本月口径）。
final expenseQueueSummaryProvider =
    FutureProvider.autoDispose<ExpenseQueueSummary>((ref) {
      ref.watch(masterDataSessionKeyProvider);
      return ref.watch(expenseRepositoryProvider).summary();
    });

Future<void> submitExpense(
  WidgetRef ref,
  String id, {
  int? expectedVersion,
}) async {
  await ref
      .read(expenseRepositoryProvider)
      .submit(
        id,
        expectedVersion:
            expectedVersion ??
            ref.read(expenseDetailProvider(id)).requireValue.version,
      );
  _invalidateExpense(ref, id);
}

Future<void> withdrawExpense(
  WidgetRef ref,
  String id, {
  int? expectedVersion,
}) async {
  await ref
      .read(expenseRepositoryProvider)
      .withdraw(
        id,
        expectedVersion:
            expectedVersion ??
            ref.read(expenseDetailProvider(id)).requireValue.version,
      );
  _invalidateExpense(ref, id);
}

Future<void> deleteExpense(
  WidgetRef ref,
  String id, {
  int? expectedVersion,
}) async {
  await ref
      .read(expenseRepositoryProvider)
      .delete(
        id,
        expectedVersion:
            expectedVersion ??
            ref.read(expenseDetailProvider(id)).requireValue.version,
      );
  refreshBadges(ref);
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
  refreshBadges(ref);
  ref.invalidate(expenseListProvider);
  return claim;
}

/// 编辑保存（DRAFT/REJECTED；明细整组替换，V608）。
Future<ExpenseClaim> updateExpense(
  WidgetRef ref,
  String id, {
  required int expectedVersion,
  required String title,
  required List<ExpenseItem> items,
  String? remark,
}) async {
  final claim = await ref
      .read(expenseRepositoryProvider)
      .update(
        id,
        ExpenseClaimCreateInput(
          title: title,
          items: items,
          remark: remark,
          expectedVersion: expectedVersion,
        ),
      );
  refreshBadges(ref);
  ref.invalidate(expenseListProvider);
  ref.invalidate(expenseDetailProvider(id));
  return claim;
}

/// 发票登记/修改（V608）：成功后刷新详情（发票表/轨迹联动）。
Future<ExpenseClaim> saveExpenseInvoice(
  WidgetRef ref,
  String claimId,
  ExpenseClaimInvoiceInput input, {
  String? invoiceId,
}) async {
  final repository = ref.read(expenseRepositoryProvider);
  final claim = invoiceId == null
      ? await repository.addInvoice(claimId, input)
      : await repository.updateInvoice(claimId, invoiceId, input);
  ref.invalidate(expenseDetailProvider(claimId));
  return claim;
}

Future<void> deleteExpenseInvoice(
  WidgetRef ref,
  String claimId,
  String invoiceId,
) async {
  await ref
      .read(expenseRepositoryProvider)
      .deleteInvoice(
        claimId,
        invoiceId,
        expectedVersion: ref
            .read(expenseDetailProvider(claimId))
            .requireValue
            .version,
      );
  ref.invalidate(expenseDetailProvider(claimId));
}

enum ApprovalQueue { pending, payable, history }

extension ApprovalQueueValue on ApprovalQueue {
  String get label => switch (this) {
    ApprovalQueue.pending => '待审批',
    ApprovalQueue.payable => '待付款',
    ApprovalQueue.history => '已处理',
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
  const ExpenseApprovalFilters({
    this.departmentId,
    this.yearMonth,
    this.category,
  });

  final String? departmentId;
  final String? category;

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
    if (category != null) 'category': category,
  };

  ExpenseApprovalFilters withColumn(String key, String? value) {
    return switch (key) {
      'departmentName' => ExpenseApprovalFilters(
        departmentId: value,
        yearMonth: yearMonth,
        category: category,
      ),
      'yearMonth' => ExpenseApprovalFilters(
        departmentId: departmentId,
        yearMonth: value,
        category: category,
      ),
      'category' => ExpenseApprovalFilters(
        departmentId: departmentId,
        yearMonth: yearMonth,
        category: value,
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
        ApprovalQueue.history => ApprovalFacetQueue.history,
      });
    });

final expenseApprovalListProvider =
    AsyncNotifierProvider.autoDispose<
      ExpenseApprovalListNotifier,
      PagedResult<ExpenseClaim>
    >(ExpenseApprovalListNotifier.new);

class ExpenseApprovalListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<ExpenseClaim>> {
  int _requestGeneration = 0;

  @override
  Future<PagedResult<ExpenseClaim>> build() {
    _requestGeneration++;
    ref.listen(masterDataSessionKeyProvider, (previous, next) {
      if (previous == next) return;
      _requestGeneration++;
      state = const AsyncLoading();
      ref.invalidateSelf();
    });
    ref.onDispose(() => _requestGeneration++);
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
    final generation = _requestGeneration;
    final result = await AsyncValue.guard(() => _fetch(page));
    if (generation == _requestGeneration) state = result;
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
        category: filters.category,
      ),
      ApprovalQueue.history => repository.listHistory(
        page: page,
        year: filters.year,
        month: filters.month,
        departmentId: filters.departmentId,
        category: filters.category,
      ),
      ApprovalQueue.payable => repository.listPayable(
        page: page,
        year: filters.year,
        month: filters.month,
        departmentId: filters.departmentId,
        category: filters.category,
      ),
    };
  }
}

final expensePaymentOptionsProvider =
    FutureProvider.autoDispose<ExpensePaymentOptions>((ref) async {
      ref.watch(masterDataSessionKeyProvider);
      final accountFuture = ref.watch(accountRepositoryProvider).dict();
      final styleFuture = ref
          .watch(paymentStyleRepositoryProvider)
          .tree(category: 'EXPENSE');
      final accounts = await accountFuture;
      final styles = await styleFuture;
      return buildExpensePaymentOptions(accounts, styles);
    });

Future<void> approveExpense(
  WidgetRef ref,
  String id, {
  int? expectedVersion,
}) async {
  await ref
      .read(expenseRepositoryProvider)
      .approve(
        id,
        expectedVersion:
            expectedVersion ??
            ref.read(expenseDetailProvider(id)).requireValue.version,
      );
  _invalidateExpense(ref, id);
}

Future<void> rejectExpense(
  WidgetRef ref,
  String id,
  String reason, {
  int? expectedVersion,
}) async {
  await ref
      .read(expenseRepositoryProvider)
      .reject(
        id,
        reason,
        expectedVersion:
            expectedVersion ??
            ref.read(expenseDetailProvider(id)).requireValue.version,
      );
  _invalidateExpense(ref, id);
}

Future<void> payExpense(
  WidgetRef ref,
  String id,
  ExpensePaymentInput input, {
  int? expectedVersion,
}) async {
  await ref
      .read(expenseRepositoryProvider)
      .pay(
        id,
        input,
        expectedVersion:
            expectedVersion ??
            ref.read(expenseDetailProvider(id)).requireValue.version,
      );
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
  ref.invalidate(expenseQueueSummaryProvider);
  ref.invalidate(expenseApprovalFacetsProvider);
  refreshBadges(ref);
  ref.invalidate(expenseListProvider);
  ref.invalidate(expenseApprovalListProvider);
  ref.invalidate(expenseDetailProvider(id));
}
