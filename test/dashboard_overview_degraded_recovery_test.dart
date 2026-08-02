import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/dashboard/models/dashboard_overview.dart';
import 'package:uten_imp/features/dashboard/providers/dashboard_overview_provider.dart';
import 'package:uten_imp/features/dashboard/repositories/dashboard_overview_repository.dart';

void main() {
  test(
    'a degraded dashboard partition retries itself and then stops polling',
    () async {
      final repository = _RecoveringDashboardRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          dashboardOverviewRepositoryProvider.overrideWithValue(repository),
          dashboardOverviewDegradedRetryDelayProvider.overrideWithValue(
            Duration.zero,
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        dashboardOverviewProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final first = await container.read(dashboardOverviewProvider.future);
      expect(first.todos.single.sourceType, 'FULFILLMENT_UNAVAILABLE');
      expect(repository.calls, 1);

      await pumpEventQueue();
      final recovered = await container.read(dashboardOverviewProvider.future);
      expect(recovered.todos, isEmpty);
      expect(repository.calls, 2);

      await pumpEventQueue();
      expect(repository.calls, 2, reason: 'healthy payloads do not poll');
    },
  );
}

class _RecoveringDashboardRepository implements DashboardOverviewRepository {
  int calls = 0;

  @override
  Future<DashboardOverview> load() async {
    calls++;
    return DashboardOverview(
      departmentCode: 'PURCHASE',
      departmentName: '采购部',
      generatedAt: DateTime.utc(2026, 8, 2),
      metrics: const <DashboardMetric>[],
      todos: calls == 1
          ? const <DashboardTodo>[
              DashboardTodo(
                id: 'fulfillment-purchase-unavailable',
                title: '采购任务正在自动恢复',
                summary: '其它功能可继续使用，无需退出或反复刷新',
                count: 0,
                urgentCount: 0,
                tone: 'warning',
                route: '/operations/workbench/purchase',
                sourceType: 'FULFILLMENT_UNAVAILABLE',
                sourceId: null,
                dueAt: null,
                completable: false,
              ),
            ]
          : const <DashboardTodo>[],
      intelligence: const <PolicyBrief>[],
    );
  }
}
