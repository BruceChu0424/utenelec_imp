import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final width in [400.0, 1400.0]) {
    testWidgets(
      'empty pending schedule keeps zero selection in floating actions width=$width',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final router = _router();
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              productionPlanRepositoryProvider.overrideWithValue(
                _repository([], empty: true),
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
        expect(find.text('暂无待排产的订单行'), findsOneWidget);
        final summary = find.byKey(
          const Key('production-pending-selected-total'),
        );
        expect(find.text('已选 0 项'), findsOneWidget);
        expect(tester.getRect(summary).top, greaterThan(675));
        expect(
          find.ancestor(
            of: summary,
            matching: find.byType(UtenFloatingActionGroup),
          ),
          findsOneWidget,
        );
        if (width > 600) {
          final tableFinder = find.byType(
            MasterDataTableView<SchedulePendingRow>,
          );
          final table = tester.widget<MasterDataTableView<SchedulePendingRow>>(
            tableFinder,
          );
          expect(table.showSelectionSummary, isFalse);
          expect(
            table.bottomContentPadding,
            UtenFloatingActionGroup.scrollClearance,
          );
          expect(
            find.descendant(
              of: tableFinder,
              matching: find.byType(UtenSelectionSummaryPill),
            ),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

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

      // 分类分段范式（ADR-066）：大类行默认不选（引导占位，不发请求），
      // 先点「待排产」段加载缺口表格。
      await tester.tap(find.text('待排产'));
      await tester.pumpAndSettle();

      // ADR-088：待排产段只剩「尚未被活动分析承接的量」，齐套率属于「进行中」
      // 那张分析，本段不再有「可生产量 / 预计可生产」两列，改挂「已分析」指路列。
      expect(find.text('可生产量'), findsNothing);
      expect(find.text('预计可生产'), findsNothing);
      expect(find.text('已分析'), findsOneWidget);
      expect(find.text('待分析'), findsWidgets);

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
      expect(find.text('已选 2 项'), findsOneWidget);
      // 混合产品单位不求总量；标准选择胶囊与联合分析按钮同一悬浮组、垂直居中
      // 对齐且在其左侧；工具条不再驻留内建胶囊（showSelectionSummary=false，
      // 同页选择数只出现一处）。
      final totalRect = tester.getRect(
        find.byKey(const Key('production-pending-selected-total')),
      );
      final analysisBtnRect = tester.getRect(
        find.byKey(const Key('pending-enter-analysis-to-generate')),
      );
      expect(totalRect.right, lessThan(analysisBtnRect.left));
      expect(
        (totalRect.center.dy - analysisBtnRect.center.dy).abs(),
        lessThan(2),
      );

      await tester.tap(
        find.byKey(const Key('production-pending-clear-selection')),
      );
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(find.text('新建物料分析'), findsOneWidget);
      expect(find.text('已选 2 项'), findsNothing);

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

      // 分类分段范式（ADR-066）：先点「待排产」段加载缺口表格。
      await tester.tap(find.text('待排产'));
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

  testWidgets(
    'double-clicking an analyzed row resumes its joint analysis directly',
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

      // 分类分段范式（ADR-066）：先点「待排产」段加载缺口表格。
      await tester.tap(find.text('待排产'));
      await tester.pumpAndSettle();

      // 双击已分析行 = 直接恢复它所属的物料分析（多销售单联合分析时，
      // 每一行都带同一张分析 id，点谁都是进那张合并分析页）；
      // 单击仍只切换勾选，不导航。
      final analyzedCell = find.text('SO-A');
      await tester.tap(analyzedCell);
      await tester.pump();
      expect(find.textContaining('analysis='), findsNothing);

      await tester.tap(analyzedCell);
      await tester.pumpAndSettle();
      expect(find.text('analysis=analysis-a;sources=0;'), findsOneWidget);
    },
  );

  testWidgets(
    'double-clicking an unanalyzed row shows guidance instead of silence',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final requests = <RequestOptions>[];
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);

      // 默认夹具（activeFirst=false）：SO-A 无活动分析。
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionPlanRepositoryProvider.overrideWithValue(
              _repository(requests),
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

      // 分类分段范式（ADR-066）：先点「待排产」段加载缺口表格。
      await tester.tap(find.text('待排产'));
      await tester.pumpAndSettle();

      // 双击未分析行必须有反馈（引导提示），不能无反应，也不导航。
      final cell = find.text('SO-A');
      await tester.tap(cell);
      await tester.pump();
      await tester.tap(cell);
      await tester.pumpAndSettle();

      expect(find.textContaining('analysis='), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionBoardPage)),
      );
      expect(
        container.read(appNotificationProvider).last.message,
        '该行的缺口还没有分析承接；请勾选后点右下角「联合分析所选 N 项」',
      );
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
  bool empty = false,
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
            'items': empty
                ? <dynamic>[]
                : [
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
                      // ADR-088：带活动分析的行一定是「部分承接」行——全量承接的
                      // 行服务端已经不返回了，所以这里同时给出已承接量。
                      if (activeFirst) 'analysisCoveredQty': 6,
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
            'total': empty ? 0 : 2,
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
