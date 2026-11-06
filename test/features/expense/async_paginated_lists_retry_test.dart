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

void _complete<T>(PagedResult<T> result, _RetryPage<T> repository) {
  final batchSize = repository.sizes.first;
  expect(result.items, hasLength(batchSize + 1));
  expect(result.total, batchSize + 1);
  expect(result.page, 1);
  expect(result.totalPages, 1);
  expect(repository.pages, [1, 2, 1, 2]);
  expect(repository.sizes, everyElement(batchSize));
}

void main() {
  for (final approval in [false, true]) {
    test(
      '${approval ? 'approval' : 'mine'} expense retries a failed internal batch as one complete read',
      () async {
        final repository = _RetryExpenseRepository();
        final container = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            masterDataSessionKeyProvider.overrideWithValue('account'),
            expenseRepositoryProvider.overrideWithValue(repository),
            approvalQueueProvider.overrideWith((ref) => ApprovalQueue.pending),
          ],
        );
        addTearDown(container.dispose);
        final publishedCounts = <int>[];
        if (approval) {
          container.listen(expenseApprovalListProvider, (_, next) {
            if (next.hasValue) {
              publishedCounts.add(next.requireValue.items.length);
            }
          });
          await expectLater(
            container.read(expenseApprovalListProvider.future),
            throwsStateError,
          );
          final notifier = container.read(expenseApprovalListProvider.notifier);
          expect(container.read(expenseApprovalListProvider).hasError, isTrue);
          expect(container.read(expenseApprovalListProvider).hasValue, isFalse);
          expect(
            publishedCounts,
            isEmpty,
            reason: 'A failed continuation cannot publish a partial list.',
          );
          // The approval page refresh retires its shared read owner first.
          notifier.invalidateCachedPages();
          container.invalidate(expenseApprovalListProvider);
          final result = await container.read(
            expenseApprovalListProvider.future,
          );
          _complete(result, repository);
          expect(
            result.items.map((row) => row.id).toSet(),
            hasLength(result.total),
          );
          await container
              .read(expenseApprovalListProvider.notifier)
              .goToPage(2);
        } else {
          container.listen(expenseListProvider, (_, next) {
            if (next.hasValue) {
              publishedCounts.add(next.requireValue.items.length);
            }
          });
          await expectLater(
            container.read(expenseListProvider.future),
            throwsStateError,
          );
          final notifier = container.read(expenseListProvider.notifier);
          expect(container.read(expenseListProvider).hasError, isTrue);
          expect(container.read(expenseListProvider).hasValue, isFalse);
          expect(
            publishedCounts,
            isEmpty,
            reason: 'A failed continuation cannot publish a partial list.',
          );
          await notifier.retry();
          final result = container.read(expenseListProvider).requireValue;
          _complete(result, repository);
          expect(
            result.items.map((row) => row.id).toSet(),
            hasLength(result.total),
          );
          await notifier.goToPage(2);
        }
        expect(publishedCounts, everyElement(repository.sizes.first + 1));
        expect(
          repository.pages,
          [1, 2, 1, 2],
          reason:
              'Compatibility pagination cannot request more of a complete result.',
        );
      },
    );
  }

  test(
    'payroll retries a failed internal batch as one complete read',
    () async {
      final repository = _RetryPayrollRepository();
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          masterDataSessionKeyProvider.overrideWithValue('account'),
          payrollRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      final publishedCounts = <int>[];
      container.listen(payrollListProvider, (_, next) {
        if (next.hasValue) publishedCounts.add(next.requireValue.items.length);
      });
      await expectLater(
        container.read(payrollListProvider.future),
        throwsStateError,
      );
      final notifier = container.read(payrollListProvider.notifier);
      expect(container.read(payrollListProvider).hasError, isTrue);
      expect(container.read(payrollListProvider).hasValue, isFalse);
      expect(publishedCounts, isEmpty);
      await notifier.retry();
      final result = container.read(payrollListProvider).requireValue;
      _complete(result, repository);
      expect(
        result.items.map((row) => row.id).toSet(),
        hasLength(result.total),
      );
      expect(publishedCounts, everyElement(repository.sizes.first + 1));
      await notifier.goToPage(2);
      expect(repository.pages, [1, 2, 1, 2]);
    },
  );
}

mixin _RetryPage<T> {
  final pages = <int>[];
  final sizes = <int>[];
  bool failed = false;
  T row(int index);

  Future<PagedResult<T>> load(int page, int size) async {
    pages.add(page);
    sizes.add(size);
    if (page == 2 && !failed) {
      failed = true;
      throw StateError('offline');
    }
    final total = size + 1;
    final start = (page - 1) * size;
    return PagedResult(
      items: [
        for (var index = start; index < total && index < start + size; index++)
          row(index),
      ],
      page: page,
      size: size,
      total: total,
      totalPages: 2,
    );
  }
}

class _RetryExpenseRepository extends Fake
    with _RetryPage<ExpenseClaim>
    implements ExpenseRepository {
  @override
  ExpenseClaim row(int index) => ExpenseClaim(
    id: 'expense-$index',
    claimNo: 'BX-$index',
    applicantId: 'employee',
    applicantName: '原申请人',
    title: '原报销 $index',
    items: const [],
    totalAmount: 1,
    status: ExpenseClaimStatus.draft,
    createdAt: DateTime.utc(2026, 11, 6),
  );
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
  }) => load(page, size);

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
  }) => load(page, size);
}

class _RetryPayrollRepository extends Fake
    with _RetryPage<PayrollSlip>
    implements PayrollRepository {
  @override
  PayrollSlip row(int index) => PayrollSlip(
    id: 'payroll-$index',
    employeeId: 'employee',
    employeeName: '原员工',
    employeeCode: '0001',
    year: 2026,
    month: 11,
    items: const [],
    grossIncome: 100,
    totalDeduction: 10,
    netIncome: 90,
    status: PayrollSlipStatus.published,
    publishedAt: DateTime.utc(2026, 11, 6),
  );
  @override
  Future<PagedResult<PayrollSlip>> listSlips({
    String? status,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    Map<String, String?> columnSearch = const {},
    String? sort,
    String? order,
  }) => load(page, size);
}
