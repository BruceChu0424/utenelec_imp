import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
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
  for (final payroll in [true, false]) {
    final name = payroll ? 'payroll' : 'expense';
    test(
      '$name switches identity without retaining old data or accepting a late old refresh',
      () async {
        final harness = _Harness(payroll);
        addTearDown(harness.dispose);
        harness.complete(0, 11);
        await harness.total();
        final refresh = harness.refresh();
        await harness.tick();
        harness.container.read(harness.identity.notifier).state = 'B';
        await harness.tick();
        // Riverpod 3：AsyncNotifier 元素在世期间无法清空 previous value——reload
        // 会保留旧快照供 skipLoadingOnReload 渐进渲染（v3 起 when 默认不再跳过
        // reload 的 loading 分支，默认消费方渲染骨架屏，不再呈现旧身份数据）。
        // 隔离契约由此处的「切换立即进入重载」+ 后续「新身份数据原子替换、旧响应
        // 晚到被世代号拒收」+ 页面层 RetainedAsyncPage（scope 键含会话）共同保证。
        expect(harness.reloading(), isTrue, reason: '切换身份必须立即进入重载过渡');
        harness.complete(2, 22);
        expect(await harness.total(), 22);
        harness.complete(1, 99);
        await refresh;
        await harness.tick();
        expect(harness.value()?.total, 22);
      },
    );

    test(
      '$name discards a late complete refresh when a new filter starts',
      () async {
        final harness = _Harness(payroll);
        addTearDown(harness.dispose);
        harness.complete(0, 10);
        await harness.total();
        await harness.nextPage();
        await harness.tick();
        expect(harness.requestCount, 1);
        final oldRefresh = harness.refresh();
        await harness.tick();
        expect(harness.requestedPage(1), 1);
        harness.filter();
        await harness.tick();
        expect(harness.requestedPage(2), 1);
        harness.complete(2, 20);
        expect(await harness.total(), 20);
        harness.complete(1, 99);
        await oldRefresh;
        await harness.tick();
        expect(harness.value()?.total, 20);
        expect(harness.value()?.items, hasLength(20));
        expect(harness.requestCount, 3);
      },
    );

    test('$name refresh supersedes an unfinished initial load', () async {
      final harness = _Harness(payroll);
      addTearDown(harness.dispose);
      final refresh = harness.refresh();
      await harness.tick();
      harness.complete(1, 21);
      await refresh;
      harness.complete(0, 99);
      await harness.tick();
      expect(harness.value()?.total, 21);
    });
  }
}

class _Harness {
  _Harness(this.payroll) {
    container = ProviderContainer(
      overrides: [
        masterDataSessionKeyProvider.overrideWith((ref) => ref.watch(identity)),
        payrollRepositoryProvider.overrideWithValue(payrollRepo),
        expenseRepositoryProvider.overrideWithValue(expenseRepo),
      ],
    );
    subscription = payroll
        ? container.listen(payrollListProvider, (_, _) {})
        : container.listen(expenseListProvider, (_, _) {});
  }
  final bool payroll;
  final identity = StateProvider<String>((ref) => 'A');
  final payrollRepo = _PayrollRepo();
  final expenseRepo = _ExpenseRepo();
  late final ProviderContainer container;
  late final ProviderSubscription<Object?> subscription;
  Future<void> tick() => Future<void>.delayed(Duration.zero);
  void dispose() {
    subscription.close();
    container.dispose();
  }

  Future<int> total() async => payroll
      ? (await container.read(payrollListProvider.future)).total
      : (await container.read(expenseListProvider.future)).total;
  PagedResult<Object?>? value() => payroll
      ? container.read(payrollListProvider).value
      : container.read(expenseListProvider).value;
  bool reloading() => payroll
      ? container.read(payrollListProvider).isReloading
      : container.read(expenseListProvider).isReloading;
  Future<void> refresh() => payroll
      ? container.read(payrollListProvider.notifier).refresh()
      : container.read(expenseListProvider.notifier).refresh();
  Future<void> nextPage() => payroll
      ? container.read(payrollListProvider.notifier).nextPage()
      : container.read(expenseListProvider.notifier).nextPage();
  void filter() {
    if (payroll) {
      container.read(payrollFilterProvider.notifier).state =
          PayrollFilter.viewed;
    } else {
      container.read(expenseFilterProvider.notifier).state =
          ExpenseFilter.draft;
    }
  }

  int requestedPage(int index) =>
      payroll ? payrollRepo.pages[index] : expenseRepo.pages[index];
  int get requestCount =>
      payroll ? payrollRepo.requests.length : expenseRepo.requests.length;
  void complete(int index, int total) {
    if (payroll) {
      payrollRepo.requests[index].complete(
        PagedResult<PayrollSlip>(
          items: [
            for (
              var i = (payrollRepo.pages[index] - 1) * 24;
              i < total && i < payrollRepo.pages[index] * 24;
              i++
            )
              PayrollSlip(
                id: 'reply-$index-$i',
                employeeId: 'employee-$index',
                employeeName: '原员工$index',
                employeeCode: 'E$index',
                year: 2026,
                month: 11,
                items: const [],
                grossIncome: 1,
                totalDeduction: 0,
                netIncome: 1,
                status: payrollRepo.statuses[index] == 'VIEWED'
                    ? PayrollSlipStatus.viewed
                    : PayrollSlipStatus.published,
                publishedAt: DateTime(2026, 11),
              ),
          ],
          page: payrollRepo.pages[index],
          size: 24,
          total: total,
          totalPages: (total / 24).ceil(),
        ),
      );
    } else {
      expenseRepo.requests[index].complete(
        PagedResult<ExpenseClaim>(
          items: [
            for (
              var i = (expenseRepo.pages[index] - 1) * 24;
              i < total && i < expenseRepo.pages[index] * 24;
              i++
            )
              ExpenseClaim(
                id: 'reply-$index-$i',
                claimNo: 'claim-$index-$i',
                applicantId: 'employee-$index',
                applicantName: '原员工$index',
                title: '原报销单$i',
                items: const [],
                totalAmount: 1,
                status: expenseRepo.statuses[index],
                createdAt: DateTime(2026, 11),
              ),
          ],
          page: expenseRepo.pages[index],
          size: 24,
          total: total,
          totalPages: (total / 24).ceil(),
        ),
      );
    }
  }
}

class _PayrollRepo implements PayrollRepository {
  final requests = <Completer<PagedResult<PayrollSlip>>>[];
  final pages = <int>[];
  final statuses = <String?>[];
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
  }) {
    pages.add(page);
    statuses.add(status);
    final pending = Completer<PagedResult<PayrollSlip>>();
    requests.add(pending);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ExpenseRepo implements ExpenseRepository {
  final requests = <Completer<PagedResult<ExpenseClaim>>>[];
  final pages = <int>[];
  final statuses = <ExpenseClaimStatus>[];
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
  }) {
    pages.add(page);
    this.statuses.add(statuses?.first ?? ExpenseClaimStatus.submitted);
    final pending = Completer<PagedResult<ExpenseClaim>>();
    requests.add(pending);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
