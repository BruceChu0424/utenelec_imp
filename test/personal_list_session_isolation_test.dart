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
      '$name discards late page response when a new filter starts at page one',
      () async {
        final harness = _Harness(payroll);
        addTearDown(harness.dispose);
        harness.complete(0, 10);
        await harness.total();
        final next = harness.nextPage();
        await harness.tick();
        expect(harness.requestedPage(1), 2);
        harness.filter();
        await harness.tick();
        expect(harness.requestedPage(2), 1);
        harness.complete(2, 20);
        expect(await harness.total(), 20);
        harness.complete(1, 99);
        await next;
        await harness.tick();
        expect(harness.value()?.total, 20);
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
  void complete(int index, int total) {
    if (payroll) {
      payrollRepo.requests[index].complete(
        PagedResult<PayrollSlip>(
          items: [],
          page: payrollRepo.pages[index],
          size: 24,
          total: total,
          totalPages: 3,
        ),
      );
    } else {
      expenseRepo.requests[index].complete(
        PagedResult<ExpenseClaim>(
          items: [],
          page: expenseRepo.pages[index],
          size: 24,
          total: total,
          totalPages: 3,
        ),
      );
    }
  }
}

class _PayrollRepo implements PayrollRepository {
  final requests = <Completer<PagedResult<PayrollSlip>>>[];
  final pages = <int>[];
  @override
  Future<PagedResult<PayrollSlip>> listSlips({
    String? status,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  }) {
    pages.add(page);
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
    final pending = Completer<PagedResult<ExpenseClaim>>();
    requests.add(pending);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
