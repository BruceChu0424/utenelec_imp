// 仓库数据范围(ADR-149) 的前端契约：
//   · 主管：顶栏小标签 + 右侧滑窗(先主仓后子仓)，首行「全部仓库」；选一个仓 → 各分段按新范围重拉；
//   · 负责多个仓：同样的滑窗，首行「我负责的全部仓库」，只列自己负责的仓；
//   · 单仓负责人及其他人：使用相同入口，只能从服务端给出的可见仓中缩小筛选；
//   · 记忆的仓不在当前可选范围内(负责关系变了)时回到本人默认范围；
//   · 范围只经骨架往下传：骨架外的同一视图不带参数。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_provider_retry.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_center_scaffold.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_scope_selector.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_badges.dart';
import 'package:uten_imp/shared/warehouse/warehouse_scope_recovery_host.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

// Riverpod 3 将 copyWithPrevious 标记为 @internal；跨 family 实例手动保页/保旧值是既有架构，等上游公开等价 API 后再迁移。
// ignore_for_file: invalid_use_of_internal_member

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

class _BadgeApi extends _SilentApi {
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == ApiEndpoints.workbenchBadges
      ? {
          'facts': {'productionDraw.readyToPick': 11},
        }
      : const {};
}

class _StaleBadgeApi extends _SilentApi {
  Map<String, dynamic> next = _selectedBadgeResponse(11);
  int reads = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.workbenchBadges) return const {};
    reads++;
    expect(query?['scopeWarehouseId'], 'hw');
    return next;
  }
}

Map<String, dynamic> _selectedBadgeResponse(int count, {bool stale = false}) =>
    {
      'entries': {
        'warehouseOutboundCenter': {'todo': count, 'inProgress': 0},
      },
      'modules': {
        'warehouse': {'todo': count, 'inProgress': 0},
      },
      'total': {'todo': count, 'inProgress': 0},
      'facts': {
        if (!stale) BadgeFact.productionDrawReady: count,
        'warehouseSalesOutbound.PENDING_PICK': count,
      },
      if (stale) 'staleEntries': ['warehouseOutboundCenter'],
      if (stale) 'staleSources': ['productionDraw'],
    };

final _badgeIdentity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'warehouse-reader'),
);
final _badgePermissions = StateProvider<Set<String>>(
  (_) => const {'subcontract_outbound:view'},
);

List<Override> _staleBadgeOverrides(ApiClient api) => [
  sharedPreferencesProvider.overrideWithValue(_preferences),
  apiClientProvider.overrideWithValue(api),
  authenticatedScopeProvider.overrideWith((ref) => ref.watch(_badgeIdentity)),
  currentPermissionsProvider.overrideWith(
    (ref) => ref.watch(_badgePermissions),
  ),
  isSuperAdminProvider.overrideWithValue(false),
  myWarehouseScopeProvider.overrideWith((ref) async => _supervisor),
  warehouseTaskScopeProvider.overrideWithValue(
    const WarehouseTaskScope.warehouse('hw'),
  ),
];

/// 真实 my-scope provider 的替身网络：记录每次范围读取；[failFirst] 决定第一次读取怎样失败。
/// READ_SCOPE_CHANGED 时与拦截器同序：先退役读取范围版本号，再拒掉这次读取。
class _ScopeApi extends ApiClient {
  _ScopeApi({required this.failFirst}) : super(Dio());

  final ApiException Function() failFirst;
  final scopeQueries = <Map<String, dynamic>?>[];

  int get scopeReads => scopeQueries.length;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.myWarehouseScope) return const {};
    scopeQueries.add(query);
    final attempt = scopeQueries.length;
    // 响应在网络往返之后才到(拦截器的退役与拒绝都发生在这之后), 不在 provider 构建期间同步发生。
    await Future<void>.delayed(Duration.zero);
    if (attempt == 1) throw failFirst();
    return const {
      'role': 'OTHER',
      'warehouseParticipant': true,
      'selectable': [
        {'id': 'hw', 'name': '五金仓'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      const {};
}

List<Override> _scopeOverrides(ApiClient api) => [
  sharedPreferencesProvider.overrideWithValue(_preferences),
  apiClientProvider.overrideWithValue(api),
  authenticatedScopeProvider.overrideWithValue(
    const AuthenticatedScope(userId: 'warehouse-reader'),
  ),
  currentPermissionsProvider.overrideWithValue(const {
    'subcontract_outbound:view',
  }),
  isSuperAdminProvider.overrideWithValue(false),
];

/// 与正式应用同一重试策略(main.dart: ApiException 不自动重试)，否则 Riverpod 默认重试会掩盖
/// 「错误态一直停着等手动重试」的真实现象。
ProviderContainer _scopeContainer(ApiClient api) =>
    ProviderContainer(overrides: _scopeOverrides(api), retry: apiProviderRetry);

/// 等 my-scope 落定(不再加载中)；读取本身会刷新已失效的 provider。
Future<AsyncValue<MyWarehouseScope>> _settledScope(
  ProviderContainer container,
) async {
  for (var turn = 0; turn < 50; turn++) {
    final state = container.read(myWarehouseScopeProvider);
    if (!state.isLoading) return state;
    await Future<void>.delayed(Duration.zero);
  }
  return container.read(myWarehouseScopeProvider);
}

ApiException _scopeChanged() => ApiException(
  'READ_SCOPE_CHANGED',
  '数据访问范围已变化，请重新打开页面后核对',
  httpStatus: 403,
  hasResponseCode: true,
);

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
  Future<MyWarehouseScope> Function()? loadScope,
  ThemeData? theme,
  double textScale = 1,
}) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(_preferences),
    apiClientProvider.overrideWithValue(_SilentApi()),
    myWarehouseScopeProvider.overrideWith(
      (ref) async => loadScope == null ? mine : await loadScope(),
    ),
  ],
  child: MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
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
  testWidgets(
    'same-owner selected warehouse stale response preserves counts and then recovers',
    (tester) async {
      final api = _StaleBadgeApi();
      final container = ProviderContainer(
        overrides: _staleBadgeOverrides(api),
        retry: apiProviderRetry,
      );
      try {
        late WidgetRef widgetRef;
        const projection = WarehouseTaskScope.warehouse('hw');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Consumer(
              builder: (_, ref, _) {
                widgetRef = ref;
                ref.watch(warehouseScopedBadgesProvider(projection));
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        BadgeSummary read() =>
            container.read(warehouseScopedBadgesProvider(projection));
        expect(read().fact(BadgeFact.productionDrawReady), 11);
        api.next = _selectedBadgeResponse(4, stale: true);
        await refreshSelectedWarehouseBadges(widgetRef);
        await tester.pumpAndSettle();
        expect(read().fact(BadgeFact.productionDrawReady), 11);
        expect(read().entryTodo(BadgeEntry.warehouseOutboundCenter), 11);
        expect(read().total.todo, 11);
        expect(
          read().facts['warehouseSalesOutbound.PENDING_PICK'],
          4,
          reason: 'a healthy source still publishes its fresh result',
        );
        expect(read().staleSources, {'productionDraw'});
        api.next = _selectedBadgeResponse(9);
        await refreshSelectedWarehouseBadges(widgetRef);
        await tester.pumpAndSettle();
        expect(read().fact(BadgeFact.productionDrawReady), 9);
        expect(read().entryTodo(BadgeEntry.warehouseOutboundCenter), 9);
        expect(read().staleSources, isEmpty);
        expect(api.reads, 3);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      }
    },
  );

  for (final boundary in ['identity', 'permission', 'revision']) {
    testWidgets(
      'selected warehouse stale response cannot reuse a previous $boundary boundary',
      (tester) async {
        final api = _StaleBadgeApi();
        final container = ProviderContainer(
          overrides: _staleBadgeOverrides(api),
          retry: apiProviderRetry,
        );
        try {
          const projection = WarehouseTaskScope.warehouse('hw');
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: Consumer(
                builder: (_, ref, _) {
                  ref.watch(warehouseScopedBadgesProvider(projection));
                  return const SizedBox.shrink();
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            container
                .read(warehouseScopedBadgesProvider(projection))
                .fact(BadgeFact.productionDrawReady),
            11,
          );
          api.next = _selectedBadgeResponse(0, stale: true);
          switch (boundary) {
            case 'identity':
              container.read(_badgeIdentity.notifier).state =
                  const AuthenticatedScope(userId: 'other-reader');
            case 'permission':
              container.read(_badgePermissions.notifier).state = const {
                'stock_doc:view',
              };
            case 'revision':
              container.read(readScopeRevisionProvider.notifier).state++;
          }
          await tester.pumpAndSettle();
          final summary = container.read(
            warehouseScopedBadgesProvider(projection),
          );
          expect(
            summary.facts.containsKey(BadgeFact.productionDrawReady),
            isFalse,
          );
          expect(summary.entryTodo(BadgeEntry.warehouseOutboundCenter), 0);
          expect(summary.total.todo, 0);
          expect(api.reads, 2);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
        }
      },
    );
  }

  test(
    'same-owner scope refresh keeps badges across rapid rechecks and confirmed removal',
    () async {
      var next = Future.value(_supervisor);
      final container = ProviderContainer(
        overrides: [
          ..._scopeOverrides(_BadgeApi()),
          myWarehouseScopeProvider.overrideWith((ref) => next),
        ],
        retry: apiProviderRetry,
      );
      addTearDown(container.dispose);
      await container.read(myWarehouseScopeProvider.future);
      const scope = WarehouseTaskScope.warehouse('hw');
      final projection = warehouseScopedBadgesProvider(scope);
      final subscription = container.listen(projection, (_, _) {});
      addTearDown(subscription.close);
      for (var i = 0; i < 10 && container.read(projection).facts.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(projection).facts.values, [11]);
      for (var turn = 0; turn < 5; turn++) {
        final recheck = Completer<MyWarehouseScope>();
        next = recheck.future;
        container.invalidate(myWarehouseScopeProvider);
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(projection).facts.values,
          [11],
          reason: 'rapid recheck $turn cannot clear the badge',
        );
        recheck.complete(_supervisor);
        await container.read(myWarehouseScopeProvider.future);
      }
      final refreshed = Completer<MyWarehouseScope>();
      next = refreshed.future;
      container.invalidate(myWarehouseScopeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(myWarehouseScopeProvider).isLoading, isTrue);
      expect(
        confirmedMyWarehouseScope(container.read(myWarehouseScopeProvider)),
        isNull,
        reason: 'operation authority remains unavailable during recheck',
      );
      expect(
        container.read(projection).facts.values,
        [11],
        reason: 'a display refresh must not flash empty',
      );
      refreshed.complete(const MyWarehouseScope(selectable: [_fg]));
      await container.read(myWarehouseScopeProvider.future);
      expect(
        container.read(projection).facts,
        isEmpty,
        reason: 'confirmed removal withdraws the badge',
      );
    },
  );
  test(
    'all-warehouse browsing preserves the keeper role and physical badge selection',
    () async {
      final mine = MyWarehouseScope.fromJson(const {
        'role': 'KEEPER',
        'warehouseParticipant': true,
        'readAllWarehouses': true,
        'canSelectAll': true,
        'selectable': [
          {'id': 'own', 'name': '本仓'},
          {'id': 'other', 'name': '别仓'},
        ],
        'commandSelectable': [
          {'id': 'own', 'name': '本仓'},
        ],
      });
      expect(mine.isKeeper, isTrue);
      expect(mine.isSupervisor, isFalse);
      expect(mine.canSelect('other'), isTrue);
      expect(mine.canSelectForTasks('other'), isFalse);
      expect(mine.canSelectForTasks('own'), isTrue);
      final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
      expect(
        WarehouseScopeSelector.labelOf(
          l10n,
          mine,
          const WarehouseTaskScope.all(),
        ),
        l10n.warehouseScopeAllWarehouses,
      );
      final container = ProviderContainer(
        overrides: [myWarehouseScopeProvider.overrideWith((ref) async => mine)],
      );
      addTearDown(container.dispose);
      await container.read(myWarehouseScopeProvider.future);
      final summary = container.read(
        warehouseScopedBadgesProvider(
          const WarehouseTaskScope.warehouse('other'),
        ),
      );
      expect(summary.entries, isEmpty);
      expect(summary.facts, isEmpty);
    },
  );
  test('warehouse participation is an explicit server capability', () {
    expect(
      MyWarehouseScope.fromJson(const {'role': 'OTHER'}).warehouseParticipant,
      isFalse,
    );
    expect(
      MyWarehouseScope.fromJson(const {
        'role': 'OTHER',
        'warehouseParticipant': true,
      }).warehouseParticipant,
      isTrue,
    );
    expect(
      MyWarehouseScope.fromJson(const {
        'role': 'SUPERVISOR',
        'warehouseParticipant': 'true',
      }).warehouseParticipant,
      isFalse,
    );
  });

  test(
    'refreshing or failed warehouse scopes cannot reuse old authorization',
    () {
      const previous = AsyncData(MyWarehouseScope(warehouseParticipant: true));
      expect(confirmedMyWarehouseScope(previous)?.warehouseParticipant, isTrue);
      expect(
        confirmedMyWarehouseScope(
          const AsyncLoading<MyWarehouseScope>().copyWithPrevious(previous),
        ),
        isNull,
      );
      expect(
        confirmedMyWarehouseScope(
          AsyncError<MyWarehouseScope>(
            StateError('revoked'),
            StackTrace.empty,
          ).copyWithPrevious(previous),
        ),
        isNull,
      );
    },
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  for (final brightness in Brightness.values) {
    for (final width in [390.0, 760.0, 1500.0]) {
      testWidgets(
        'warehouse selector keeps its theme border at $width in $brightness with large text',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final theme =
              (brightness == Brightness.dark
                      ? buildDarkTheme()
                      : buildLightTheme())
                  .copyWith(platform: TargetPlatform.windows);
          await tester.pumpWidget(
            _app(mine: _supervisor, seen: [], theme: theme, textScale: 2),
          );
          await tester.pumpAndSettle();
          final selector = find.byKey(const Key('warehouse-scope-selector'));
          if (selector.hitTestable().evaluate().isEmpty) {
            await tester.tap(
              find.byKey(const Key('uten-app-bar-more-actions')),
            );
            await tester.pumpAndSettle();
          }
          expect(selector.hitTestable(), findsOneWidget);
          final border = tester.widget<Ink>(
            find
                .byKey(const Key('warehouse-scope-selector-border'))
                .hitTestable(),
          );
          expect(
            (border.decoration! as BoxDecoration).border,
            Border.all(color: theme.colorScheme.primary),
          );
          expect(
            tester.getSize(selector.hitTestable()).height,
            greaterThanOrEqualTo(UtenControlMetrics.compactHeight),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'embedded parent and child categories share one compact gap and keep IDs',
    (tester) async {
      final selected = <String>[];
      final seen = <(WarehouseTaskScope, int)>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(_preferences),
            apiClientProvider.overrideWithValue(_SilentApi()),
            myWarehouseScopeProvider.overrideWith((ref) async => _supervisor),
          ],
          child: MaterialApp(
            theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
            home: Scaffold(
              body: WarehouseTaskCenterScaffold(
                embedded: true,
                location: '/warehouse/tasks/hierarchy',
                title: '子类任务',
                searchHint: '搜索',
                initialSegment: 'pending',
                externalHeader: UtenSegmentRow<String>(
                  key: const Key('warehouse-parent-category'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'inbound', label: Text('入库')),
                    ButtonSegment(value: 'outbound', label: Text('出库')),
                  ],
                  selected: const {'inbound'},
                  onSelectionChanged: (_) {},
                ),
                segments: const [
                  WarehouseTaskSegmentSpec(
                    value: 'pending',
                    label: '待办',
                    count: 7,
                  ),
                  WarehouseTaskSegmentSpec(value: 'done', label: '已完成'),
                ],
                bodyBuilder: (value, keyword, tick, header) {
                  selected.add(value);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      _ScopeProbe(refreshTick: tick, seen: seen),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final parent = tester.getRect(
        find.byKey(const Key('warehouse-parent-category')),
      );
      final child = tester.getRect(find.byType(UtenFilterToolbar<String>));
      expect(child.top - parent.bottom, UtenFilterRow.rowGap);
      expect(parent.height, greaterThanOrEqualTo(36));
      expect(selected.last, 'pending');
      expect(seen.last.$1, const WarehouseTaskScope.all());
      await tester.tap(find.text('已完成').hitTestable());
      await tester.pumpAndSettle();
      expect(selected.last, 'done');
      final toolbar = tester.widget<UtenFilterToolbar<String>>(
        find.byType(UtenFilterToolbar<String>),
      );
      expect(toolbar.selected, {'done'});
      expect(toolbar.segments.first.value, 'pending');
      expect(toolbar.segments.first.count, 7);
      expect(tester.takeException(), isNull);
    },
  );

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
    // 首行「全部仓库」, 先主仓后子仓(2026-10 表格统一: 主仓既是行也是分组标题)。
    expect(find.byKey(const Key('warehouse-picker-all')), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-picker-entry-main')),
      findsOneWidget,
    );
    expect(find.text('主仓'), findsWidgets);
    await tester.tap(find.text('成品仓'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
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
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    expect(seen.last.$1.queryParameters, {'scopeWarehouseId': 'hw'});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('keeper of one warehouse can explicitly filter that warehouse', (
    tester,
  ) async {
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
    expect(find.byKey(const Key('warehouse-scope-selector')), findsOneWidget);
    // 默认范围由服务端按本人负责的仓强制, 请求不带参数。
    expect(seen.last.$1.queryParameters, isEmpty);
    await tester.tap(find.byKey(const Key('warehouse-scope-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('成品仓'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    expect(seen.last.$1.queryParameters, {'scopeWarehouseId': 'fg'});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an account without visible warehouses has no selector', (
    tester,
  ) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(_app(mine: MyWarehouseScope.empty, seen: seen));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-scope-selector')), findsNothing);
    expect(find.byKey(const Key('warehouse-scope-keeper-label')), findsNothing);
    expect(seen.last.$1, const WarehouseTaskScope.all());
  });

  testWidgets('ordinary warehouse staff can filter within visible warehouses', (
    tester,
  ) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(
      _app(
        mine: const MyWarehouseScope(selectable: [_hw]),
        seen: seen,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('全部可见仓库'), findsOneWidget);
    await tester.tap(find.byKey(const Key('warehouse-scope-selector')));
    await tester.pumpAndSettle();
    expect(find.text('主仓'), findsNothing);
    expect(find.text('成品仓'), findsNothing);
    await tester.tap(find.text('五金仓'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    expect(seen.last.$1.queryParameters, {'scopeWarehouseId': 'hw'});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('parent warehouse filter makes visible descendants explicit', (
    tester,
  ) async {
    final seen = <(WarehouseTaskScope, int)>[];
    await tester.pumpWidget(_app(mine: _supervisor, seen: seen));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-scope-selector')));
    await tester.pumpAndSettle();
    expect(find.text('包含可见的下级仓库'), findsOneWidget);
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('主仓(含下级)'), findsOneWidget);
    expect(seen.last.$1.queryParameters, {'scopeWarehouseId': 'main'});
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('failed scope read exposes an inline retry', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        mine: MyWarehouseScope.empty,
        seen: [],
        loadScope: () async {
          if (++attempts == 1) throw StateError('offline');
          return const MyWarehouseScope(selectable: [_hw]);
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('warehouse-scope-retry')), findsOneWidget);
    await tester.tap(find.byKey(const Key('warehouse-scope-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-scope-selector')), findsOneWidget);
    expect(find.text('全部可见仓库'), findsOneWidget);
  });

  test(
    'READ_SCOPE_CHANGED retires the version and the scope refetches once by itself',
    () async {
      late final ProviderContainer container;
      final api = _ScopeApi(
        failFirst: () {
          // 拦截器发现同一读取面的版本漂移：先退役版本号，再把这次读取拒掉。
          container.read(readScopeRevisionProvider.notifier).state++;
          return _scopeChanged();
        },
      );
      container = _scopeContainer(api);
      addTearDown(container.dispose);
      final subscription = container.listen(
        myWarehouseScopeProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);

      final recovered = await _settledScope(container);
      expect(recovered.hasError, isFalse);
      expect(recovered.requireValue.selectable.single.id, 'hw');
      expect(api.scopeReads, 2);
      expect(api.scopeQueries, everyElement(equals(const {'forRead': 'true'})));

      // 版本号不再变化就不再读：一次退役只换来一次重拉，不形成请求风暴。
      for (var turn = 0; turn < 10; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.scopeReads, 2);

      // 别的读取退役了版本号(范围真的变了)时同样只重拉一次。
      container.read(readScopeRevisionProvider.notifier).state++;
      expect((await _settledScope(container)).hasValue, isTrue);
      expect(api.scopeReads, 3);
    },
  );

  testWidgets(
    'the scope selector leaves its retry state once the read version is retired',
    (tester) async {
      final api = _ScopeApi(failFirst: () => NetworkException());
      await tester.pumpWidget(
        ProviderScope(
          retry: apiProviderRetry,
          overrides: _scopeOverrides(api),
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: Center(child: WarehouseScopeSelector())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('warehouse-scope-retry')), findsOneWidget);
      expect(api.scopeReads, 1);

      // 同一读取面的版本被退役后不用点重试：选择器用新版本自己恢复。
      ProviderScope.containerOf(
        tester.element(find.byType(WarehouseScopeSelector)),
      ).read(readScopeRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('warehouse-scope-retry')), findsNothing);
      expect(find.byKey(const Key('warehouse-scope-selector')), findsOneWidget);
      expect(find.text('全部可见仓库'), findsOneWidget);
      expect(api.scopeReads, 2);
    },
  );

  test(
    'refreshing a selected scope never briefly expands to the default',
    () async {
      var response = Future.value(_supervisor);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(_preferences),
          apiClientProvider.overrideWithValue(_SilentApi()),
          myWarehouseScopeProvider.overrideWith((ref) => response),
        ],
      );
      addTearDown(container.dispose);
      container.listen(warehouseTaskScopeProvider, (_, _) {});
      await container.read(myWarehouseScopeProvider.future);
      container
          .read(warehouseTaskScopePrefProvider.notifier)
          .select(const WarehouseTaskScope.warehouse('hw'));
      final refresh = Completer<MyWarehouseScope>();
      response = refresh.future;
      container.invalidate(myWarehouseScopeProvider);
      expect(container.read(myWarehouseScopeProvider).isLoading, isTrue);
      expect(container.read(warehouseTaskScopeProvider).warehouseId, 'hw');
      refresh.complete(const MyWarehouseScope(selectable: [_fg]));
      await container.read(myWarehouseScopeProvider.future);
      expect(container.read(warehouseTaskScopeProvider).isAll, isTrue);
      await container.pump();
      expect(
        container.read(warehouseTaskScopePrefProvider).warehouseId,
        isNull,
      );
    },
  );

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

  // 2026-11-09: 服务重启/断网窗口里 my-scope 失败后 provider 停在错误态,
  // 用户被卡在「仓库筛选加载失败」切不了「全部仓库」。恢复前台自动重拉一次。
  testWidgets('window resume retries a failed warehouse scope only', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myWarehouseScopeProvider.overrideWith((ref) async {
            reads++;
            if (reads == 1) {
              throw DioException(
                requestOptions: RequestOptions(
                  path: ApiEndpoints.myWarehouseScope,
                ),
              );
            }
            return MyWarehouseScope.empty;
          }),
        ],
        child: WarehouseScopeRecoveryHost(
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  ref.watch(myWarehouseScopeProvider);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(reads, 1, reason: '首次取数失败进入错误态');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, 2, reason: '恢复前台重拉错误态的范围');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, 2, reason: '成功后不再重复请求');
  });
}
