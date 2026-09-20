import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Repo extends Fake implements ExpenseRepository {
  final requests = <Completer<PagedResult<ExpenseClaim>>>[];
  @override
  Future<PagedResult<ExpenseClaim>> listPending({
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  }) {
    final request = Completer<PagedResult<ExpenseClaim>>();
    requests.add(request);
    return request.future;
  }
}

PagedResult<ExpenseClaim> _page(int total, {int page = 1}) =>
    PagedResult(items: [], page: page, size: 24, total: total, totalPages: 3);

void main() {
  test(
    'finance queue clears on identity switch and rejects a late page response',
    () async {
      final identity = StateProvider<String>((ref) => 'A');
      final repo = _Repo();
      final container = ProviderContainer(
        overrides: [
          masterDataSessionKeyProvider.overrideWith(
            (ref) => ref.watch(identity),
          ),
          currentPermissionsProvider.overrideWithValue({Perm.expenseApprove}),
          expenseRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        expenseApprovalListProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      repo.requests[0].complete(_page(10));
      await container.read(expenseApprovalListProvider.future);
      final next = container
          .read(expenseApprovalListProvider.notifier)
          .nextPage();
      await Future<void>.delayed(Duration.zero);
      container.read(identity.notifier).state = 'B';
      await Future<void>.delayed(Duration.zero);
      expect(container.read(expenseApprovalListProvider).valueOrNull, isNull);
      repo.requests[2].complete(_page(22));
      expect(
        (await container.read(expenseApprovalListProvider.future)).total,
        22,
      );
      repo.requests[1].complete(_page(99, page: 2));
      await next;
      expect(
        container.read(expenseApprovalListProvider).requireValue.total,
        22,
      );
    },
  );
}
