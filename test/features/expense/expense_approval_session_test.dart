import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Repo extends Fake implements ExpenseRepository {
  final requests = <Completer<PagedResult<ExpenseClaim>>>[];
  final pages = <int>[];
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
  }) {
    final request = Completer<PagedResult<ExpenseClaim>>();
    requests.add(request);
    pages.add(page);
    return request.future;
  }
}

PagedResult<ExpenseClaim> _page(int total, String owner, {int page = 1}) =>
    PagedResult(
      items: [
        for (var i = (page - 1) * 24; i < total && i < page * 24; i++)
          ExpenseClaim(
            id: '$owner-$i',
            claimNo: '$owner-claim-$i',
            applicantId: owner,
            applicantName: owner,
            title: '原报销单$i',
            items: const [],
            totalAmount: 1,
            status: ExpenseClaimStatus.submitted,
            createdAt: DateTime(2026, 11),
          ),
      ],
      page: page,
      size: 24,
      total: total,
      totalPages: (total / 24).ceil(),
    );

void main() {
  test(
    'finance queue clears on identity switch and rejects a late complete refresh',
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
      repo.requests[0].complete(_page(10, 'A'));
      final original = await container.read(expenseApprovalListProvider.future);
      expect(original.items, hasLength(10));
      expect(original.items.every((claim) => claim.applicantId == 'A'), isTrue);
      container
          .read(expenseApprovalListProvider.notifier)
          .invalidateCachedPages();
      final oldRefresh = container.refresh(expenseApprovalListProvider.future);
      await Future<void>.delayed(Duration.zero);
      container.read(identity.notifier).state = 'B';
      // Riverpod 3 的 provider 刷新经调度器异步入队；给事件循环几个节拍让
      // session key 重建传导到审批队列。
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      // Riverpod 3 起 loading 态会并入旧值（copyWithPrevious），value 不再清空；
      // 「队列已清空、旧数据不再作为完成态展示」的 v3 等价断言是 isLoading。
      // 旧身份迟到完整读取的拒绝由下方实际原始行身份断言保证。
      expect(container.read(expenseApprovalListProvider).isLoading, isTrue);
      repo.requests[2].complete(_page(22, 'B'));
      expect(
        (await container.read(expenseApprovalListProvider.future)).total,
        22,
      );
      repo.requests[1].complete(_page(99, 'A-late'));
      await oldRefresh;
      expect(
        container.read(expenseApprovalListProvider).requireValue.total,
        22,
      );
      expect(
        container.read(expenseApprovalListProvider).requireValue.items,
        hasLength(22),
      );
      expect(
        container
            .read(expenseApprovalListProvider)
            .requireValue
            .items
            .every((claim) => claim.applicantId == 'B'),
        isTrue,
      );
      expect(repo.pages, [1, 1, 1]);
    },
  );
}
