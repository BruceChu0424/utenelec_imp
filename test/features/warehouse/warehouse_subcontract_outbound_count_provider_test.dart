// 委外待出仓红黄两数(ADR-103 §2.5)的解析与派生契约:
//   · 服务端 {count, waitingComponent} 两键都读; 老服务端只回 count 时黄数回落 0;
//   · 红黄两支由同一支源头派生(一次请求两枚), 刷新期间保住旧值;
//   · 无权限静默回空, 不发请求。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_subcontract_outbound_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.response) : super(Dio());

  Map<String, dynamic> response;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, ApiEndpoints.warehouseSubcontractOutboundTaskCount);
    calls++;
    return response;
  }
}

void main() {
  test('taskCount 解析红黄两键', () async {
    final repository = WarehouseSubcontractOutboundRepository(
      _FakeApi({'count': 2, 'waitingComponent': 3}),
    );
    expect(
      await repository.taskCount(),
      const SubcontractOutboundTaskCounts(count: 2, waitingComponent: 3),
    );
  });

  test('老服务端缺 waitingComponent 键时黄数回落 0', () async {
    final repository = WarehouseSubcontractOutboundRepository(
      _FakeApi({'count': 4}),
    );
    expect(
      await repository.taskCount(),
      const SubcontractOutboundTaskCounts(count: 4),
    );
    expect(
      await WarehouseSubcontractOutboundRepository(
        _FakeApi(const {}),
      ).taskCount(),
      SubcontractOutboundTaskCounts.empty,
    );
  });

  test('红黄两支由同一支源头派生: 一次请求两枚, 刷新期间保住旧值', () async {
    final api = _FakeApi({'count': 2, 'waitingComponent': 3});
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.subcontractOutboundView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);

    final redSub = container.listen(
      warehouseSubcontractOutboundCountProvider,
      (_, _) {},
    );
    final yellowSub = container.listen(
      warehouseSubcontractOutboundWaitingComponentCountProvider,
      (_, _) {},
    );
    expect(redSub.read().isLoading, isTrue);
    expect(yellowSub.read().isLoading, isTrue);
    await container.read(warehouseSubcontractOutboundTaskCountsProvider.future);
    expect(redSub.read().valueOrNull, 2);
    expect(yellowSub.read().valueOrNull, 3);
    expect(api.calls, 1, reason: '两枚徽章必须共用一次请求');

    // 失效源头: 重拉期间两支都带住旧值(准则 §四之三), 回来后同时换成新数。
    api.response = {'count': 0, 'waitingComponent': 5};
    container.invalidate(warehouseSubcontractOutboundTaskCountsProvider);
    expect(redSub.read().valueOrNull, 2);
    expect(yellowSub.read().valueOrNull, 3);
    await container.read(warehouseSubcontractOutboundTaskCountsProvider.future);
    expect(redSub.read().valueOrNull, 0);
    expect(yellowSub.read().valueOrNull, 5);
    expect(api.calls, 2);
  });

  test('无委外出仓权限时静默回空, 不发请求', () async {
    final api = _FakeApi({'count': 9, 'waitingComponent': 9});
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    expect(
      await container.read(
        warehouseSubcontractOutboundTaskCountsProvider.future,
      ),
      SubcontractOutboundTaskCounts.empty,
    );
    expect(api.calls, 0);
  });
}
