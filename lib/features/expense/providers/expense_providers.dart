// 报销 Provider
// 文档：docs/05-架构/状态管理.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../repositories/mock_expense_repository.dart';

final expenseRepositoryProvider = Provider<MockExpenseRepository>((ref) {
  return MockExpenseRepository();
});

/// 列表筛选
enum ExpenseFilter { all, draft, processing, finished }

extension ExpenseFilterValue on ExpenseFilter {
  String get label => switch (this) {
        ExpenseFilter.all => '全部',
        ExpenseFilter.draft => '草稿',
        ExpenseFilter.processing => '处理中',
        ExpenseFilter.finished => '已完成',
      };

  bool matches(ExpenseClaimStatus status) => switch (this) {
        ExpenseFilter.all => true,
        ExpenseFilter.draft => status == ExpenseClaimStatus.draft,
        ExpenseFilter.processing => status == ExpenseClaimStatus.submitted ||
            status == ExpenseClaimStatus.reviewing ||
            status == ExpenseClaimStatus.approved,
        ExpenseFilter.finished =>
          status == ExpenseClaimStatus.paid || status == ExpenseClaimStatus.rejected,
      };
}

final expenseFilterProvider = StateProvider<ExpenseFilter>((ref) {
  return ExpenseFilter.all;
});

final expenseListProvider =
    AsyncNotifierProvider.autoDispose<ExpenseListNotifier, List<ExpenseClaim>>(
  ExpenseListNotifier.new,
);

class ExpenseListNotifier
    extends AutoDisposeAsyncNotifier<List<ExpenseClaim>> {
  @override
  Future<List<ExpenseClaim>> build() async {
    final filter = ref.watch(expenseFilterProvider);
    final repo = ref.watch(expenseRepositoryProvider);
    final all = await repo.list();
    return all.where((c) => filter.matches(c.status)).toList();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final filter = ref.read(expenseFilterProvider);
      final repo = ref.read(expenseRepositoryProvider);
      final all = await repo.list();
      return all.where((c) => filter.matches(c.status)).toList();
    });
  }
}

/// 详情
final expenseDetailProvider =
    FutureProvider.autoDispose.family<ExpenseClaim?, String>((ref, id) async {
  return ref.watch(expenseRepositoryProvider).getById(id);
});

/// 操作辅助
Future<void> submitExpense(WidgetRef ref, String id) async {
  await ref.read(expenseRepositoryProvider).submit(id);
  ref.invalidate(expenseListProvider);
  ref.invalidate(expenseDetailProvider(id));
}

Future<void> withdrawExpense(WidgetRef ref, String id) async {
  await ref.read(expenseRepositoryProvider).withdraw(id);
  ref.invalidate(expenseListProvider);
  ref.invalidate(expenseDetailProvider(id));
}

Future<void> deleteExpense(WidgetRef ref, String id) async {
  await ref.read(expenseRepositoryProvider).delete(id);
  ref.invalidate(expenseListProvider);
}

Future<ExpenseClaim> createExpense(
  WidgetRef ref, {
  required String title,
  required List<ExpenseItem> items,
  String? remark,
}) async {
  final claim = await ref.read(expenseRepositoryProvider).create(
        title: title,
        items: items,
        remark: remark,
      );
  ref.invalidate(expenseListProvider);
  return claim;
}

// ===== 报销审批（Phase 3）=====

enum ApprovalFilter { mine, all, done }

extension ApprovalFilterX on ApprovalFilter {
  String get label => switch (this) {
        ApprovalFilter.mine => '待我审',
        ApprovalFilter.all => '全部',
        ApprovalFilter.done => '已审',
      };

  bool matches(ExpenseClaimStatus s) => switch (this) {
        ApprovalFilter.mine =>
          s == ExpenseClaimStatus.submitted || s == ExpenseClaimStatus.reviewing,
        ApprovalFilter.all => true,
        ApprovalFilter.done =>
          s == ExpenseClaimStatus.approved ||
          s == ExpenseClaimStatus.rejected ||
          s == ExpenseClaimStatus.paid,
      };
}

final approvalFilterProvider =
    StateProvider<ApprovalFilter>((ref) => ApprovalFilter.mine);

final expenseApprovalListProvider =
    FutureProvider.autoDispose<List<ExpenseClaim>>((ref) async {
  ref.watch(approvalFilterProvider);
  return ref.watch(expenseRepositoryProvider).list();
});
