import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_chain_health_page.dart';

void main() {
  testWidgets(
    'chain health page renders four categories with counts and navigates to source documents',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const ProductionChainHealthPage(),
          ),
          GoRoute(
            path: '/sales/orders/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开销售订单 ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/production/plans/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开计划 ${state.pathParameters['id']}')),
          ),
          GoRoute(
            path: '/warehouse/DRAW/:id',
            builder: (context, state) =>
                Scaffold(body: Text('已打开领料单 ${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(_healthApi())],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('有销售缺口 · 无物料分析'), findsOneWidget);
      expect(find.text('有物料分析 · 未排完计划'), findsOneWidget);
      expect(find.text('有计划 · 未生成领料单'), findsOneWidget);
      expect(find.text('有领料单 · 无计划来源'), findsOneWidget);
      expect(find.textContaining('SO-1'), findsOneWidget);
      expect(find.text('SJ-9'), findsOneWidget);
      expect(find.text('LL-3'), findsOneWidget);
      // 全量命中数徽标（不受明细截断影响）
      expect(find.text('7'), findsWidgets);

      await tester.tap(find.textContaining('SO-1'));
      await tester.pumpAndSettle();
      expect(find.text('已打开销售订单 order-1'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('SJ-9'));
      await tester.pumpAndSettle();
      expect(find.text('已打开计划 plan-9'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('LL-3'));
      await tester.pumpAndSettle();
      expect(find.text('已打开领料单 draw-3'), findsOneWidget);
    },
  );

  testWidgets('chain health page shows healthy banner when no issues', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_healthApi(healthy: true)),
        ],
        child: const MaterialApp(home: ProductionChainHealthPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('本次覆盖范围内未发现断链'), findsOneWidget);
    expect(
      find.byKey(const Key('chain-health-coverage-notice')),
      findsOneWidget,
    );
  });
}

ApiClient _healthApi({bool healthy = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final categories = <Map<String, dynamic>>[
          <String, dynamic>{
            'category': 'SALES_GAP_NO_ANALYSIS',
            'label': '有销售缺口 · 无物料分析',
            'description': 'desc-1',
            'count': healthy ? 0 : 7,
            'issues': healthy
                ? <Map<String, dynamic>>[]
                : <Map<String, dynamic>>[
                    <String, dynamic>{
                      'refId': 'item-1',
                      'targetId': 'order-1',
                      'billNo': 'SO-1',
                      'label': '成品 A',
                      'detail': '缺口 5 · 交期 2026-08-20',
                      'route': 'SALES_ORDER',
                    },
                  ],
          },
          <String, dynamic>{
            'category': 'ANALYSIS_UNPLANNED',
            'label': '有物料分析 · 未排完计划',
            'description': 'desc-2',
            'count': 0,
            'issues': <Map<String, dynamic>>[],
          },
          <String, dynamic>{
            'category': 'PLAN_NO_DRAW',
            'label': '有计划 · 未生成领料单',
            'description': 'desc-3',
            'count': healthy ? 0 : 2,
            'issues': healthy
                ? <Map<String, dynamic>>[]
                : <Map<String, dynamic>>[
                    <String, dynamic>{
                      'refId': 'plan-9',
                      'targetId': 'plan-9',
                      'billNo': 'SJ-9',
                      'label': 'SJ-9',
                      'detail': '开单 2026-08-10 · 注塑车间',
                      'route': 'PRODUCTION_PLAN',
                    },
                  ],
          },
          <String, dynamic>{
            'category': 'DRAW_NO_PLAN',
            'label': '有领料单 · 无计划来源',
            'description': 'desc-4',
            'count': healthy ? 0 : 1,
            'issues': healthy
                ? <Map<String, dynamic>>[]
                : <Map<String, dynamic>>[
                    <String, dynamic>{
                      'refId': 'draw-3',
                      'targetId': 'draw-3',
                      'billNo': 'LL-3',
                      'label': 'LL-3',
                      'detail': '单据日期 2026-08-09',
                      'route': 'STOCK_DRAW',
                    },
                  ],
          },
        ];
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: categories,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
