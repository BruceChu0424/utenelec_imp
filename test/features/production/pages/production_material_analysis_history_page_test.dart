import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_history_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  testWidgets(
    'desktop history exposes server facts and resumes by analysis id',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final router = GoRouter(
        initialLocation: RouteName.productionMaterialAnalysisHistory,
        routes: [
          GoRoute(
            path: RouteName.productionMaterialAnalysisHistory,
            builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(),
          ),
          GoRoute(
            path: RouteName.productionMaterialAnalysis,
            builder: (_, state) {
              final seed = state.extra! as ProductionMaterialAnalysisSeed;
              return Scaffold(body: Text('resume-${seed.analysisId}'));
            },
          ),
          GoRoute(
            path: RouteName.productionPlanList,
            builder: (_, _) => const Scaffold(body: Text('plan-history')),
          ),
        ],
      );
      addTearDown(router.dispose);

      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('analysis-history-table')), findsOneWidget);
      expect(find.text('部分已下达，剩余待料'), findsWidgets);
      expect(find.textContaining('RW-20260808-001'), findsOneWidget);
      expect(find.text('生产调度员'), findsOneWidget);
      expect(find.text('12 / 30'), findsOneWidget);
      expect(find.text('继续处理 →'), findsOneWidget);
      expect(requests.single.path, '/production/material-analyses');

    await tester.tap(find.textContaining('RW-20260808-001'));
      await tester.pumpAndSettle();
      expect(find.text('resume-analysis-1'), findsOneWidget);
    },
  );

  testWidgets('375dp history uses cards, textual status and 48dp row action', (
    tester,
  ) async {
    final api = _api(<RequestOptions>[]);
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
        ],
        child: const MaterialApp(home: ProductionMaterialAnalysisHistoryPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('analysis-history-cards')), findsOneWidget);
    expect(find.byKey(const Key('analysis-history-table')), findsNothing);
    expect(find.text('部分已下达，剩余待料'), findsOneWidget);
    expect(find.byIcon(Icons.pending_actions_outlined), findsOneWidget);
    expect(find.text('继续处理'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const Key('analysis-history-row-analysis-1')))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });
}

ApiClient _api(List<RequestOptions> requests) {
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
              'items': [
                {
                  'analysisId': 'analysis-1',
                  'status': 'PARTIALLY_PLANNED',
                  'version': 8,
                  'fingerprint': 'a' * 64,
                  'warehouseId': 'warehouse-1',
                  'warehouseCode': 'WH-01',
                  'warehouseName': '主仓',
                  'analyzedAt': '2026-08-08T02:00:00Z',
                  'updatedAt': '2026-08-08T03:00:00Z',
                  'makerId': 'employee-1',
                  'makerName': '生产调度员',
                  'sourceCount': 1,
                  'sourceTypes': ['REWORK'],
                  'sourceRefs': ['RW-20260808-001'],
                  'productLabels': ['P-001 返工产品'],
                  'requestedQty': 100,
                  'submittedQty': 10,
                  'approvedQty': 5,
                  'remainingQty': 85,
                  'readyNowQty': 12,
                  'readyByDateQty': 30,
                },
              ],
              'page': 1,
              'size': 20,
              'total': 1,
              'totalPages': 1,
            },
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
