import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/widgets/production_execution_group_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

// 2026-09-05 起进行中面板是计划部统筹视角：不提供报工入口与「只看我的车间」
// 筛选；双击批次直达物料分析页（ANALYSIS 根，携带 analysisId seed）或生产
// 计划详情（PLAN 根）。
void main() {
  testWidgets('double-click analysis root opens material analysis page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionExecutionOverview,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(),
          ),
          productionWorkshopTreeProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 报工入口与「只看我的车间」筛选均已下线。
    expect(find.textContaining('报工'), findsNothing);
    expect(find.text('只看我的车间/负责工单'), findsNothing);

    // 双击 ANALYSIS 批次行 → 直达物料分析页（带 analysisId seed，不弹滑窗）。
    final cell = find.text('联合分析 SO-1 / SO-2');
    await tester.tap(cell);
    await tester.pump();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.text('analysis=analysis-1'), findsOneWidget);
  });

  testWidgets('double-click legacy plan root opens plan detail page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionExecutionOverview,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(),
          ),
          productionWorkshopTreeProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final cell = find.text('根计划 SJ-9');
    await tester.tap(cell);
    await tester.pump();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.text('计划 plan-9'), findsOneWidget);
  });
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

GoRouter _router() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) =>
          const Scaffold(body: ProductionExecutionGroupPanel(keyword: '')),
    ),
    GoRoute(
      path: '/production/material-analysis',
      builder: (_, state) {
        final seed = state.extra is ProductionMaterialAnalysisSeed
            ? state.extra! as ProductionMaterialAnalysisSeed
            : const ProductionMaterialAnalysisSeed();
        return Scaffold(body: Text('analysis=${seed.analysisId}'));
      },
    ),
    GoRoute(
      path: '/production/plans/:id',
      builder: (_, state) =>
          Scaffold(body: Text('计划 ${state.pathParameters['id']}')),
    ),
  ],
);

ProductionExecutionWorkbenchRepository _repository() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/production/execution-workbench' => {
            'items': [
              _group('ANALYSIS', 'analysis-1', '联合分析 SO-1 / SO-2', 'PREPARED'),
              _group('PLAN', 'plan-9', '根计划 SJ-9', 'IN_PROGRESS'),
            ],
            'page': 1,
            'size': 50,
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
  return ProductionExecutionWorkbenchRepository(ApiClient(dio));
}

Map<String, dynamic> _group(
  String rootType,
  String rootId,
  String rootLabel,
  String status,
) => {
  'rootType': rootType,
  'rootId': rootId,
  'rootLabel': rootLabel,
  'status': status,
  'planCount': 1,
  'segmentCount': 1,
};
