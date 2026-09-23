import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Repository implements SalesOrderFinanceConfirmationRepository {
  final calls = <bool?>[];

  @override
  Future<int> pendingCount({bool? changesOnly}) async {
    calls.add(changesOnly);
    return changesOnly == null
        ? 7
        : changesOnly
        ? 3
        : 4;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'first-review and modification segments are counted separately and refresh together',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.salesOrderFinanceView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
            repository,
          ),
        ],
      );
      addTearDown(container.dispose);
      final first = container.listen(
        salesOrderFinanceQueueCountProvider(false),
        (_, _) {},
      );
      final changes = container.listen(
        salesOrderFinanceQueueCountProvider(true),
        (_, _) {},
      );
      addTearDown(first.close);
      addTearDown(changes.close);
      expect(
        await container.read(salesOrderFinanceQueueCountProvider(false).future),
        4,
      );
      expect(
        await container.read(salesOrderFinanceQueueCountProvider(true).future),
        3,
      );
      expect(repository.calls, unorderedEquals([false, true]));
      // 队列页确认/驳回成功后两个分段一起失效重拉; 卡面总数随徽章汇总走(ADR-108),
      // 不再有单独的「总数」请求。
      container.invalidate(salesOrderFinanceQueueCountProvider);
      await container.read(salesOrderFinanceQueueCountProvider(false).future);
      await container.read(salesOrderFinanceQueueCountProvider(true).future);
      expect(repository.calls, unorderedEquals([false, true, false, true]));
    },
  );

  test('users without finance view never request either task count', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        currentPermissionsProvider.overrideWithValue({}),
        isSuperAdminProvider.overrideWithValue(false),
        salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(
      await container.read(salesOrderFinanceQueueCountProvider(false).future),
      0,
    );
    expect(
      await container.read(salesOrderFinanceQueueCountProvider(true).future),
      0,
    );
    expect(repository.calls, isEmpty);
  });
}
