import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_chain_health_page.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

const _tableKey = Key('chain-health-table');

void main() {
  _pageTest(
    'shared issue table omits zero categories and opens four exact sources only on double click',
    (tester) async {
      final api = _HealthApi(_categories());
      final app = await _pump(tester, api);
      final table = tester.widget<MasterDataTableView<Object>>(
        find.byKey(_tableKey),
      );
      expect(table.embedded, isFalse);
      expect(table.singleTapRows, isFalse);
      expect(table.virtualized, isTrue);
      expect(table.items.length, 4);
      expect(find.byKey(const Key('chain-health-summary')), findsNothing);
      expect(find.byKey(const Key('chain-health-ZERO')), findsNothing);
      expect(find.text('没有问题的类别'), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(find.textContaining('待处理 11 条 · 已展示 4 条'), findsOneWidget);
      expect(find.byKey(const Key('chain-health-truncation')), findsOneWidget);
      expect(find.textContaining('每类最多 50 条'), findsOneWidget);
      expect(api.limits, [50]);

      final columns = table.columns;
      expect(
        columns.map((column) => column.label),
        containsAll(['问题类型', '单据编号', '事项', '详情']),
      );
      expect(columns.any((column) => column.type == 'date'), isFalse);

      for (final entry in [
        (text: 'SO-1', path: '/sales/orders/order-target'),
        (text: '需求待安排', path: RouteName.productionMaterialAnalysis),
        (text: 'SJ-9', path: '/production/plans/plan-ref'),
        (text: 'LL-3', path: '/warehouse/DRAW/draw-ref'),
      ]) {
        final source = find.text(entry.text).first;
        await tester.ensureVisible(source);
        await tester.tap(source);
        await tester.pump(const Duration(milliseconds: 50));
        expect(app.router.routeInformationProvider.value.uri.path, '/');
        expect(find.byType(ProductionChainHealthPage), findsOneWidget);
        await tester.tap(source);
        await tester.pumpAndSettle();
        expect(find.text('destination ${entry.path}'), findsOneWidget);
        if (entry.path == RouteName.productionMaterialAnalysis) {
          expect(app.analysisSeed?.analysisId, 'analysis-ref');
        }
        app.router.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(_tableKey), findsOneWidget);
      }
      expect(
        api.calls,
        greaterThanOrEqualTo(5),
        reason: 'Returning from each source re-scans after the route settles.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  _pageTest(
    'a zero scan keeps an empty table, not completed cards or zero-type filters',
    (tester) async {
      final api = _HealthApi(_categories(healthy: true));
      await _pump(tester, api);
      expect(find.byKey(_tableKey), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      expect(find.text('本次覆盖范围内未发现断链'), findsNothing);
      expect(find.textContaining('待处理 0 条 · 已展示 0 条'), findsOneWidget);
      expect(find.text('本次覆盖范围内暂无待处理问题'), findsOneWidget);
      expect(find.byKey(const Key('chain-health-truncation')), findsNothing);
      final filter = tester.widget<UtenFilterToolbar<String>>(
        find.byType(UtenFilterToolbar<String>),
      );
      expect(filter.segments.map((segment) => segment.label), ['全部']);
      expect(filter.selected, {'__all__'});
      expect(
        find.byKey(const Key('chain-health-coverage-notice')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  _pageTest(
    'category filters keep authoritative counts separate from returned details',
    (tester) async {
      final api = _HealthApi(_categories());
      await _pump(tester, api, size: const Size(2200, 900));
      final filter = find.byKey(const Key('chain-health-category-filter'));
      final choice = find.descendant(
        of: filter,
        matching: find.text('有销售缺口 · 无物料分析'),
      );
      expect(choice, findsOneWidget);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(find.textContaining('待处理 7 条 · 已展示 1 条'), findsOneWidget);
      expect(
        tester
            .widget<MasterDataTableView<Object>>(find.byKey(_tableKey))
            .items
            .length,
        1,
      );
      expect(find.text('SO-1'), findsOneWidget);
      expect(find.text('SJ-9'), findsNothing);
      await tester.tap(find.descendant(of: filter, matching: find.text('全部')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MasterDataTableView<Object>>(find.byKey(_tableKey))
            .items
            .length,
        4,
      );
      expect(
        api.calls,
        1,
        reason:
            'The category switch filters the existing bounded scan without inventing another page.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  _pageTest(
    'a repeated bill number is not printed twice in the item column; original text remains disclosed',
    (tester) async {
      await _pump(tester, _HealthApi(_categories()));
      expect(find.text('LL-3'), findsOneWidget);
      final original = find.byWidgetPredicate(
        (widget) => widget is UtenFieldHintIcon && widget.info == '原始事项：LL-3',
      );
      expect(original, findsOneWidget);
      await tester.tap(original);
      await tester.pumpAndSettle();
      expect(find.text('原始事项：LL-3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _pageTest(
    'a positive count without returned details never claims there are no pending issues',
    (tester) async {
      await _pump(
        tester,
        _HealthApi([_category('ONLY_COUNT', '明细暂未返回', 12, [])]),
      );
      expect(find.textContaining('待处理 12 条 · 已展示 0 条'), findsOneWidget);
      expect(find.text('本次扫描未返回本范围明细，请重新扫描或核对原单据'), findsOneWidget);
      expect(find.text('本次覆盖范围内暂无待处理问题'), findsNothing);
      expect(find.byKey(const Key('chain-health-truncation')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(1366, 768),
    const Size(1920, 1080),
    const Size(390, 700),
  ]) {
    _pageTest(
      'issue table and compact controls fit $size with many long categories',
      (tester) async {
        await _pump(tester, _HealthApi(_manyCategories()), size: size);
        expect(find.byKey(_tableKey), findsOneWidget);
        expect(
          find.byKey(const Key('chain-health-category-filter')),
          findsOneWidget,
        );
        final table = tester.widget<MasterDataTableView<Object>>(
          find.byKey(_tableKey),
        );
        expect(table.virtualized, isTrue);
        expect(table.items.length, 150);
        final mountedBills = find
            .byWidgetPredicate(
              (widget) =>
                  widget is Text && widget.data?.startsWith('DOC-') == true,
            )
            .evaluate()
            .length;
        expect(mountedBills, greaterThan(0));
        expect(
          mountedBills,
          lessThan(80),
          reason:
              'The real shared table mounts a viewport window, not every scan detail.',
        );
        if (size.width >= 1366) {
          expect(
            tester.getSize(find.byType(UtenFilterToolbar<String>)).height,
            lessThan(90),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  _pageTest(
    'refresh failure retains old rows, shows the error and permits a new scan',
    (tester) async {
      final api = _HealthApi(_categories());
      await _pump(tester, api);
      api.failNext = true;
      await tester.tap(find.byTooltip('重新扫描'));
      await tester.pumpAndSettle();
      final failed = tester.widget<MasterDataTableView<Object>>(
        find.byKey(_tableKey),
      );
      expect(failed.items.length, 4);
      expect(failed.error, isNotNull);
      expect(find.text('SO-1'), findsOneWidget);
      await tester.tap(find.byTooltip('重新扫描'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MasterDataTableView<Object>>(find.byKey(_tableKey)).error,
        isNull,
      );
      expect(api.calls, 3);
      expect(tester.takeException(), isNull);
    },
  );

  _pageTest(
    'an in-flight scan is deduplicated and late completion after disposal does not publish',
    (tester) async {
      final api = _HealthApi(_categories());
      final pending = Completer<void>();
      api.pauseNext = pending;
      await _pump(tester, api, settle: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(api.calls, 1);
      await Future<void>.sync(
        tester
            .widget<UtenRefreshButton>(find.byType(UtenRefreshButton))
            .onRefresh,
      );
      expect(api.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(_tableKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Harness {
  _Harness(this.router, this.container);
  final GoRouter router;
  final ProviderContainer container;
  VoidCallback? detach;
  bool _disposed = false;
  ProductionMaterialAnalysisSeed? analysisSeed;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detach?.call();
    router.dispose();
    container.dispose();
  }
}

final _liveHarnesses = <_Harness>[];

/// Dispose app-owned providers before testWidgets verifies pending timers, not
/// only in package:test teardown after that verification already completed.
void _pageTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final app in _liveHarnesses) {
        app.dispose();
      }
      _liveHarnesses.clear();
      await tester.pump();
    }
  });
}

class _FixtureSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

Future<_Harness> _pump(
  WidgetTester tester,
  _HealthApi api, {
  Size size = const Size(1920, 1080),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api.client),
      apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
      authenticatedScopeProvider.overrideWithValue(null),
      sessionProvider.overrideWith(_FixtureSession.new),
    ],
  );
  late final _Harness app;
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ProductionChainHealthPage()),
      GoRoute(
        path: '/sales/orders/:id',
        builder: (_, state) => Scaffold(
          body: Text('destination /sales/orders/${state.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/production/plans/:id',
        builder: (_, state) => Scaffold(
          body: Text(
            'destination /production/plans/${state.pathParameters['id']}',
          ),
        ),
      ),
      GoRoute(
        path: '/warehouse/DRAW/:id',
        builder: (_, state) => Scaffold(
          body: Text(
            'destination /warehouse/DRAW/${state.pathParameters['id']}',
          ),
        ),
      ),
      GoRoute(
        path: RouteName.productionMaterialAnalysis,
        builder: (_, state) {
          app.analysisSeed = state.extra as ProductionMaterialAnalysisSeed?;
          return const Scaffold(
            body: Text('destination ${RouteName.productionMaterialAnalysis}'),
          );
        },
      ),
    ],
  );
  app = _Harness(router, container);
  _liveHarnesses.add(app);
  addTearDown(app.dispose);
  app.detach = attachPageResume(
    router,
    container.read(pageResumeProvider.notifier),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        scrollBehavior: const UtenScrollBehavior(),
        builder: (_, child) => UtenPageScrollbarHost(child: child!),
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(platform: TargetPlatform.windows),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return app;
}

class _HealthApi {
  _HealthApi(this.payload) {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.path != '/production/chain-health') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
            return;
          }
          calls++;
          limits.add(request.queryParameters['limit']);
          final pause = pauseNext;
          pauseNext = null;
          final fail = failNext;
          failNext = false;
          final data = payload;
          if (pause != null) await pause.future;
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 503,
                  data: {'message': '链路扫描暂时不可用'},
                ),
              ),
            );
          } else {
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          }
        },
      ),
    );
    client = ApiClient(dio);
  }
  late final ApiClient client;
  List<Map<String, dynamic>> payload;
  int calls = 0;
  final limits = <Object?>[];
  bool failNext = false;
  Completer<void>? pauseNext;
}

Map<String, dynamic> _issue(
  String route,
  String ref, {
  String? target,
  String? bill,
  String? label,
}) => {
  'route': route,
  'refId': ref,
  'targetId': target,
  'billNo': bill,
  'label': label ?? bill ?? ref,
  'detail': '原始事项的具体业务事实',
};

Map<String, dynamic> _category(
  String code,
  String label,
  int count,
  List<Map<String, dynamic>> issues,
) => {
  'category': code,
  'label': label,
  'description': '$label 的服务端分类说明',
  'count': count,
  'issues': issues,
};

List<Map<String, dynamic>> _categories({bool healthy = false}) => [
  _category(
    'SALES',
    '有销售缺口 · 无物料分析',
    healthy ? 0 : 7,
    healthy
        ? []
        : [
            _issue(
              'SALES_ORDER',
              'sales-item-ref',
              target: 'order-target',
              bill: 'SO-1',
              label: '成品 A',
            ),
          ],
  ),
  _category(
    'ANALYSIS',
    '有物料分析 · 未排完计划',
    healthy ? 0 : 1,
    healthy
        ? []
        : [
            _issue(
              'MATERIAL_ANALYSIS',
              'analysis-ref',
              target: 'wrong-analysis-target',
              label: '需求待安排',
            ),
          ],
  ),
  _category(
    'PLAN',
    '有计划 · 未生成领料单',
    healthy ? 0 : 2,
    healthy
        ? []
        : [
            _issue(
              'PRODUCTION_PLAN',
              'plan-ref',
              target: 'wrong-plan-target',
              bill: 'SJ-9',
            ),
          ],
  ),
  _category(
    'DRAW',
    '有领料单 · 无计划来源',
    healthy ? 0 : 1,
    healthy
        ? []
        : [
            _issue(
              'STOCK_DRAW',
              'draw-ref',
              target: 'wrong-draw-target',
              bill: 'LL-3',
            ),
          ],
  ),
  _category('ZERO', '没有问题的类别', 0, []),
];

List<Map<String, dynamic>> _manyCategories() => [
  for (var category = 0; category < 10; category++)
    _category(
      'TYPE-$category',
      '第$category类需要处理的生产链路校验事项',
      category < 3 ? 50 : 1,
      [
        for (var row = 0; row < (category < 3 ? 50 : 0); row++)
          _issue(
            'STOCK_DRAW',
            'ref-$category-$row',
            bill: 'DOC-$category-$row',
            label: '事项 $category / $row',
          ),
      ],
    ),
];
