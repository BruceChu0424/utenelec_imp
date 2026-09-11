import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_count_suffix.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// 2026-09-05 生产调度与进度简化：
//  ① 待排产段交货日期范围筛选与「建议联合分析」下线，不发 dateFrom/dateTo；
//     刷新按钮在表格右上角（toolbarActions）。
//  ② 大类行两种计数形态（2026-09-11 收敛，docs/00-项目准则/14-徽章与计数口径.md）：
//     「待排产」= 调度员必须清空的队列 → 红色通知徽章（0 不渲染）；
//     「进行中」= 计划部统筹的监控数 → 中性括号 `(N)`（0 显示 `(0)` 保持队形）。
//     计数与各自列表同源（size=1 只取分页 total）；无对应权限时不发计数请求、
//     不显示数字（待排产=production_plan:view、进行中=production_execution:overview）。
void main() {
  testWidgets('pending segment drops deliver-date filter and suggest button', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final requests = <RequestOptions>[];
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            _planRepository(requests),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionMaterialAnalysisCreate,
          }),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('待排产'));
    await tester.pumpAndSettle();

    expect(find.text('可生产量'), findsOneWidget);
    // V545：新增「已排」列；部分排产（订 10 排 4）的行仍在待排产段，状态标明已排/订货。
    expect(find.text('已排'), findsOneWidget);
    expect(find.text('部分已排 4/10'), findsOneWidget);
    // 交货日期范围筛选与「建议联合分析」按钮已下线。
    expect(find.text('交货从'), findsNothing);
    expect(find.text('交货至'), findsNothing);
    expect(find.textContaining('建议联合分析'), findsNothing);
    // 刷新按钮仍在，且随表格工具条放在右上角。
    expect(find.byKey(const Key('production-pending-refresh')), findsOneWidget);
    // 列表/布点请求不再携带交货日期参数。
    final pendingRequest = requests.firstWhere(
      (request) => request.path == '/production/schedule/pending',
    );
    expect(pendingRequest.queryParameters.containsKey('dateFrom'), isFalse);
    expect(pendingRequest.queryParameters.containsKey('dateTo'), isFalse);
  });

  testWidgets('pending segment keeps the red todo badge', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final requests = <RequestOptions>[];
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            _planRepository(requests, total: 9),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
          }),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 「待排产」是待办队列：红色通知徽章，数字在徽章组件里不拼进 label 文本，
    // 也不是中性括号。
    expect(find.text('待排产'), findsOneWidget);
    expect(find.text('待排产 9'), findsNothing);
    expect(find.text('(9)'), findsNothing);
    final pendingLabel = tester.widget<UtenSegmentBadgeLabel>(
      find.byWidgetPredicate(
        (widget) => widget is UtenSegmentBadgeLabel && widget.label == '待排产',
      ),
    );
    expect(pendingLabel.countForm, UtenSegmentCountForm.actionable);
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is UtenSegmentBadgeLabel && widget.label == '待排产',
        ),
        matching: find.byType(UtenNotificationBadge),
      ),
      findsOneWidget,
    );
    expect(find.text('9'), findsOneWidget);
    // 计数与列表同源：只取 size=1 的分页 total，不带筛选。
    final countRequest = requests.firstWhere(
      (request) =>
          request.path == '/production/schedule/pending' &&
          request.queryParameters['size'] == 1,
    );
    expect(countRequest.queryParameters.containsKey('status'), isFalse);

    // 进入待排产段后，列表加载完成会刷新大类行计数（仍为同源 total）。
    await tester.tap(find.text('待排产'));
    await tester.pumpAndSettle();
    expect(find.text('待排产'), findsOneWidget);
  });

  testWidgets('ongoing segment shows the neutral bracket count', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final requests = <RequestOptions>[];
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            _planRepository(requests),
          ),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(requests),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionOverview,
          }),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 浏览型监控数（批次数）：中性括号 `(7)`，不是红色通知徽章，也不再拼
    // 进 label 文本。
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('进行中 7'), findsNothing);
    expect(find.text('(7)'), findsOneWidget);
    final ongoing = find.byWidgetPredicate(
      (widget) => widget is UtenSegmentBadgeLabel && widget.label == '进行中',
    );
    expect(
      tester.widget<UtenSegmentBadgeLabel>(ongoing).countForm,
      UtenSegmentCountForm.browsing,
    );
    expect(
      find.descendant(of: ongoing, matching: find.byType(UtenCountSuffix)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: ongoing,
        matching: find.byType(UtenNotificationBadge),
      ),
      findsNothing,
    );
    final countRequest = requests.firstWhere(
      (request) => request.path == '/production/execution-workbench',
    );
    expect(countRequest.queryParameters['size'], 1);
  });

  testWidgets('ongoing count stays hidden without overview permission', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final requests = <RequestOptions>[];
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            _planRepository(requests),
          ),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(requests),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
          }),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('进行中'), findsOneWidget);
    expect(find.textContaining('进行中 7'), findsNothing);
    // 无权限 = 计数为 null（未知），中性括号同样不渲染——不把未知伪装成 `(0)`。
    expect(find.text('(7)'), findsNothing);
    expect(find.text('(0)'), findsNothing);
    expect(
      requests.where(
        (request) => request.path == '/production/execution-workbench',
      ),
      isEmpty,
    );
  });
}

GoRouter _router() => GoRouter(
  routes: [GoRoute(path: '/', builder: (_, _) => const ProductionBoardPage())],
);

ProductionPlanRepository _planRepository(
  List<RequestOptions> requests, {
  int total = 1,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final data = switch (request.path) {
          '/production/schedule/pending/facets' => {
            'status': <Map<String, dynamic>>[],
          },
          '/production/schedule/pending' => {
            'items': <Map<String, dynamic>>[
              {
                'orderItemId': 'line-a',
                'orderId': 'order-a',
                'orderBillNo': 'SO-A',
                'goodsId': 'goods-a',
                'goodsCode': 'A-001',
                'goodsName': '产品 A',
                'qty': 10,
                'plannedQty': 4,
                'needQty': 6,
                'deliverDate': '2026-08-20',
              },
            ],
            'page': 1,
            'size': 20,
            'total': total,
            'totalPages': 1,
          },
          _ => <String, dynamic>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ProductionPlanRepository(ApiClient(dio));
}

ProductionExecutionWorkbenchRepository _workbenchRepository(
  List<RequestOptions> requests,
) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: {
              'items': <Map<String, dynamic>>[],
              'page': 1,
              'size': 1,
              'total': 7,
              'totalPages': 7,
            },
          ),
        );
      },
    ),
  );
  return ProductionExecutionWorkbenchRepository(ApiClient(dio));
}
