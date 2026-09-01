import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'multi-select seeds joint analysis and never calls the legacy merge endpoint',
    (tester) async {
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
              _repository(requests),
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

      expect(find.text('可生产量'), findsOneWidget);
      expect(find.text('3(30%)'), findsOneWidget);
      expect(find.text('未分析'), findsWidgets);

      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsNWidgets(3));
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);
      expect(tester.widget<Checkbox>(checkboxes.at(1)).value, isFalse);
      expect(tester.widget<Checkbox>(checkboxes.at(2)).value, isFalse);

      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
      expect(find.text('联合分析所选 2 项'), findsOneWidget);
      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);

      await tester.tap(checkboxes.at(1));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isNull);
      expect(find.text('联合分析所选 1 项'), findsOneWidget);

      await tester.tap(checkboxes.at(2));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
      expect(find.text('联合分析所选 2 项'), findsOneWidget);
      expect(find.text('已选 2 行'), findsOneWidget);
      // 混合产品单位不求总量；所选行数徽标与联合分析按钮同一行、同高且在其左侧。
      final totalRect = tester.getRect(
        find.byKey(const Key('production-pending-selected-total')),
      );
      final analysisBtnRect = tester.getRect(
        find.byKey(const Key('pending-enter-analysis-to-generate')),
      );
      expect(totalRect.top, analysisBtnRect.top);
      expect(totalRect.height, analysisBtnRect.height);
      expect(totalRect.right, lessThan(analysisBtnRect.left));

      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);
      expect(find.text('新建物料分析'), findsOneWidget);
      expect(find.text('已选 2 行'), findsNothing);

      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(find.text('联合分析所选 2 项'), findsOneWidget);

      await tester.tap(find.text('联合分析所选 2 项'));
      await tester.pumpAndSettle();

      expect(
        find.text('analysis=null;sources=2;line-a:10.0,line-b:4.0'),
        findsOneWidget,
      );
      expect(
        requests.where((request) => request.path.contains('merge-plan')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'active analysis fails fast in multi-select and resumes alone without source subset',
    (tester) async {
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
              _repository(requests, activeFirst: true),
            ),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionMaterialAnalysisCreate,
              Perm.productionMaterialAnalysisRefresh,
            }),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsNWidgets(3));
      await tester.tap(checkboxes.at(1));
      await tester.pump();
      await tester.tap(checkboxes.at(2));
      await tester.pump();
      await tester.tap(find.text('联合分析所选 2 项'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionBoardPage)),
      );
      expect(
        container.read(appNotificationProvider).last.message,
        '已有物料分析的产品只能单独“继续分析”；联合分析请只选择全部未分析的产品。',
      );
      expect(find.textContaining('analysis='), findsNothing);

      await tester.tap(checkboxes.at(2));
      await tester.pump();
      await tester.tap(find.text('联合分析所选 1 项'));
      await tester.pumpAndSettle();
      expect(find.text('analysis=analysis-a;sources=0;'), findsOneWidget);
    },
  );
}

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const ProductionBoardPage()),
    GoRoute(
      path: RouteName.productionMaterialAnalysis,
      builder: (_, state) {
        final seed = state.extra! as ProductionMaterialAnalysisSeed;
        return Scaffold(
          body: Text(
            'analysis=${seed.analysisId};sources=${seed.sources.length};'
            '${seed.sources.map((source) => '${source.salesOrderItemId}:${source.requestedQty}').join(',')}',
          ),
        );
      },
    ),
  ],
);

ProductionPlanRepository _repository(
  List<RequestOptions> requests, {
  bool activeFirst = false,
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
            'items': [
              {
                'orderItemId': 'line-a',
                'orderId': 'order-a',
                'orderBillNo': 'SO-A',
                'goodsId': 'goods-a',
                'goodsCode': 'A-001',
                'goodsName': '产品 A',
                'qty': 10,
                'plannedQty': 0,
                'needQty': 10,
                'readyNowQty': 3,
                'readyByDateQty': 8,
                'readinessRatio': 0.3,
                if (activeFirst) 'materialAnalysisId': 'analysis-a',
                if (activeFirst) 'materialAnalysisVersion': 2,
                'materialAnalyzedAt': '2026-08-08T10:00:00Z',
                'deliverDate': '2026-08-20',
              },
              {
                'orderItemId': 'line-b',
                'orderId': 'order-b',
                'orderBillNo': 'SO-B',
                'goodsId': 'goods-b',
                'goodsCode': 'B-001',
                'goodsName': '产品 B',
                'qty': 4,
                'plannedQty': 0,
                'needQty': 4,
                'deliverDate': '2026-08-25',
              },
            ],
            'page': 1,
            'size': 20,
            'total': 2,
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
