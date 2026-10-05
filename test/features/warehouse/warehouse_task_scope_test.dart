// 仓库数据范围(ADR-149) 的前端契约：
//   · 主管：顶栏小标签 + 右侧滑窗(先主仓后子仓)，首行「全部仓库」；选一个仓 → 各分段按新范围重拉；
//   · 负责多个仓：同样的滑窗，首行「我负责的全部仓库」，只列自己负责的仓；
//   · 只负责一个仓：只读标签「我负责：xx」，不显示选择器，请求不带参数(服务端按本人范围过滤)；
//   · 其他人：不显示；
//   · 记忆的仓不在当前可选范围内(负责关系变了)时回到本人默认范围；
//   · 范围只经骨架往下传：骨架外的同一视图不带参数。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
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

const _main = WarehouseScopeOption(id: 'main', name: '主仓');
const _fg = WarehouseScopeOption(id: 'fg', name: '成品仓', parentId: 'main');
const _hw = WarehouseScopeOption(id: 'hw', name: '五金仓', parentId: 'main');

const _supervisor = MyWarehouseScope(
  role: WarehouseScopeRole.supervisor,
  canSelectAll: true,
  selectable: [_main, _fg, _hw],
);

Widget _app({
  required MyWarehouseScope mine,
  required List<(WarehouseTaskScope, int)> seen,
}) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(_preferences),
    apiClientProvider.overrideWithValue(_SilentApi()),
    myWarehouseScopeProvider.overrideWith((ref) async => mine),
  ],
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: WarehouseTaskCenterScaffold(
      location: '/warehouse/tasks/test',
      title: '测试任务中心',
      searchHint: '搜索',
      initialSegment: 'list',
      segments: const [WarehouseTaskSegmentSpec(value: 'list', label: '列表')],
      bodyBuilder: (segment, keyword, refreshTick, _) =>
          _ScopeProbe(refreshTick: refreshTick, seen: seen),
    ),
  ),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('supervisor picks any warehouse from the side panel', (
    tester,
  ) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(_app(mine: _supervisor, seen: seen));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('warehouse-scope-label'))).data,
      '全部仓库',
    );
    expect(seen.last.$1, const WarehouseTaskScope.all());
    expect(seen.last.$1.queryParameters, isEmpty);
    final tickBefore = seen.last.$2;

    await tester.tap(find.byKey(const Key('warehouse-scope-selector')));
    await tester.pumpAndSettle();
    // 首行「全部仓库」, 先主仓后子仓。
    expect(find.byKey(const Key('warehouse-picker-all')), findsOneWidget);
    expect(find.text('主仓'), findsOneWidget);
    await tester.tap(find.text('成品仓'));
    await tester.pumpAndSettle();

    expect(seen.last.$1, const WarehouseTaskScope.warehouse('fg'));
    expect(seen.last.$1.queryParameters, {'scopeWarehouseId': 'fg'});
    expect(seen.last.$2, greaterThan(tickBefore));
    expect(
      tester.widget<Text>(find.byKey(const Key('warehouse-scope-label'))).data,
      '成品仓',
    );

    // 记忆写入(账号级偏好防抖 800ms)后再结束, 不留悬挂定时器。
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('keeper of several warehouses switches only among them', (
    tester,
  ) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(
      _app(
        mine: const MyWarehouseScope(
          role: WarehouseScopeRole.keeper,
          selectable: [_fg, _hw],
          keeperWarehouses: [_fg, _hw],
        ),
        seen: seen,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('warehouse-scope-label'))).data,
      '我负责的全部仓库',
    );
    await tester.tap(find.byKey(const Key('warehouse-scope-selector')));
    await tester.pumpAndSettle();
    expect(find.text('我负责的全部仓库'), findsWidgets);
    expect(find.text('主仓'), findsNothing);
    await tester.tap(find.text('五金仓'));
    await tester.pumpAndSettle();
    expect(seen.last.$1.queryParameters, {'scopeWarehouseId': 'hw'});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'keeper of one warehouse sees a read-only label and no selector',
    (tester) async {
      final seen = <(WarehouseTaskScope, int)>[];
      await tester.pumpWidget(
        _app(
          mine: const MyWarehouseScope(
            role: WarehouseScopeRole.keeper,
            selectable: [_fg],
            keeperWarehouses: [_fg],
            defaultWarehouseId: 'fg',
          ),
          seen: seen,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('warehouse-scope-selector')), findsNothing);
      expect(find.text('我负责：成品仓'), findsOneWidget);
      // 默认范围由服务端按本人负责的仓强制, 请求不带参数。
      expect(seen.last.$1.queryParameters, isEmpty);
    },
  );

  testWidgets('other people see no selector at all', (tester) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(_app(mine: MyWarehouseScope.empty, seen: seen));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-scope-selector')), findsNothing);
    expect(find.byKey(const Key('warehouse-scope-keeper-label')), findsNothing);
    expect(seen.last.$1, const WarehouseTaskScope.all());
  });

  test('a remembered warehouse outside the current scope falls back', () async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiClientProvider.overrideWithValue(_SilentApi()),
        myWarehouseScopeProvider.overrideWith(
          (ref) async => const MyWarehouseScope(
            role: WarehouseScopeRole.keeper,
            selectable: [_fg, _hw],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(myWarehouseScopeProvider.future);
    container
        .read(warehouseTaskScopePrefProvider.notifier)
        .select(const WarehouseTaskScope.warehouse('xw03'));
    expect(
      container.read(warehouseTaskScopeProvider),
      const WarehouseTaskScope.all(),
    );
    container
        .read(warehouseTaskScopePrefProvider.notifier)
        .select(const WarehouseTaskScope.warehouse('hw'));
    expect(
      container.read(warehouseTaskScopeProvider),
      const WarehouseTaskScope.warehouse('hw'),
    );
  });

  test('legacy ADR-115 preferences fall back to the default scope', () {
    final notifier = WarehouseTaskScopePrefNotifier();
    expect(notifier.decode({'mode': 'MINE'})?.warehouseId, isNull);
    expect(notifier.decode({'mode': 'ALL'})?.warehouseId, isNull);
    expect(
      notifier.decode({'mode': 'WAREHOUSE', 'warehouseId': 'fg'})?.warehouseId,
      'fg',
    );
    expect(notifier.decode({'warehouseId': 'hw'})?.warehouseId, 'hw');
    expect(notifier.encode(WarehouseTaskScopePref.unset), isEmpty);
  });

  testWidgets('views outside a task center send no scope parameter', (
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
