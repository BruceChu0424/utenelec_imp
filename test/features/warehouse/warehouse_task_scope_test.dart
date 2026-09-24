// 仓库任务中心「仓库范围」(ADR-115, 2026-09-24) 契约：
//   · 从没选过：负责人默认「我的仓库」，其余默认「全部仓库」；
//   · 顶栏选择器选一个仓 → 各分段列表按新范围重拉(refreshTick 推进)，请求参数随范围变化；
//   · 范围只经骨架往下传：同一视图在骨架外(单独页面)不受影响，按全部仓库请求。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_center_scaffold.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

late SharedPreferences _preferences;

/// 不走真实网络：偏好推送等后台请求一律回空。
class _SilentApi extends ApiClient {
  _SilentApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      const {};
}

/// 分段内容替身：记录每次(重)建时拿到的范围与 refreshTick。
class _ScopeProbe extends StatelessWidget {
  const _ScopeProbe({required this.refreshTick, required this.seen});

  final int refreshTick;
  final List<(WarehouseTaskScope, int)> seen;

  @override
  Widget build(BuildContext context) {
    final scope = WarehouseListScope.of(context);
    seen.add((scope, refreshTick));
    return Text(
      'scope=${scope.queryParameters} tick=$refreshTick',
      key: const Key('scope-probe'),
    );
  }
}

Widget _app({
  required MyWarehouseScope mine,
  required List<(WarehouseTaskScope, int)> seen,
}) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(_preferences),
    apiClientProvider.overrideWithValue(_SilentApi()),
    myWarehouseScopeProvider.overrideWith((ref) async => mine),
    warehouseScopeOptionsProvider.overrideWith(
      (ref) async => const [
        WarehouseScopeOption(id: 'main', name: '主仓'),
        WarehouseScopeOption(id: 'fg', name: '成品仓', parentId: 'main'),
        WarehouseScopeOption(id: 'hw', name: '五金仓', parentId: 'main'),
      ],
    ),
  ],
  child: MaterialApp(
    home: WarehouseTaskCenterScaffold(
      location: '/warehouse/tasks/test',
      title: '测试任务中心',
      subtitle: '范围',
      searchHint: '搜索',
      initialSegment: 'list',
      segments: const [WarehouseTaskSegmentSpec(value: 'list', label: '列表')],
      bodyBuilder: (segment, keyword, refreshTick) =>
          _ScopeProbe(refreshTick: refreshTick, seen: seen),
    ),
  ),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('keepers default to 我的仓库', (tester) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(
      _app(
        mine: const MyWarehouseScope(
          keeperWarehouses: [WarehouseScopeOption(id: 'fg', name: '成品仓')],
          scopeWarehouseIds: {'fg'},
          keepersConfigured: true,
        ),
        seen: seen,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-scope-label')), findsOneWidget);
    expect(find.text('我的仓库'), findsOneWidget);
    expect(seen.last.$1, const WarehouseTaskScope.mine());
    expect(seen.last.$1.queryParameters, {'warehouseScope': 'MINE'});
  });

  testWidgets('non-keepers default to 全部仓库', (tester) async {
    final others = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(
      _app(mine: const MyWarehouseScope(keepersConfigured: true), seen: others),
    );
    await tester.pumpAndSettle();
    expect(others.last.$1, const WarehouseTaskScope.all());
    expect(others.last.$1.queryParameters, isEmpty);
  });

  testWidgets('choosing a warehouse reloads the segment with its scope', (
    tester,
  ) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(
      _app(mine: const MyWarehouseScope(keepersConfigured: true), seen: seen),
    );
    await tester.pumpAndSettle();
    final tickBefore = seen.last.$2;

    await tester.tap(find.byKey(const Key('warehouse-scope-selector')));
    await tester.pumpAndSettle();
    // 子仓按层级缩进列在主仓下面。
    expect(find.text('成品仓'), findsOneWidget);
    await tester.tap(find.text('成品仓'));
    await tester.pumpAndSettle();

    expect(seen.last.$1, const WarehouseTaskScope.warehouse('fg'));
    expect(seen.last.$1.queryParameters, {'scopeWarehouseId': 'fg'});
    expect(seen.last.$2, greaterThan(tickBefore));
    expect(find.byKey(const Key('warehouse-scope-label')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('warehouse-scope-label'))).data,
      '成品仓',
    );

    // 记忆写入(账号级偏好防抖 800ms)后再结束, 不留悬挂定时器。
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('views outside a task center request every warehouse', (
    tester,
  ) async {
    late WarehouseTaskScope outside;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            outside = WarehouseListScope.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(outside, const WarehouseTaskScope.all());
    expect(outside.queryParameters, isEmpty);
  });
}
