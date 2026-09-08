import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../basic_data/models/account_node.dart';
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

final expenseListProvider =
    AsyncNotifierProvider.autoDispose<
      ExpenseListNotifier,
      PagedResult<ExpenseClaim>
    >(ExpenseListNotifier.new);

class ExpenseListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<ExpenseClaim>> {
  int _page = 1;
  ExpenseFilter? _lastFilter;

  @override
  Future<PagedResult<ExpenseClaim>> build() async {
    ref.listen(masterDataSessionKeyProvider, (previous, next) {
      if (previous == next) return;
      _page = 1;
      state = const AsyncLoading();
      ref.invalidateSelf();
    });
    final filter = ref.watch(expenseFilterProvider);
    if (_lastFilter != filter) _page = 1;
    _lastFilter = filter;
    return ref
        .watch(expenseRepositoryProvider)
        .listMine(statuses: filter.apiStatuses, page: _page);
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

final expenseApprovalListProvider =
    AsyncNotifierProvider.autoDispose<
      ExpenseApprovalListNotifier,
      PagedResult<ExpenseClaim>
    >(ExpenseApprovalListNotifier.new);

class ExpenseApprovalListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<ExpenseClaim>> {
  @override
  Future<PagedResult<ExpenseClaim>> build() {
    final queue = ref.watch(approvalQueueProvider);
    final repository = ref.watch(expenseRepositoryProvider);
    return switch (queue) {
      ApprovalQueue.pending => repository.listPending(),
      ApprovalQueue.payable => repository.listPayable(),
    };
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
    state = const AsyncLoading<PagedResult<ExpenseClaim>>().copyWithPrevious(
      state,
    );
    state = await AsyncValue.guard(() => _fetch(page));
  }

  Future<PagedResult<ExpenseClaim>> _fetch(int page) {
    final queue = ref.read(approvalQueueProvider);
    final repository = ref.read(expenseRepositoryProvider);
    return switch (queue) {
      ApprovalQueue.pending => repository.listPending(page: page),
      ApprovalQueue.payable => repository.listPayable(page: page),
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
