import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/dashboard/models/dashboard_overview.dart';
import 'package:uten_imp/features/dashboard/providers/dashboard_overview_provider.dart';
import 'package:uten_imp/features/dashboard/repositories/dashboard_overview_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _scope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'a'),
);

class _Repository implements DashboardOverviewRepository {
  final pending = <Completer<DashboardOverview>>[];

  @override
  Future<DashboardOverview> load() {
    final request = Completer<DashboardOverview>();
    pending.add(request);
    return request.future;
  }
}

DashboardOverview _overview(String department) => DashboardOverview(
  departmentCode: department,
  departmentName: department,
  generatedAt: DateTime.utc(2026, 10, 13),
  metrics: const [],
  todos: const [],
);

void main() {
  test('切身份立即移除旧部门概览，迟到旧响应不能替换当前部门', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
        dashboardOverviewRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    container.listen(
      dashboardOverviewProvider,
      (_, _) {},
      fireImmediately: true,
    );
    repository.pending.single.complete(_overview('PURCHASE'));
    await container.read(dashboardOverviewProvider.future);
    container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'b',
    );
    await container.pump();
    expect(container.read(dashboardOverviewProvider).isLoading, isTrue);
    expect(
      container
          .read(dashboardOverviewProvider)
          .when(
            data: (value) => value,
            loading: () => null,
            error: (_, _) => null,
          ),
      isNull,
    );
    expect(repository.pending, hasLength(2));
    container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'a',
      actorId: 'admin',
      readOnly: true,
    );
    await container.pump();
    repository.pending[2].complete(_overview('WAREHOUSE'));
    await container.read(dashboardOverviewProvider.future);
    repository.pending[1].complete(_overview('FINANCE'));
    await container.pump();
    expect(
      container.read(dashboardOverviewProvider).value?.departmentCode,
      'WAREHOUSE',
    );
    container.read(_scope.notifier).state = null;
    await container.pump();
    expect(container.read(dashboardOverviewProvider).value, isNull);
    expect(repository.pending, hasLength(3), reason: '登出不读取业务概览');
  });
}
