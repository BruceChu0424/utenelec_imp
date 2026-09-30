import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/providers/payroll_providers.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  for (final approval in [false, true]) {
    test(
      '${approval ? 'approval' : 'mine'} expense retries a failed next page',
      () async {
        final repository = _RetryExpenseRepository();
        final container = ProviderContainer(
          overrides: [
            masterDataSessionKeyProvider.overrideWithValue('account'),
            expenseRepositoryProvider.overrideWithValue(repository),
            approvalQueueProvider.overrideWith((ref) => ApprovalQueue.pending),
          ],
        );
        addTearDown(container.dispose);
        if (approval) {
          container.listen(expenseApprovalListProvider, (_, _) {});
          await container.read(expenseApprovalListProvider.future);
          final notifier = container.read(expenseApprovalListProvider.notifier);
          await notifier.goToPage(2);
          expect(container.read(expenseApprovalListProvider).hasError, isTrue);
          await notifier.goToPage(2);
          expect(
            container.read(expenseApprovalListProvider).requireValue.page,
            2,
          );
        } else {
          container.listen(expenseListProvider, (_, _) {});
          await container.read(expenseListProvider.future);
          final notifier = container.read(expenseListProvider.notifier);
          await notifier.goToPage(2);
          expect(container.read(expenseListProvider).hasError, isTrue);
          await notifier.goToPage(2);
          expect(container.read(expenseListProvider).requireValue.page, 2);
        }
        expect(repository.pages, [1, 2, 2]);
      },
    );
  }

  test('payroll retries a failed next page', () async {
    final repository = _RetryPayrollRepository();
    final container = ProviderContainer(
      overrides: [
        masterDataSessionKeyProvider.overrideWithValue('account'),
        payrollRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    container.listen(payrollListProvider, (_, _) {});
    await container.read(payrollListProvider.future);
    final notifier = container.read(payrollListProvider.notifier);
    await notifier.goToPage(2);
    expect(container.read(payrollListProvider).hasError, isTrue);
    await notifier.goToPage(2);
    expect(container.read(payrollListProvider).requireValue.page, 2);
    expect(repository.pages, [1, 2, 2]);
  });
}

mixin _RetryPage<T> {
  final pages = <int>[];
  bool failed = false;

  Future<PagedResult<T>> load(int page) async {
    pages.add(page);
    if (page == 2 && !failed) {
      failed = true;
      throw StateError('offline');
    }
    return PagedResult(
      items: const [],
      page: page,
      size: 1,
      total: 2,
      totalPages: 2,
    );
  }
}

class _RetryExpenseRepository extends Fake
    with _RetryPage<ExpenseClaim>
    implements ExpenseRepository {
  @override
  Future<PagedResult<ExpenseClaim>> listMine({
    Iterable<ExpenseClaimStatus>? statuses,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
    String? sort,
    String? order,
    String? claimNo,
  }) => load(page);

  @override
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
    String? sort,
    String? order,
    String? claimNo,
  }) => load(page);
}

class _RetryPayrollRepository extends Fake
    with _RetryPage<PayrollSlip>
    implements PayrollRepository {
  @override
  Future<PagedResult<PayrollSlip>> listSlips({
    String? status,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  }) => load(page);
}
